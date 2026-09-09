//! Startup recovery has one budget per display activation, not per timer or stream.
use hbb_common::tokio::time::{Duration, Instant};

pub(super) const FIRST_CAPTURE_RETRY: Duration = Duration::from_secs(15);
pub(super) const CAPTURE_RETRY_INTERVAL: Duration = Duration::from_secs(40);
const REFERENCE_INTERVAL: Duration = Duration::from_millis(750);
const DECODE_GRACE: Duration = Duration::from_secs(3);
const MAX_REFERENCES: usize = 3;
const MAX_CAPTURE_RETRIES: usize = 2;
const STARTUP_LIMIT: Duration = Duration::from_secs(110);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum StartupRecoveryAction {
    Reference,
    Capture,
    Failed,
}

#[derive(Debug, Default)]
pub(super) struct StartupRecovery {
    since: Option<Instant>,
    last_action: Option<Instant>,
    last_try: Option<Instant>,
    last_capture: Option<Instant>,
    keyframe_at: Option<Instant>,
    reference_attempts: usize,
    capture_attempts: usize,
    decoded: bool,
    failed: bool,
    pub dropped_deltas: u64,
}

impl StartupRecovery {
    pub(super) fn new_stream(&mut self, now: Instant) {
        // A stream that never decodes must not replenish its retry budget by
        // provoking host restarts. A previously decoded stream starts a new episode.
        if self.decoded {
            *self = Self::default();
        }
        self.keyframe_at = None;
        self.since.get_or_insert(now);
    }

    pub(super) fn received(&mut self, keyframe: bool, dropped_delta: bool, now: Instant) {
        self.since.get_or_insert(now);
        if keyframe {
            self.keyframe_at.get_or_insert(now);
        }
        if dropped_delta {
            self.dropped_deltas = self.dropped_deltas.saturating_add(1);
        }
    }

    pub(super) fn decoded(&mut self) {
        self.decoded = true;
        self.failed = false;
    }

    pub(super) fn is_failed(&self) -> bool {
        self.failed
    }

    pub(super) fn next(
        &mut self,
        now: Instant,
        known_stream: bool,
        scoped_supported: bool,
    ) -> Option<StartupRecoveryAction> {
        if self.decoded || self.failed {
            return None;
        }
        let since = *self.since.get_or_insert(now);
        let elapsed = now.saturating_duration_since(since);
        let last_capture_elapsed = self
            .last_capture
            .map(|last| now.saturating_duration_since(last));
        if elapsed >= STARTUP_LIMIT
            || (self.capture_attempts >= MAX_CAPTURE_RETRIES
                && last_capture_elapsed.is_some_and(|age| age >= CAPTURE_RETRY_INTERVAL))
        {
            self.failed = true;
            return Some(StartupRecoveryAction::Failed);
        }
        if self
            .last_try
            .is_some_and(|at| now.saturating_duration_since(at) < REFERENCE_INTERVAL)
        {
            return None;
        }
        if known_stream
            && scoped_supported
            && self.reference_attempts < MAX_REFERENCES
            && self
                .keyframe_at
                .map_or(true, |at| now.saturating_duration_since(at) >= DECODE_GRACE)
            && self.last_action.map_or(true, |at| {
                now.saturating_duration_since(at) >= REFERENCE_INTERVAL
            })
        {
            return Some(StartupRecoveryAction::Reference);
        }
        if elapsed >= FIRST_CAPTURE_RETRY
            && self.capture_attempts < MAX_CAPTURE_RETRIES
            && last_capture_elapsed.map_or(true, |age| age >= CAPTURE_RETRY_INTERVAL)
            && self
                .last_action
                .map_or(true, |at| now.saturating_duration_since(at) >= DECODE_GRACE)
        {
            return Some(StartupRecoveryAction::Capture);
        }
        None
    }

    pub(super) fn admitted(&mut self, action: StartupRecoveryAction, now: Instant) {
        match action {
            StartupRecoveryAction::Reference => self.reference_attempts += 1,
            StartupRecoveryAction::Capture => {
                self.capture_attempts += 1;
                self.last_capture = Some(now);
            }
            StartupRecoveryAction::Failed => return,
        }
        self.last_action = Some(now);
    }

    pub(super) fn attempted(&mut self, now: Instant) {
        self.last_try = Some(now);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn delta_only_recovery_uses_bounded_reference_then_capture_ladder() {
        let start = Instant::now();
        let mut p = StartupRecovery::default();
        let mut actions = Vec::new();
        for second in 0..1000 {
            let now = start + Duration::from_secs(second);
            // Changing the host stream does not evade the activation budget.
            p.new_stream(now);
            p.received(false, true, now);
            if let Some(action) = p.next(now, true, true) {
                p.admitted(action, now);
                actions.push(action);
            }
        }
        assert_eq!(
            actions,
            vec![StartupRecoveryAction::Reference; 3]
                .into_iter()
                .chain([
                    StartupRecoveryAction::Capture,
                    StartupRecoveryAction::Capture,
                    StartupRecoveryAction::Failed
                ])
                .collect::<Vec<_>>()
        );
        assert!(p.is_failed());
    }

    #[test]
    fn no_frames_and_legacy_peers_never_fabricate_reference_identity() {
        for (known, supported) in [(false, true), (false, false), (true, false)] {
            let start = Instant::now();
            let mut p = StartupRecovery::default();
            assert_eq!(p.next(start, known, supported), None);
            assert_eq!(
                p.next(start + FIRST_CAPTURE_RETRY, known, supported),
                Some(StartupRecoveryAction::Capture)
            );
            p.admitted(StartupRecoveryAction::Capture, start + FIRST_CAPTURE_RETRY);
            assert_eq!(
                p.next(
                    start + FIRST_CAPTURE_RETRY + Duration::from_secs(30),
                    known,
                    supported
                ),
                None
            );
        }
    }

    #[test]
    fn failed_admission_does_not_spend_budget_but_total_wait_is_bounded() {
        let start = Instant::now();
        let mut p = StartupRecovery::default();
        for ms in 0..1000 {
            assert_eq!(
                p.next(start + Duration::from_millis(ms), true, true),
                Some(StartupRecoveryAction::Reference)
            );
        }
        assert_eq!(
            p.next(start + STARTUP_LIMIT, true, true),
            Some(StartupRecoveryAction::Failed)
        );
        assert_eq!(p.next(start + STARTUP_LIMIT * 2, true, true), None);
    }

    #[test]
    fn receiving_keyframe_is_not_decode_success_and_late_decode_can_recover() {
        let start = Instant::now();
        let mut p = StartupRecovery::default();
        p.received(true, false, start);
        assert_eq!(p.next(start, true, true), None);
        assert_eq!(
            p.next(start + DECODE_GRACE, true, true),
            Some(StartupRecoveryAction::Reference)
        );
        assert_eq!(
            p.next(start + STARTUP_LIMIT, true, true),
            Some(StartupRecoveryAction::Failed)
        );
        p.decoded();
        assert!(!p.is_failed());
        assert_eq!(p.next(start + STARTUP_LIMIT, true, true), None);
        p.new_stream(start + STARTUP_LIMIT);
        assert_eq!(
            p.next(start + STARTUP_LIMIT, true, true),
            Some(StartupRecoveryAction::Reference)
        );
    }
}
