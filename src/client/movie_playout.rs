//! Playout pacing of decoded frames on a viewer that has no presentation clock of its own.
//!
//! The Movie profile promises a playout buffer of 50 ms: frames are shown at the spacing in
//! which the host captured them, and the buffer absorbs the jitter of the network and of the
//! decoder. Only Android's decoder with output to a surface had that. Everywhere else a frame
//! was shown the moment it was decoded: two frames in one refresh of the screen and none in
//! the next give a picture that stutters at a steady 60 frames a second on the counter.
//!
//! This uses the same clock as the Android path. The decoder thread has one decoded buffer,
//! so a decoded frame is held until it is due and the next one is decoded after that; the
//! frames that arrive meanwhile wait, still encoded, in the queue.
//!
//! That queue is short on purpose (eight frames in Movie, and a frame more than 100 ms older
//! than the newest is dropped and costs a keyframe), and it was sized for a decoder that
//! takes frames at once. So the hold never lets the picture fall further behind the newest
//! arrived frame than the buffer itself: after a stall of the network the frames that arrive
//! together are shown as fast as they decode, as before, and pacing starts again when the
//! picture has caught up.

use scrap::video_presentation_clock::{PresentationResetReason, VideoPresentationClock};
use std::{
    sync::atomic::{AtomicU32, Ordering},
    time::{Duration, Instant},
};

/// The picture is not held while the frames that arrived after it span more than this of the
/// host's capture time: the playout delay of the clock (50 ms) and one frame at 60 per
/// second. In an even stream the span is the playout delay or less.
pub(crate) const BACKLOG_LIMIT: Duration = Duration::from_millis(67);

/// The refresh rate of the viewer's screen in thousandths of a hertz, as the user interface
/// reported it; zero when it did not.
static VIEWER_DISPLAY_REFRESH_MILLIHZ: AtomicU32 = AtomicU32::new(0);

pub(crate) fn set_viewer_display_refresh_millihz(millihz: u32) {
    VIEWER_DISPLAY_REFRESH_MILLIHZ.store(millihz, Ordering::Relaxed);
}

pub(crate) fn viewer_display_refresh_millihz() -> u32 {
    VIEWER_DISPLAY_REFRESH_MILLIHZ.load(Ordering::Relaxed)
}

/// The refresh period for the clock; zero (which the clock reads as 60 Hz) when the rate is
/// not known.
fn refresh_period_ns(millihz: u32) -> i64 {
    if millihz == 0 {
        0
    } else {
        (1_000_000_000_000u64 / u64::from(millihz)) as i64
    }
}

/// When a decoded frame is due, and whether the clock had to start again for it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Playout {
    pub due: Instant,
    pub reset: Option<PresentationResetReason>,
}

/// What was done with a decoded frame.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Hold {
    /// How long to keep the frame before it is shown.
    pub wait: Duration,
    /// The frame was due later, but the picture is behind and it is shown sooner.
    pub catching_up: bool,
}

/// Show now or wait: how long to hold a decoded frame that is ready at `now` and due at
/// `due`, when the frames that arrived after it span `backlog` of the host's capture time.
pub(crate) fn hold(due: Instant, now: Instant, backlog: Duration) -> Hold {
    let wanted = due.saturating_duration_since(now);
    let wait = wanted.min(BACKLOG_LIMIT.saturating_sub(backlog));
    Hold {
        wait,
        catching_up: wait < wanted,
    }
}

/// The span of capture time between a frame and the newest frame that has arrived.
pub(crate) fn backlog(capture_time_ms: u64, newest_capture_time_ms: u64) -> Duration {
    if capture_time_ms == 0 {
        return Duration::ZERO;
    }
    Duration::from_millis(newest_capture_time_ms.saturating_sub(capture_time_ms))
}

/// How many of the `queued` frames to report as waiting for the decoder. The host reads that
/// number as a decoder that cannot keep up and lowers its rate for it. Frames that wait
/// because the picture is held for its time are not that: with pacing (`behind` is how far
/// the picture is behind the newest arrived frame) they count only when the picture is
/// behind by more than the buffer.
pub(crate) fn queue_depth_to_report(queued: usize, behind: Option<Duration>) -> usize {
    match behind {
        Some(behind) if behind <= BACKLOG_LIMIT => 0,
        _ => queued,
    }
}

/// The presentation clock of one display in the Movie profile.
pub(crate) struct MoviePlayout {
    clock: VideoPresentationClock,
    epoch: Instant,
}

impl MoviePlayout {
    /// `epoch`: any moment not after the arrival of the first frame.
    pub(crate) fn new(refresh_millihz: u32, epoch: Instant) -> Self {
        let mut clock = VideoPresentationClock::new(refresh_period_ns(refresh_millihz));
        clock.set_movie_mode(true);
        Self { clock, epoch }
    }

