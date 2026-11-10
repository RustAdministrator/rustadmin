//! Pure capture-backend recovery policy used by the portable SYSTEM helper.
//!
//! The caller supplies elapsed time so this policy remains independent of
//! Windows desktop state, shared memory, and clipboard access.

use std::time::Duration;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CaptureBackend {
    Dxgi,
    Gdi,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum CaptureRecoveryAction {
    Wait,
    FallbackToGdi,
    FailHelper,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct CaptureRecoveryPolicy {
    backend: Option<CaptureBackend>,
    first_frame_received: bool,
    // A forced-GDI decision remains in force until this helper policy is retired.
    gdi_required: bool,
}

impl CaptureRecoveryPolicy {
    pub(crate) fn reset_for_rebind(&mut self) {
        self.backend = None;
        self.first_frame_received = false;
        self.gdi_required = true;
    }

    pub(crate) fn reset_for_recreation(&mut self) {
        self.backend = None;
        self.first_frame_received = false;
    }

    pub(crate) fn require_gdi(&mut self) {
        self.gdi_required = true;
    }

    pub(crate) fn gdi_required(&self) -> bool {
        self.gdi_required
    }

    pub(crate) fn backend_created(&mut self, backend: CaptureBackend) -> bool {
        if self.gdi_required && backend == CaptureBackend::Dxgi {
            return false;
        }
        self.backend = Some(backend);
        self.first_frame_received = false;
        true
    }

    pub(crate) fn first_frame_received(&self) -> bool {
        self.first_frame_received
    }

    pub(crate) fn frame_succeeded(&mut self) {
        self.first_frame_received = true;
    }

    pub(crate) fn no_frame_action(
        &self,
        elapsed: Duration,
        first_frame_deadline: Duration,
    ) -> CaptureRecoveryAction {
        if self.first_frame_received || elapsed < first_frame_deadline {
            return CaptureRecoveryAction::Wait;
        }
        match self.backend {
            Some(CaptureBackend::Dxgi) => CaptureRecoveryAction::FallbackToGdi,
            Some(CaptureBackend::Gdi) => CaptureRecoveryAction::FailHelper,
            None => CaptureRecoveryAction::FailHelper,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{CaptureBackend, CaptureRecoveryAction, CaptureRecoveryPolicy};
    use std::time::Duration;

    const DEADLINE: Duration = Duration::from_secs(2);

    #[test]
    fn rebind_reset_rearms_deadline_and_requires_gdi() {
        let mut policy = CaptureRecoveryPolicy::default();
        assert!(policy.backend_created(CaptureBackend::Dxgi));
        policy.frame_succeeded();
        assert_eq!(
            policy.no_frame_action(DEADLINE, DEADLINE),
            CaptureRecoveryAction::Wait
        );

        policy.reset_for_rebind();
        assert!(!policy.first_frame_received());
        assert!(policy.gdi_required());
        assert_eq!(
            policy.no_frame_action(DEADLINE - Duration::from_millis(1), DEADLINE),
            CaptureRecoveryAction::Wait
        );
        assert!(!policy.backend_created(CaptureBackend::Dxgi));
        assert!(policy.backend_created(CaptureBackend::Gdi));
        policy.frame_succeeded();
        policy.reset_for_recreation();
        assert!(!policy.backend_created(CaptureBackend::Dxgi));
        assert!(policy.backend_created(CaptureBackend::Gdi));
    }

    #[test]
    fn dxgi_timeout_requests_one_gdi_fallback() {
        let mut policy = CaptureRecoveryPolicy::default();
        assert!(policy.backend_created(CaptureBackend::Dxgi));
        assert_eq!(
            policy.no_frame_action(DEADLINE, DEADLINE),
            CaptureRecoveryAction::FallbackToGdi
        );

        policy.require_gdi();
        policy.reset_for_recreation();
        assert!(policy.backend_created(CaptureBackend::Gdi));
        assert_eq!(
            policy.no_frame_action(DEADLINE, DEADLINE),
            CaptureRecoveryAction::FailHelper
        );
    }

    #[test]
    fn gdi_timeout_requests_existing_failure_path() {
        let mut policy = CaptureRecoveryPolicy::default();
        assert!(policy.backend_created(CaptureBackend::Gdi));
        assert_eq!(
            policy.no_frame_action(DEADLINE, DEADLINE),
            CaptureRecoveryAction::FailHelper
        );
    }

    #[test]
    fn frame_success_disarms_timeout_but_recreation_rearms_it() {
        let mut policy = CaptureRecoveryPolicy::default();
        assert!(policy.backend_created(CaptureBackend::Dxgi));
        assert_eq!(
            policy.no_frame_action(DEADLINE, DEADLINE),
            CaptureRecoveryAction::FallbackToGdi
        );

        policy.frame_succeeded();
        assert_eq!(
            policy.no_frame_action(DEADLINE * 2, DEADLINE),
            CaptureRecoveryAction::Wait
        );

        policy.reset_for_recreation();
        assert!(policy.backend_created(CaptureBackend::Dxgi));
        assert_eq!(
            policy.no_frame_action(DEADLINE, DEADLINE),
            CaptureRecoveryAction::FallbackToGdi
        );
    }

    #[test]
    fn ordinary_would_block_after_success_stays_idle() {
        let mut policy = CaptureRecoveryPolicy::default();
        assert!(policy.backend_created(CaptureBackend::Gdi));
        policy.frame_succeeded();
        assert_eq!(
            policy.no_frame_action(DEADLINE * 10, DEADLINE),
            CaptureRecoveryAction::Wait
        );
    }

    #[test]
    fn backend_creation_timeout_requests_existing_failure_path() {
        let policy = CaptureRecoveryPolicy::default();
        assert_eq!(
            policy.no_frame_action(DEADLINE - Duration::from_millis(1), DEADLINE),
            CaptureRecoveryAction::Wait
        );
        assert_eq!(
            policy.no_frame_action(DEADLINE, DEADLINE),
            CaptureRecoveryAction::FailHelper
        );
    }
}
