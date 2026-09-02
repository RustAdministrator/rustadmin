use std::collections::{HashMap, HashSet};

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub(crate) struct ClipboardChannelId {
    peer_id: String,
    round: u32,
}

impl ClipboardChannelId {
    fn new(peer_id: &str, round: u32) -> Self {
        Self {
            peer_id: peer_id.to_owned(),
            round,
        }
    }

    #[cfg_attr(test, allow(dead_code))]
    pub(crate) fn into_tuple(self) -> (String, u32) {
        (self.peer_id, self.round)
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct ClipboardChannelPolicy {
    pub(crate) text: bool,
    pub(crate) file: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ClipboardPayloadKind {
    Text,
    File,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum ClipboardSnapshotOrigin {
    Local,
    // Platform owner markers consume remote snapshots before fan-out.
    #[allow(dead_code)]
    Remote(ClipboardChannelId),
}

#[derive(Default)]
pub(crate) struct ClipboardChannelRegistry {
    channels: HashMap<ClipboardChannelId, ClipboardChannelPolicy>,
}

impl ClipboardChannelRegistry {
    pub(crate) fn register(&mut self, peer_id: &str, round: u32, policy: ClipboardChannelPolicy) {
        self.channels
            .insert(ClipboardChannelId::new(peer_id, round), policy);
    }

    pub(crate) fn update(&mut self, peer_id: &str, round: u32, policy: ClipboardChannelPolicy) {
        if let Some(channel) = self
            .channels
            .get_mut(&ClipboardChannelId::new(peer_id, round))
        {
            *channel = policy;
        }
    }

    pub(crate) fn unregister(&mut self, peer_id: &str, round: u32) {
        self.channels
            .remove(&ClipboardChannelId::new(peer_id, round));
    }

    pub(crate) fn has_active(&self) -> bool {
        !self.channels.is_empty()
    }

    pub(crate) fn requires(&self, kind: ClipboardPayloadKind) -> bool {
        self.channels.values().any(|policy| policy.allows(kind))
    }

    pub(crate) fn recipients(
        &self,
        kind: ClipboardPayloadKind,
        origin: ClipboardSnapshotOrigin,
    ) -> HashSet<ClipboardChannelId> {
        match origin {
            ClipboardSnapshotOrigin::Remote(_source) => return HashSet::new(),
            ClipboardSnapshotOrigin::Local => {}
        }
        self.channels
            .iter()
            .filter_map(|(id, policy)| policy.allows(kind).then_some(id.clone()))
            .collect()
    }
}

impl ClipboardChannelPolicy {
    fn allows(self, kind: ClipboardPayloadKind) -> bool {
        match kind {
            ClipboardPayloadKind::Text => self.text,
            ClipboardPayloadKind::File => self.file,
        }
    }
}

#[derive(Default)]
pub(crate) struct ClipboardCoordinator {
    pub(crate) channels: ClipboardChannelRegistry,
    watcher_generation: u64,
    watcher_running: bool,
}

impl ClipboardCoordinator {
    pub(crate) fn begin_watcher(&mut self) -> Option<u64> {
        if self.watcher_running {
            return None;
        }
        self.watcher_generation = self.watcher_generation.wrapping_add(1);
        if self.watcher_generation == 0 {
            self.watcher_generation = 1;
        }
        self.watcher_running = true;
        Some(self.watcher_generation)
    }

    pub(crate) fn stop_watcher(&mut self) {
        self.watcher_running = false;
        self.watcher_generation = self.watcher_generation.wrapping_add(1);
    }

    pub(crate) fn is_current_watcher(&self, generation: u64) -> bool {
        self.watcher_running && self.watcher_generation == generation
    }

    pub(crate) fn finish_watcher(&mut self, generation: u64) {
        if self.watcher_generation == generation {
            self.watcher_running = false;
        }
    }

    pub(crate) fn watcher_running(&self) -> bool {
        self.watcher_running
    }
}

#[cfg(test)]
mod tests {
    use super::{
        ClipboardChannelId, ClipboardChannelPolicy, ClipboardCoordinator, ClipboardPayloadKind,
        ClipboardSnapshotOrigin,
    };

    fn policy(text: bool, file: bool) -> ClipboardChannelPolicy {
        ClipboardChannelPolicy { text, file }
    }

    #[test]
    fn reconnect_round_keeps_new_clipboard_channel_active() {
        let mut coordinator = ClipboardCoordinator::default();
        coordinator
            .channels
            .register("peer", 1, policy(true, false));
        coordinator
            .channels
            .register("peer", 2, policy(true, false));

        coordinator.channels.unregister("peer", 1);

        assert!(coordinator.channels.has_active());
        assert_eq!(
            coordinator
                .channels
                .recipients(ClipboardPayloadKind::Text, ClipboardSnapshotOrigin::Local),
            [ClipboardChannelId::new("peer", 2)].into_iter().collect()
        );
    }

    #[test]
    fn duplicate_registration_updates_policy_without_retaining_a_channel() {
        let mut coordinator = ClipboardCoordinator::default();
        coordinator
            .channels
            .register("peer", 7, policy(true, false));
        coordinator
            .channels
            .register("peer", 7, policy(false, true));

        assert!(!coordinator.channels.requires(ClipboardPayloadKind::Text));
        assert!(coordinator.channels.requires(ClipboardPayloadKind::File));
        coordinator.channels.unregister("peer", 7);
        assert!(!coordinator.channels.has_active());
    }

    #[test]
    fn local_fanout_respects_each_channel_direction_and_capability() {
        let mut coordinator = ClipboardCoordinator::default();
        coordinator
            .channels
            .register("text", 1, policy(true, false));
        coordinator
            .channels
            .register("file", 2, policy(false, true));
        coordinator
            .channels
            .register("receive-only", 3, policy(false, false));

        assert_eq!(
            coordinator
                .channels
                .recipients(ClipboardPayloadKind::Text, ClipboardSnapshotOrigin::Local),
            [ClipboardChannelId::new("text", 1)].into_iter().collect()
        );
        assert_eq!(
            coordinator
                .channels
                .recipients(ClipboardPayloadKind::File, ClipboardSnapshotOrigin::Local),
            [ClipboardChannelId::new("file", 2)].into_iter().collect()
        );
    }

    #[test]
    fn remote_origin_is_applied_locally_but_never_relayed_to_other_sessions() {
        let mut coordinator = ClipboardCoordinator::default();
        coordinator
            .channels
            .register("first", 1, policy(true, false));
        coordinator
            .channels
            .register("second", 1, policy(true, false));

        assert!(coordinator
            .channels
            .recipients(
                ClipboardPayloadKind::Text,
                ClipboardSnapshotOrigin::Remote(ClipboardChannelId::new("first", 1)),
            )
            .is_empty());
    }

    #[test]
    fn closing_one_channel_does_not_change_another_policy() {
        let mut coordinator = ClipboardCoordinator::default();
        coordinator
            .channels
            .register("first", 3, policy(true, false));
        coordinator
            .channels
            .register("second", 1, policy(false, true));
        coordinator.channels.unregister("first", 3);

        assert!(!coordinator.channels.requires(ClipboardPayloadKind::Text));
        assert!(coordinator.channels.requires(ClipboardPayloadKind::File));
    }

    #[test]
    fn stale_watcher_completion_cannot_stop_a_new_generation() {
        let mut coordinator = ClipboardCoordinator::default();
        let first = coordinator.begin_watcher().expect("first watcher");
        coordinator.stop_watcher();
        let second = coordinator.begin_watcher().expect("second watcher");

        coordinator.finish_watcher(first);

        assert!(coordinator.is_current_watcher(second));
        assert!(coordinator.watcher_running());
    }

    #[test]
    fn policy_updates_only_the_matching_connection_round() {
        let mut coordinator = ClipboardCoordinator::default();
        coordinator
            .channels
            .register("peer", 1, policy(true, false));
        coordinator
            .channels
            .register("peer", 2, policy(true, false));

        coordinator.channels.update("peer", 1, policy(false, false));

        assert_eq!(
            coordinator
                .channels
                .recipients(ClipboardPayloadKind::Text, ClipboardSnapshotOrigin::Local),
            [ClipboardChannelId::new("peer", 2)].into_iter().collect()
        );
    }

    #[test]
    fn policy_update_cannot_create_an_unregistered_channel() {
        let mut coordinator = ClipboardCoordinator::default();

        coordinator
            .channels
            .update("connecting", 4, policy(true, true));

        assert!(!coordinator.channels.has_active());
    }

    #[test]
    fn duplicate_watcher_start_keeps_the_current_generation() {
        let mut coordinator = ClipboardCoordinator::default();
        let generation = coordinator.begin_watcher().expect("watcher");

        assert_eq!(coordinator.begin_watcher(), None);
        assert!(coordinator.is_current_watcher(generation));
    }
}
