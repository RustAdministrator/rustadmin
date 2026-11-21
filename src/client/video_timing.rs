//! What the viewer's decoder thread of one display measures about its own timing, for the
//! log: how long the decoder calls take and how evenly frames are handed to the renderer.
//!
//! The numbers answer two questions that could only be guessed before. How often does one
//! decoder call block for longer than a handful of frames (after such a call the queue has
//! overflowed and a keyframe is needed)? And do frames reach the renderer at even intervals,
//! or two in one refresh of the screen and none in the next?

use std::{
    fmt,
    time::{Duration, Instant},
};

/// A decoder call longer than this is a stall: about eleven frames at 60 per second, more
/// than the eight frames the Movie queue holds.
pub(crate) const DECODE_STALL: Duration = Duration::from_millis(180);
/// One line goes to the log for each such stretch of video.
pub(crate) const REPORT_INTERVAL: Duration = Duration::from_secs(60);
/// A longer pause between two frames is a still picture, not uneven presentation.
const IDLE_GAP: Duration = Duration::from_secs(1);
/// Upper bounds of the interval classes, in milliseconds. At 60 frames per second an even
/// stream sits in "<=20"; a doubled frame shows as one in "<=8" and one in "<=40".
const INTERVAL_BOUNDS_MS: [u64; 8] = [8, 12, 20, 25, 40, 60, 100, 180];

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub(crate) struct VideoTimingReport {
    pub window: Duration,
    pub decoded: u32,
    pub decode_stalls: u32,
    pub longest_decode: Duration,
    pub presented: u32,
    /// Intervals between presented frames: one count per class of `INTERVAL_BOUNDS_MS`, then
    /// the ones above the last bound.
    pub intervals: [u32; INTERVAL_BOUNDS_MS.len() + 1],
    pub idle_gaps: u32,
}

impl fmt::Display for VideoTimingReport {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "window_s={}, decoded={}, decode_stalls_over_{}ms={}, longest_decode_ms={}, presented={}, intervals_ms=[",
            self.window.as_secs(),
            self.decoded,
            DECODE_STALL.as_millis(),
            self.decode_stalls,
            self.longest_decode.as_millis(),
            self.presented,
        )?;
        for (index, count) in self.intervals.iter().enumerate() {
            let separator = if index == 0 { "" } else { ", " };
            match INTERVAL_BOUNDS_MS.get(index) {
                Some(bound) => write!(f, "{}<={}:{}", separator, bound, count)?,
                None => write!(
                    f,
                    "{}>{}:{}",
                    separator,
                    INTERVAL_BOUNDS_MS[index - 1],
                    count
                )?,
            }
        }
        write!(f, "], idle_gaps={}", self.idle_gaps)
    }
}

/// Collects the measurements of one display and hands out a report once a minute.
#[derive(Debug, Default)]
pub(crate) struct VideoTiming {
    window_started: Option<Instant>,
    last_presented: Option<Instant>,
    report: VideoTimingReport,
}

impl VideoTiming {
    /// A decoder call that took `duration` returned at `now`.
    pub(crate) fn record_decode(
        &mut self,
        duration: Duration,
        now: Instant,
    ) -> Option<VideoTimingReport> {
        self.window_started.get_or_insert(now);
        self.report.decoded += 1;
        if duration > DECODE_STALL {
            self.report.decode_stalls += 1;
        }
        self.report.longest_decode = self.report.longest_decode.max(duration);
        self.take_due(now)
    }

    /// A frame was handed to the renderer at `now`.
    pub(crate) fn record_presented(&mut self, now: Instant) -> Option<VideoTimingReport> {
        self.window_started.get_or_insert(now);
        self.report.presented += 1;
        if let Some(last) = self.last_presented.replace(now) {
            let interval = now.saturating_duration_since(last);
            if interval > IDLE_GAP {
                self.report.idle_gaps += 1;
            } else {
                let millis = interval.as_millis() as u64;
                let class = INTERVAL_BOUNDS_MS
                    .iter()
                    .position(|bound| millis <= *bound)
                    .unwrap_or(INTERVAL_BOUNDS_MS.len());
                self.report.intervals[class] += 1;
            }
        }
        self.take_due(now)
    }

