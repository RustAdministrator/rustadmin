use std::time::{Duration, Instant};

const OUTPUT_STALL_TIMEOUT: Duration = Duration::from_secs(2);
const INITIAL_RETRY_DELAY: Duration = Duration::from_millis(500);
const MAX_RETRY_DELAY: Duration = Duration::from_secs(5);

pub(super) fn frame_is_current(
    current_stream: u64,
    previous_frame: u64,
    stream: u64,
    frame: u64,
) -> bool {
    if current_stream != 0 && (stream == 0 || stream < current_stream) {
        return false;
    }
    stream == 0 || stream != current_stream || frame == 0 || frame > previous_frame
}

/// Owned by one display's video worker, never by codec capability discovery.
#[derive(Default)]
pub(super) struct DecoderRecovery {
    next_retry: Option<Instant>,
    attempt: usize,
    waiting_for_keyframe: bool,
    needs_reset: bool,
}

impl DecoderRecovery {
    pub(super) fn failed(&mut self, now: Instant) {
        if self.attempt == 0 {
            self.next_retry = Some(now);
        }
        self.waiting_for_keyframe = true;
        self.needs_reset = true;
    }

    pub(super) fn pending(&mut self, now: Instant) {
        if self.next_retry.is_none() {
            self.next_retry = Some(now + OUTPUT_STALL_TIMEOUT);
        }
    }

    pub(super) fn succeeded(&mut self) {
        *self = Self::default();
    }

    pub(super) fn take_due(&mut self, now: Instant) -> Option<usize> {
        if now < self.next_retry? {
            return None;
        }
        self.attempt = self.attempt.saturating_add(1);
        let delay = INITIAL_RETRY_DELAY
            .saturating_mul(1 << self.attempt.saturating_sub(1).min(4))
            .min(MAX_RETRY_DELAY);
        self.next_retry = Some(now + delay);
        self.waiting_for_keyframe = true;
        self.needs_reset = false;
        Some(self.attempt)
    }

    pub(super) fn wait_duration(&self, now: Instant) -> Option<Duration> {
        self.next_retry
            .map(|next| next.saturating_duration_since(now))
    }

    pub(super) fn accepts_frame(&mut self, stamped: bool, has_keyframe: bool) -> bool {
        if self.needs_reset || (self.waiting_for_keyframe && stamped && !has_keyframe) {
            return false;
        }
        // Older hosts may omit frame IDs/key flags; keep their refresh path usable.
        self.waiting_for_keyframe = false;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_error_retries_locally_without_waiting_for_more_input() {
        let now = Instant::now();
        let mut recovery = DecoderRecovery::default();
        assert_eq!(recovery.wait_duration(now), None);
        recovery.failed(now);
        assert_eq!(recovery.wait_duration(now), Some(Duration::ZERO));
        assert!(!recovery.accepts_frame(true, true));
        assert_eq!(recovery.take_due(now), Some(1));
        assert!(!recovery.accepts_frame(true, false));
        assert!(recovery.accepts_frame(true, true));
    }

    #[test]
    fn repeated_errors_do_not_bypass_backoff() {
        let now = Instant::now();
        let mut recovery = DecoderRecovery::default();
        recovery.failed(now);
        assert_eq!(recovery.take_due(now), Some(1));
        for _ in 0..100 {
            recovery.failed(now + Duration::from_millis(10));
            assert_eq!(recovery.take_due(now + Duration::from_millis(10)), None);
        }
        assert_eq!(recovery.take_due(now + INITIAL_RETRY_DELAY), Some(2));
    }

    #[test]
    fn retries_remain_bounded_but_can_recover_after_long_gpu_outage() {
        let mut now = Instant::now();
        let mut recovery = DecoderRecovery::default();
        recovery.failed(now);
        for attempt in 1..=30 {
            assert_eq!(recovery.take_due(now), Some(attempt));
            let delay = recovery.wait_duration(now).unwrap();
            assert!((INITIAL_RETRY_DELAY..=MAX_RETRY_DELAY).contains(&delay));
            now += delay;
        }
        assert!(recovery.accepts_frame(true, true));
        recovery.succeeded();
        assert_eq!(recovery.wait_duration(now), None);
        assert!(recovery.accepts_frame(true, false));
    }

    #[test]
    fn pending_output_is_not_an_error_but_cannot_stall_forever() {
        let now = Instant::now();
        let mut recovery = DecoderRecovery::default();
        recovery.pending(now);
        assert!(recovery.accepts_frame(true, false));
        assert_eq!(recovery.take_due(now + Duration::from_secs(1)), None);
        recovery.pending(now + Duration::from_secs(1));
        assert_eq!(recovery.take_due(now + OUTPUT_STALL_TIMEOUT), Some(1));
    }

    #[test]
    fn successful_output_cancels_pending_and_failure_timers() {
        let now = Instant::now();
        let mut recovery = DecoderRecovery::default();
        recovery.pending(now);
        recovery.succeeded();
        assert_eq!(recovery.take_due(now + OUTPUT_STALL_TIMEOUT), None);
        recovery.failed(now);
        recovery.take_due(now);
        recovery.succeeded();
        assert_eq!(recovery.take_due(now + MAX_RETRY_DELAY), None);
    }

    #[test]
    fn one_display_failure_does_not_change_another_display() {
        let now = Instant::now();
        let mut a = DecoderRecovery::default();
        let mut b = DecoderRecovery::default();
        a.failed(now);
        assert_eq!(a.take_due(now), Some(1));
        assert_eq!(b.take_due(now), None);
        assert!(b.accepts_frame(true, false));
        b.succeeded();
        assert!(!a.accepts_frame(true, false));
    }

    #[test]
    fn legacy_unstamped_frames_remain_usable_after_refresh() {
        let now = Instant::now();
        let mut recovery = DecoderRecovery::default();
        recovery.failed(now);
        recovery.take_due(now);
        assert!(recovery.accepts_frame(false, false));
    }

    #[test]
    fn queued_old_frames_cannot_replace_a_recovered_stream() {
        assert!(!frame_is_current(12, 3, 11, 50));
        assert!(!frame_is_current(12, 3, 0, 0));
        assert!(!frame_is_current(12, 3, 12, 2));
        assert!(!frame_is_current(12, 3, 12, 3));
        assert!(frame_is_current(12, 3, 12, 4));
        assert!(frame_is_current(12, 3, 13, 1));
        assert!(frame_is_current(0, 0, 0, 0));
        assert!(frame_is_current(0, 50, 0, 1));
    }
}
