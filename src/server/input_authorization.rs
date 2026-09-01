#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum RemoteInputKind {
    Mouse,
    Pointer,
    Keyboard,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum RemoteInputDecision {
    Deny,
    CursorOnly,
    Control,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct RemoteInputAuthorizationOutcome {
    pub decision: RemoteInputDecision,
    pub reset_required: bool,
}

#[derive(Default)]
pub(crate) struct RemoteInputAuthorizationGate {
    platform_state_dirty: bool,
}

impl RemoteInputAuthorizationGate {
    pub fn evaluate(
        &mut self,
        kind: RemoteInputKind,
        view_camera_session: bool,
        blocked_by_permission_prompt: bool,
        keyboard_enabled: bool,
        show_cursor: bool,
    ) -> RemoteInputAuthorizationOutcome {
        let decision = if view_camera_session || blocked_by_permission_prompt {
            RemoteInputDecision::Deny
        } else if keyboard_enabled {
            RemoteInputDecision::Control
        } else if kind == RemoteInputKind::Mouse && show_cursor {
            RemoteInputDecision::CursorOnly
        } else {
            RemoteInputDecision::Deny
        };
        let reset_required = decision != RemoteInputDecision::Control && self.revoke();
        if decision == RemoteInputDecision::Control {
            self.platform_state_dirty = true;
        }
        RemoteInputAuthorizationOutcome {
            decision,
            reset_required,
        }
    }

    pub fn revoke(&mut self) -> bool {
        std::mem::take(&mut self.platform_state_dirty)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn denies_control_before_platform_dispatch() {
        for kind in [
            RemoteInputKind::Mouse,
            RemoteInputKind::Pointer,
            RemoteInputKind::Keyboard,
        ] {
            let mut gate = RemoteInputAuthorizationGate::default();
            assert_eq!(
                gate.evaluate(kind, true, false, true, true).decision,
                RemoteInputDecision::Deny
            );
            assert_eq!(
                gate.evaluate(kind, false, true, true, true).decision,
                RemoteInputDecision::Deny
            );
            assert_eq!(
                gate.evaluate(kind, false, false, false, false).decision,
                RemoteInputDecision::Deny
            );
        }
    }

    #[test]
    fn preserves_mouse_cursor_only_mode() {
        let mut gate = RemoteInputAuthorizationGate::default();
        assert_eq!(
            gate.evaluate(RemoteInputKind::Mouse, false, false, false, true),
            RemoteInputAuthorizationOutcome {
                decision: RemoteInputDecision::CursorOnly,
                reset_required: false,
            }
        );
        assert_eq!(
            gate.evaluate(RemoteInputKind::Pointer, false, false, false, true)
                .decision,
            RemoteInputDecision::Deny
        );
        assert_eq!(
            gate.evaluate(RemoteInputKind::Keyboard, false, false, false, true)
                .decision,
            RemoteInputDecision::Deny
        );
    }

    #[test]
    fn requests_one_reset_per_control_epoch() {
        let mut gate = RemoteInputAuthorizationGate::default();
        assert_eq!(
            gate.evaluate(RemoteInputKind::Keyboard, false, false, true, false),
            RemoteInputAuthorizationOutcome {
                decision: RemoteInputDecision::Control,
                reset_required: false,
            }
        );
        assert_eq!(
            gate.evaluate(RemoteInputKind::Mouse, false, true, true, false),
            RemoteInputAuthorizationOutcome {
                decision: RemoteInputDecision::Deny,
                reset_required: true,
            }
        );
        assert!(!gate.revoke());
        assert_eq!(
            gate.evaluate(RemoteInputKind::Pointer, false, false, true, false)
                .decision,
            RemoteInputDecision::Control
        );
        assert!(gate.revoke());
        assert!(!gate.revoke());
    }
}
