//! Decoded frames that no view drew.
//!
//! A frame of a display goes to the render target that a view registered for that display.
//! When no view shows the display, or the view's target was registered for another display,
//! the frame is dropped without a word: the screen stays empty while the host sees every
//! frame decoded. The video thread says so in the log once the frames of a stream have gone
//! undrawn for a while, and again each time drawing stops after it had resumed.

use std::time::{Duration, Instant};

/// Frames have to go undrawn for this long before it is reported.
pub(crate) const REPORT_AFTER: Duration = Duration::from_secs(3);

#[derive(Debug, Default)]
pub(crate) struct UndrawnFrames {
    stream_id: u64,
    since: Option<Instant>,
    frames: u64,
    reported: bool,
}

/// What to put in the log.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct UndrawnReport {
    pub(crate) stream_id: u64,
    pub(crate) frames: u64,
    pub(crate) undrawn_for: Duration,
}

impl UndrawnFrames {
    /// A decoded frame of `stream_id` was offered to the views; `drawn` when one took it.
    pub(crate) fn offered(
        &mut self,
        stream_id: u64,
        drawn: bool,
        now: Instant,
    ) -> Option<UndrawnReport> {
        if stream_id != self.stream_id {
            *self = Self {
                stream_id,
                ..Self::default()
            };
        }
        if drawn {
            self.since = None;
            self.frames = 0;
            self.reported = false;
            return None;
        }
        let since = *self.since.get_or_insert(now);
        self.frames = self.frames.saturating_add(1);
        let undrawn_for = now.saturating_duration_since(since);
        if self.reported || undrawn_for < REPORT_AFTER {
            return None;
        }
        self.reported = true;
        Some(UndrawnReport {
            stream_id,
            frames: self.frames,
            undrawn_for,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(start: Instant, millis: u64) -> Instant {
        start + Duration::from_millis(millis)
    }

    /// The case seen on 2026-11-24: the window that took the session over after login drew
    /// display 1 while the session showed display 0; 89 frames decoded, none drawn, no log.
    #[test]
    fn frames_no_view_draws_are_reported_once() {
        let start = Instant::now();
        let mut undrawn = UndrawnFrames::default();
        let mut reports = Vec::new();
        for frame in 0..100 {
            if let Some(report) = undrawn.offered(10, false, at(start, frame * 100)) {
                reports.push(report);
            }
        }
        assert_eq!(
            reports,
            vec![UndrawnReport {
                stream_id: 10,
                frames: 31,
                undrawn_for: Duration::from_secs(3),
            }]
        );
    }

    #[test]
    fn a_drawn_frame_starts_the_count_again() {
        let start = Instant::now();
        let mut undrawn = UndrawnFrames::default();
        assert_eq!(undrawn.offered(10, false, at(start, 0)), None);
        assert_eq!(undrawn.offered(10, true, at(start, 2_000)), None);
        assert_eq!(undrawn.offered(10, false, at(start, 2_500)), None);
        assert_eq!(undrawn.offered(10, false, at(start, 4_900)), None);
        assert!(undrawn.offered(10, false, at(start, 5_500)).is_some());
    }

    #[test]
    fn drawing_that_stops_again_is_reported_again() {
        let start = Instant::now();
        let mut undrawn = UndrawnFrames::default();
        undrawn.offered(10, false, at(start, 0));
        assert!(undrawn.offered(10, false, at(start, 3_000)).is_some());
        assert_eq!(undrawn.offered(10, true, at(start, 3_100)), None);
        undrawn.offered(10, false, at(start, 3_200));
        assert!(undrawn.offered(10, false, at(start, 6_200)).is_some());
    }

    #[test]
    fn a_new_stream_starts_the_count_again() {
        let start = Instant::now();
        let mut undrawn = UndrawnFrames::default();
        undrawn.offered(10, false, at(start, 0));
        assert_eq!(undrawn.offered(11, false, at(start, 3_000)), None);
        assert!(undrawn.offered(11, false, at(start, 6_000)).is_some());
    }
}
