use hbb_common::resource_policy::ResourceMode;
use std::{
    collections::BTreeMap,
    time::{Duration, Instant},
};

/// Connection-owned visibility. Losing keyboard focus is not a visibility change.
#[derive(Default)]
pub(crate) struct ViewerResources {
    views: BTreeMap<String, bool>,
    /// Cached local viewer policy used for decoder construction and capability
    /// filtering. This is never strengthened by a remote request or host
    /// telemetry.
    pub local_mode: ResourceMode,
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
        self.actual_host_mode = ResourceMode::Normal;
        self.suspended = false;
    }

    pub fn has_visible_view(&self) -> bool {
        self.views.is_empty() || self.views.values().any(|visible| *visible)
    }

    /// Both ends must support Movie pacing, but host telemetry is never a
    /// local decoder, presentation-rate, or visibility policy.
    pub fn movie_resource_mode(&self) -> ResourceMode {
        self.local_mode.strongest(self.actual_host_mode)
    }

    pub fn should_suspend(&self, mode: ResourceMode, recording: bool) -> bool {
        mode != ResourceMode::Normal && !recording && !self.has_visible_view()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct PendingPresentation {
    pub stream_id: u64,
    pub frame_id: u64,
    pub pixelbuffer: bool,
}

/// Coalesce decoded output, never encoded input. A final pending frame has a
/// deadline even when no more packets arrive, so the desktop cannot stay stale.
#[derive(Default)]
pub(crate) struct ViewerPresentation {
    pending: Option<PendingPresentation>,
    last_presented: Option<Instant>,
}

impl ViewerPresentation {
    pub fn queue(&mut self, frame: PendingPresentation) {
        self.pending = Some(frame);
    }

    pub fn clear(&mut self) {
        self.pending = None;
        self.last_presented = None;
    }

    pub fn wait_duration(&self, mode: ResourceMode, now: Instant) -> Option<Duration> {
        self.pending?;
        let remaining = match (mode.active_fps_cap(), self.last_presented) {
            (Some(fps), Some(last)) => Duration::from_secs_f64(1.0 / f64::from(fps))
                .saturating_sub(now.saturating_duration_since(last)),
            _ => Duration::ZERO,
        };
        Some(remaining)
    }

    pub fn take_due(&mut self, mode: ResourceMode, now: Instant) -> Option<PendingPresentation> {
        if self.wait_duration(mode, now)? != Duration::ZERO {
            return None;
        }
        self.last_presented = Some(now);
        self.pending.take()
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
        assert!(!state.should_suspend(ResourceMode::LowPower, false));
    }

    #[test]
    fn host_policy_does_not_suspend_or_constrain_a_normal_viewer() {
        let mut state = ViewerResources::default();
        state.update_view("viewer".to_owned(), Some(false));
        state.set_actual_host_mode(ResourceMode::MinimizeGpu);
        assert!(!state.should_suspend(ResourceMode::Normal, false));
        assert_eq!(state.local_mode, ResourceMode::Normal);
        assert!(state.should_suspend(ResourceMode::LowPower, false));
        assert!(!state.should_suspend(ResourceMode::LowPower, true));
    }

    #[test]
    fn actual_host_mode_cache_resets_for_reconnect() {
        let mut state = ViewerResources::default();
        assert!(state.set_actual_host_mode(ResourceMode::MinimizeGpu));
        assert_eq!(state.actual_host_mode, ResourceMode::MinimizeGpu);
        state.local_mode = ResourceMode::MinimizeGpu;
        state.suspended = true;
        state.reset_runtime();
        assert_eq!(state.actual_host_mode, ResourceMode::Normal);
        assert_eq!(state.local_mode, ResourceMode::Normal);
        assert!(!state.suspended);
    }

    #[test]
    fn local_presentation_coalesces_output_and_flushes_the_last_frame() {
        let now = Instant::now();
        let mut presentation = ViewerPresentation::default();
        let frame = |frame_id| PendingPresentation {
            stream_id: 1,
            frame_id,
            pixelbuffer: true,
        };
        assert_eq!(
            presentation.wait_duration(ResourceMode::LowPower, now),
            None
        );
        presentation.queue(frame(1));
        assert_eq!(
            presentation.take_due(ResourceMode::LowPower, now),
            Some(frame(1))
        );
        for frame_id in 2..=6 {
            presentation.queue(frame(frame_id));
            assert_eq!(
                presentation.take_due(
                    ResourceMode::LowPower,
                    now + Duration::from_millis(frame_id * 10)
                ),
                None
            );
        }
        assert_eq!(
            presentation.wait_duration(ResourceMode::LowPower, now + Duration::from_millis(60)),
            Some(Duration::from_millis(40))
        );
        assert_eq!(
            presentation.take_due(ResourceMode::LowPower, now + Duration::from_millis(100)),
            Some(frame(6))
        );
        assert_eq!(
            presentation.wait_duration(ResourceMode::LowPower, now + Duration::from_millis(100)),
            None
        );
    }

    #[test]
    fn normal_viewer_is_uncapped_and_retired_output_is_cleared() {
        let now = Instant::now();
        let frame = PendingPresentation {
            stream_id: 2,
            frame_id: 3,
            pixelbuffer: false,
        };
        let mut presentation = ViewerPresentation::default();
        presentation.queue(frame);
        assert_eq!(
            presentation.take_due(ResourceMode::MinimizeGpu, now),
            Some(frame)
        );
        presentation.queue(frame);
        assert_eq!(
            presentation.take_due(ResourceMode::Normal, now),
            Some(frame)
        );
        presentation.queue(frame);
        presentation.clear();
        assert_eq!(presentation.take_due(ResourceMode::Normal, now), None);
        assert_eq!(presentation.wait_duration(ResourceMode::Normal, now), None);
    }
}