    /// The stream stopped or started again: the pause that follows is not an interval.
    pub(crate) fn pause(&mut self) {
        self.last_presented = None;
    }

    fn take_due(&mut self, now: Instant) -> Option<VideoTimingReport> {
        let started = self.window_started?;
        let window = now.saturating_duration_since(started);
        if window < REPORT_INTERVAL {
            return None;
        }
        self.window_started = Some(now);
        let mut report = std::mem::take(&mut self.report);
        report.window = window;
        Some(report)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(value: u64) -> Duration {
        Duration::from_millis(value)
    }

    #[test]
    fn even_stream_sits_in_one_class() {
        let start = Instant::now();
        let mut timing = VideoTiming::default();
        let mut report = None;
        // 60 frames per second for a little over a minute.
        for frame in 0..=3_700u64 {
            let now = start + Duration::from_micros(frame * 16_667);
            let after_decode = timing.record_decode(ms(4), now);
            let after_present = timing.record_presented(now);
            if let Some(due) = after_decode.or(after_present) {
                report = Some(due);
                break;
            }
        }
        let report = report.expect("a report after a minute");
        assert!(report.window >= REPORT_INTERVAL);
        assert_eq!(report.decode_stalls, 0);
        assert_eq!(report.longest_decode, ms(4));
        assert_eq!(report.intervals[2], report.presented - 1, "{}", report);
        assert_eq!(report.idle_gaps, 0);
    }

    #[test]
    fn doubled_and_missing_frames_show_as_short_and_long_intervals() {
        let start = Instant::now();
        let mut timing = VideoTiming::default();
        // Two frames 3 ms apart, then nothing for 30 ms: the judder of an unpaced viewer.
        let mut now = start;
        for _ in 0..10 {
            timing.record_presented(now);
            now += ms(3);
            timing.record_presented(now);
            now += ms(30);
        }
        let report = timing.report.clone();
        assert_eq!(report.presented, 20);
        assert_eq!(report.intervals[0], 10, "<=8 ms");
        assert_eq!(report.intervals[4], 9, "<=40 ms");
        assert_eq!(report.intervals[2], 0, "nothing at the even interval");
    }

    #[test]
    fn decoder_stalls_and_still_pictures_are_counted_apart() {
        let start = Instant::now();
        let mut timing = VideoTiming::default();
        timing.record_decode(ms(180), start);
        timing.record_decode(ms(181), start + ms(200));
        timing.record_decode(ms(650), start + ms(900));
        assert_eq!(timing.report.decode_stalls, 2, "longer than 180 ms");
        assert_eq!(timing.report.longest_decode, ms(650));

        timing.record_presented(start);
        // The picture did not change for five seconds: not an interval.
        timing.record_presented(start + Duration::from_secs(5));
        assert_eq!(timing.report.idle_gaps, 1);
        assert_eq!(timing.report.intervals.iter().sum::<u32>(), 0);
        // After a pause of the stream the next frame starts a new interval.
        timing.pause();
        timing.record_presented(start + Duration::from_secs(6));
        timing.record_presented(start + Duration::from_secs(6) + ms(150));
        assert_eq!(timing.report.idle_gaps, 1);
        assert_eq!(timing.report.intervals[7], 1, "<=180 ms");
    }

    #[test]
    fn report_line_names_every_class() {
        let report = VideoTimingReport {
            window: Duration::from_secs(60),
            decoded: 3_600,
            decode_stalls: 2,
            longest_decode: ms(410),
            presented: 3_590,
            intervals: [1, 2, 3_500, 40, 30, 10, 4, 2, 1],
            idle_gaps: 0,
        };
        assert_eq!(
            report.to_string(),
            "window_s=60, decoded=3600, decode_stalls_over_180ms=2, longest_decode_ms=410, presented=3590, \
             intervals_ms=[<=8:1, <=12:2, <=20:3500, <=25:40, <=40:30, <=60:10, <=100:4, <=180:2, >180:1], idle_gaps=0"
        );
    }
}
