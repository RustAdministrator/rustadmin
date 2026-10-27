use hbb_common::resource_policy::ResourceMode;
use std::collections::BTreeMap;

/// Connection-owned visibility. Losing keyboard focus is not a visibility change.
#[derive(Default)]
pub(crate) struct ViewerResources {
    views: BTreeMap<String, bool>,
    /// Cached local viewer policy used for decoder construction and capability
    /// filtering. This is never strengthened by a remote request or host
    /// telemetry.
    pub local_mode: ResourceMode,
    /// Cached local-plus-remote request sent upstream to the host.
    pub combined_mode: ResourceMode,
    /// Cached local-plus-remote-plus-host effective policy used for suspension
    /// and local Movie projection.
    pub effective_mode: ResourceMode,
    /// The last host policy reported by TestDelay. Empty/legacy reports map to
    /// Normal so an older host cannot leave a stale runtime restriction behind.
    pub actual_host_mode: ResourceMode,
    pub suspended: bool,
}

impl ViewerResources {
    pub fn update_view(&mut self, owner: String, visible: Option<bool>) {
        if owner.is_empty() {
            return;
        }
        match visible {
            Some(visible) => {
                self.views.insert(owner, visible);
            }
            None => {
                self.views.remove(&owner);
            }
        }
    }

    pub fn set_actual_host_mode(&mut self, mode: ResourceMode) -> bool {
        if self.actual_host_mode == mode {
            return false;
        }
        self.actual_host_mode = mode;
        true
    }

    pub fn reset_runtime(&mut self) {
        self.local_mode = ResourceMode::Normal;
        self.combined_mode = ResourceMode::Normal;
        self.effective_mode = ResourceMode::Normal;
        self.actual_host_mode = ResourceMode::Normal;
        self.suspended = false;
    }

    pub fn has_visible_view(&self) -> bool {
        self.views.is_empty() || self.views.values().any(|visible| *visible)
    }

    pub fn should_suspend_with_modes(
        &self,
        local: ResourceMode,
        requested: ResourceMode,
        actual_host: ResourceMode,
        recording: bool,
    ) -> bool {
        let constrained = local != ResourceMode::Normal
            || requested != ResourceMode::Normal
            || actual_host != ResourceMode::Normal;
        constrained && !recording && !self.has_visible_view()
    }

    pub fn should_suspend(&self, mode: ResourceMode, recording: bool) -> bool {
        self.should_suspend_with_modes(mode, mode, mode, recording)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resource_visibility_preserves_other_windows_and_recording() {
        let mut state = ViewerResources::default();
        assert!(!state.should_suspend(ResourceMode::LowPower, false));
        state.update_view("tab-a".into(), Some(false));
        assert!(state.should_suspend(ResourceMode::LowPower, false));
        assert!(!state.should_suspend(ResourceMode::Normal, false));
        assert!(!state.should_suspend(ResourceMode::MinimizeGpu, true));
        state.update_view("window-b".into(), Some(true));
        assert!(!state.should_suspend(ResourceMode::MinimizeGpu, false));
        state.update_view("window-b".into(), None);
        assert!(state.should_suspend(ResourceMode::MinimizeGpu, false));
        state.update_view("tab-a".into(), Some(true));
        assert!(!state.should_suspend(ResourceMode::LowPower, false));
        state.update_view("tab-a".into(), None);
        assert!(!state.should_suspend(ResourceMode::LowPower, false));
    }

    #[test]
    fn empty_visibility_map_keeps_legacy_viewers_visible() {
        let state = ViewerResources::default();
        assert!(state.has_visible_view());
        assert!(!state.should_suspend_with_modes(
            ResourceMode::LowPower,
            ResourceMode::LowPower,
            ResourceMode::LowPower,
            false
        ));
    }

    #[test]
    fn any_resource_policy_source_can_suspend_hidden_views() {
        let mut state = ViewerResources::default();
        state.update_view("viewer".to_owned(), Some(false));
        assert!(state.should_suspend_with_modes(
            ResourceMode::Normal,
            ResourceMode::Normal,
            ResourceMode::LowPower,
            false
        ));
        assert!(state.should_suspend_with_modes(
            ResourceMode::LowPower,
            ResourceMode::Normal,
            ResourceMode::Normal,
            false
        ));
        assert!(!state.should_suspend_with_modes(
            ResourceMode::LowPower,
            ResourceMode::Normal,
            ResourceMode::Normal,
            true
        ));
    }

    #[test]
    fn actual_host_mode_cache_resets_for_reconnect() {
        let mut state = ViewerResources::default();
        assert!(state.set_actual_host_mode(ResourceMode::MinimizeGpu));
        assert_eq!(state.actual_host_mode, ResourceMode::MinimizeGpu);
        state.local_mode = ResourceMode::MinimizeGpu;
        state.combined_mode = ResourceMode::MinimizeGpu;
        state.effective_mode = ResourceMode::MinimizeGpu;
        state.suspended = true;
        state.reset_runtime();
        assert_eq!(state.actual_host_mode, ResourceMode::Normal);
        assert_eq!(state.local_mode, ResourceMode::Normal);
        assert_eq!(state.combined_mode, ResourceMode::Normal);
        assert_eq!(state.effective_mode, ResourceMode::Normal);
        assert!(!state.suspended);
    }
}