    /// The refresh rate of the viewer's screen. It only sets how late a frame may be before
    /// the clock starts again.
    pub(crate) fn set_refresh_millihz(&mut self, refresh_millihz: u32) {
        self.clock
            .update_refresh_period(refresh_period_ns(refresh_millihz));
    }

    /// When the frame the host captured at `capture_time_ms` is due, given when it arrived.
    /// A frame without a capture time is due at once.
    ///
    /// The clock is asked with the time of arrival, not with the time the frame came out of
    /// the decoder: the decoder thread waits while a frame is held, so the second would hide
    /// from the clock that frames arrive earlier than it assumed, and a clock that started
    /// on a late frame would stay late.
    pub(crate) fn schedule(&mut self, capture_time_ms: u64, arrived_at: Instant) -> Playout {
        let now_ns = arrived_at
            .saturating_duration_since(self.epoch)
            .as_nanos()
            .min(i64::MAX as u128) as i64;
        let schedule = self
            .clock
            .schedule((capture_time_ms > 0).then_some(capture_time_ms), now_ns);
        Playout {
            due: self.epoch + Duration::from_nanos(schedule.target_ns.max(0) as u64),
            reset: schedule.reset.then_some(schedule.reset_reason),
        }
    }
}

/// Whether decoded frames are paced on this viewer. `movie` is the full Movie mode of the
/// stream; `option` is the viewer's `movie-playout-pacing` setting, where `N` is the kill
/// switch. Android has its own clock on the decoder's output surface and is left alone.
pub(crate) fn pacing_enabled(movie: bool, option: &str) -> bool {
    cfg!(not(any(target_os = "android", target_os = "ios"))) && movie && option != "N"
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(value: u64) -> Duration {
        Duration::from_millis(value)
    }

    #[test]
    fn show_now_or_wait() {
        let now = Instant::now();
        // (due in, ms; backlog, ms; hold, ms; catching up)
        let table = [
            // Due later and nothing much behind it: wait for the time.
            (17, 0, 17, false),
            (17, 33, 17, false),
            (17, 50, 17, false),
            (50, 0, 50, false),
            (50, 17, 50, false),
            // Due later, but the newer frames already span most of the limit: wait only
            // for what is left of it.
            (50, 33, 34, true),
            (17, 60, 7, true),
            // The picture is behind: show at once.
            (17, 67, 0, true),
            (50, 120, 0, true),
            // Due now or in the past: show at once, whatever is behind.
            (0, 0, 0, false),
            (0, 200, 0, false),
        ];
        for (index, (due_in, behind, wait, catching_up)) in table.iter().enumerate() {
            let decided = hold(now + ms(*due_in), now, ms(*behind));
            assert_eq!(decided.wait, ms(*wait), "row {}", index);
            assert_eq!(decided.catching_up, *catching_up, "row {}", index);
        }
        assert_eq!(hold(now, now + ms(5), ms(0)).wait, Duration::ZERO);
    }

    #[test]
    fn backlog_is_the_capture_time_span_to_the_newest_frame() {
        assert_eq!(backlog(1_000, 1_050), ms(50));
        assert_eq!(backlog(1_000, 1_000), ms(0));
        // The newest capture time is updated by another thread and may be behind.
        assert_eq!(backlog(1_000, 990), ms(0));
        // No capture time: nothing to measure.
        assert_eq!(backlog(0, 1_000), ms(0));
    }

    #[test]
    fn frames_held_for_their_time_are_not_reported_as_a_decoder_that_is_behind() {
        // No pacing: the queue as it is.
        assert_eq!(queue_depth_to_report(3, None), 3);
        // Paced and within the buffer: the three frames wait on purpose.
        assert_eq!(queue_depth_to_report(3, Some(ms(50))), 0);
        assert_eq!(queue_depth_to_report(4, Some(BACKLOG_LIMIT)), 0);
        // Paced but behind: they wait for the decoder.
        assert_eq!(queue_depth_to_report(6, Some(ms(100))), 6);
    }

    #[test]
    fn frames_are_due_at_the_spacing_of_their_capture_whatever_the_arrival() {
        let start = Instant::now();
        let mut playout = MoviePlayout::new(0, start);
        // (capture time on the host, ms; arrival on the viewer, ms after start; due, ms)
        // The first frame is due after the playout delay; the others keep the host's
        // spacing of 16 or 17 ms although they arrive unevenly, some of them together.
        let table = [
            (1_000u64, 0u64, 50u64),
            (1_017, 30, 67),
            (1_033, 34, 83),
            (1_050, 52, 100),
            (1_067, 95, 117),
            (1_083, 96, 133),
        ];
        for (index, (capture, arrival, due)) in table.iter().enumerate() {
            let scheduled = playout.schedule(*capture, start + ms(*arrival));
            assert_eq!(scheduled.due, start + ms(*due), "row {}", index);
            assert_eq!(
                scheduled.reset.is_some(),
                index == 0,
                "only the first frame starts the clock (row {})",
                index
            );
        }
    }

    #[test]
    fn clock_that_started_on_a_late_frame_moves_to_the_earlier_ones() {
        let start = Instant::now();
        let mut playout = MoviePlayout::new(0, start);
        // The first frame was 40 ms late on the network.
        assert_eq!(playout.schedule(1_000, start + ms(40)).due, start + ms(90));
        // The second arrives on time: with the first one's clock it would wait 90 ms.
        let second = playout.schedule(1_017, start + ms(17));
        assert_eq!(second.reset, Some(PresentationResetReason::Future));
        // Never before the frame shown last.
        assert!(second.due > start + ms(90));
        // From the third on the delay is the playout delay again.
        let third = playout.schedule(1_033, start + ms(33));
        assert!(
            third.due <= start + ms(33 + 50 + 17),
            "{:?}",
            third.due - start
        );
    }

    #[test]
    fn frame_that_is_far_too_late_starts_the_clock_again() {
        let start = Instant::now();
        let mut playout = MoviePlayout::new(0, start);
        playout.schedule(1_000, start);
        // Due at 67 ms, arrives at 300 ms: more than three refresh periods late.
        let arrival = start + ms(300);
        let late = playout.schedule(1_017, arrival);
        assert_eq!(late.reset, Some(PresentationResetReason::Late));
        assert_eq!(late.due, arrival + ms(50));
    }

    #[test]
    fn frame_that_is_a_little_late_is_due_at_once_and_keeps_the_clock() {
        let start = Instant::now();
        let mut playout = MoviePlayout::new(0, start);
        playout.schedule(1_000, start);
        // Due at 67 ms, arrives at 80 ms: within three refresh periods.
        let arrival = start + ms(80);
        let scheduled = playout.schedule(1_017, arrival);
        assert_eq!(scheduled.reset, None);
        assert_eq!(scheduled.due, arrival);
        // The frame after it is on the old schedule again.
        assert_eq!(playout.schedule(1_033, start + ms(81)).due, start + ms(83));
    }

    #[test]
    fn frame_without_a_capture_time_is_due_at_once() {
        let start = Instant::now();
        let mut playout = MoviePlayout::new(0, start);
        let arrival = start + ms(10);
        assert_eq!(playout.schedule(0, arrival).due, arrival);
    }

    #[test]
    fn refresh_rate_becomes_the_period_of_the_clock() {
        assert_eq!(refresh_period_ns(0), 0);
        assert_eq!(refresh_period_ns(60_000), 16_666_666);
        assert_eq!(refresh_period_ns(144_000), 6_944_444);
        // A higher refresh rate makes the clock start again sooner for a late frame:
        // three periods of 144 Hz are about 21 ms.
        let start = Instant::now();
        let mut playout = MoviePlayout::new(0, start);
        playout.set_refresh_millihz(144_000);
        playout.schedule(1_000, start);
        let late = playout.schedule(1_017, start + ms(67 + 30));
        assert_eq!(late.reset, Some(PresentationResetReason::Late));
    }

    #[test]
    fn pacing_is_for_the_movie_profile_and_has_a_kill_switch() {
        let desktop = cfg!(not(any(target_os = "android", target_os = "ios")));
        assert_eq!(pacing_enabled(true, ""), desktop);
        assert_eq!(pacing_enabled(true, "Y"), desktop);
        assert!(!pacing_enabled(true, "N"));
        assert!(!pacing_enabled(false, ""));
    }

    /// The decoder thread in small: frames arrive, wait in the queue, are decoded one at a
    /// time and held. Returns, for every frame, when it was shown (ms), and the largest span
    /// of capture time between a frame taken from the queue and the newest one in it.
    fn play(frames: &[(u64, u64)], decode_ms: u64, paced: bool) -> (Vec<u64>, u64) {
        let start = Instant::now();
        let mut playout = MoviePlayout::new(0, start);
        let mut shown = Vec::new();
        let mut largest_span = 0;
        let mut free_at = 0u64;
        let newest_at = |time: u64| {
            frames
                .iter()
                .filter(|(_, arrival)| *arrival <= time)
                .map(|(capture, _)| *capture)
                .max()
                .unwrap_or(0)
        };
        for (capture, arrival) in frames {
            let taken_at = free_at.max(*arrival);
            largest_span = largest_span.max(newest_at(taken_at).saturating_sub(*capture));
            let ready_at = taken_at + decode_ms;
            let mut shown_at = ready_at;
            if paced {
                let due = playout.schedule(*capture, start + ms(*arrival)).due;
                let behind = backlog(*capture, newest_at(ready_at));
                shown_at += hold(due, start + ms(ready_at), behind).wait.as_millis() as u64;
            }
            shown.push(shown_at);
            free_at = shown_at;
        }
        (shown, largest_span)
    }

    fn intervals(shown: &[u64]) -> Vec<u64> {
        shown.windows(2).map(|pair| pair[1] - pair[0]).collect()
    }

    /// 60 frames a second from the host, arriving in pairs: every second frame is 14 ms
    /// late and lands right before the next one.
    fn paired_arrivals(count: u64) -> Vec<(u64, u64)> {
        (0..count)
            .map(|index| {
                let capture = 10_000 + index * 50 / 3;
                let late = if index % 2 == 1 { 14 } else { 0 };
                (capture, index * 50 / 3 + late)
            })
            .collect()
    }

    #[test]
    fn frames_that_arrive_in_pairs_are_shown_evenly() {
        let frames = paired_arrivals(120);
        let (unpaced, _) = play(&frames, 3, false);
        let (paced, span) = play(&frames, 3, true);
        // As it was: a long interval and a short one in turn.
        let before = intervals(&unpaced);
        assert!(before.iter().any(|interval| *interval <= 5), "{:?}", before);
        assert!(
            before.iter().any(|interval| *interval >= 28),
            "{:?}",
            before
        );
        // Paced: the host's 16 or 17 ms.
        let after = intervals(&paced);
        assert!(
            after[5..]
                .iter()
                .all(|interval| (16..=17).contains(interval)),
            "{:?}",
            after
        );
        // And the queue never holds a frame near the age at which it would be dropped.
        assert!(span <= 67, "{}", span);
    }

    #[test]
    fn after_a_stall_the_picture_catches_up_and_no_frame_grows_stale() {
        // Even 60 frames a second, then nothing for 80 ms, then the missing frames together.
        let mut frames: Vec<(u64, u64)> = (0..90u64)
            .map(|index| (10_000 + index * 50 / 3, index * 50 / 3))
            .collect();
        let stall_from = 500;
        let stall = 80;
        for (_, arrival) in frames.iter_mut() {
            if *arrival >= stall_from && *arrival < stall_from + stall {
                *arrival = stall_from + stall;
            }
        }
        let (_, unpaced_span) = play(&frames, 3, false);
        let (paced, paced_span) = play(&frames, 3, true);
        // No frame waits in the queue until it is more than 100 ms older than the newest
        // (the age at which Movie drops it and asks for a keyframe), with or without pacing.
        assert!(unpaced_span <= 100, "{}", unpaced_span);
        assert!(paced_span <= 100, "{}", paced_span);
        // The frames of the stall are shown as fast as they decode, and the last of them
        // is on the schedule it had before the stall: 50 ms after it would have arrived.
        let after = intervals(&paced);
        assert!(
            after.iter().filter(|interval| **interval <= 5).count() >= 2,
            "{:?}",
            after
        );
        let last_stalled = frames
            .iter()
            .rposition(|(_, arrival)| *arrival == stall_from + stall)
            .unwrap_or_default();
        let on_time_arrival = frames[last_stalled].0 - 10_000;
        assert_eq!(paced[last_stalled], on_time_arrival + 50, "{:?}", paced);
        // A second later the picture is still 50 ms behind the arrival, evenly.
        let last = frames.len() - 1;
        let delay = paced[last] - frames[last].1;
        assert!((45..=55).contains(&delay), "{}", delay);
        assert!(
            after[after.len() - 10..]
                .iter()
                .all(|interval| (16..=17).contains(interval)),
            "{:?}",
            after
        );
    }

    #[test]
    fn decoder_that_cannot_keep_up_is_never_held() {
        // 20 ms to decode a frame that comes every 16.7 ms.
        let frames: Vec<(u64, u64)> = (0..60u64)
            .map(|index| (10_000 + index * 50 / 3, index * 50 / 3))
            .collect();
        let (unpaced, _) = play(&frames, 20, false);
        let (paced, _) = play(&frames, 20, true);
        // At the start there is still time to spare and frames are held; once the picture
        // is behind, a frame is shown the moment it is decoded.
        assert!(
            intervals(&paced)[30..]
                .iter()
                .all(|interval| *interval == 20),
            "{:?}",
            paced
        );
        // What the holds at the start added is never more than the limit.
        for (paced, unpaced) in paced.iter().zip(&unpaced) {
            assert!(paced - unpaced <= BACKLOG_LIMIT.as_millis() as u64);
        }
    }
}
