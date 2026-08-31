use std::collections::HashSet;

#[derive(Default)]
pub(crate) struct ClipboardChannelRegistry {
    channels: HashSet<(String, u32)>,
}

impl ClipboardChannelRegistry {
    pub(crate) fn register(&mut self, peer_id: &str, round: u32) {
        self.channels.insert((peer_id.to_owned(), round));
    }

    pub(crate) fn unregister(&mut self, peer_id: &str, round: u32) {
        self.channels.remove(&(peer_id.to_owned(), round));
    }

    pub(crate) fn has_active(&self) -> bool {
        !self.channels.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::ClipboardChannelRegistry;

    #[test]
    fn reconnect_round_keeps_new_clipboard_channel_active() {
        let mut registry = ClipboardChannelRegistry::default();
        registry.register("peer", 1);
        registry.register("peer", 2);

        registry.unregister("peer", 1);

        assert!(registry.has_active());
    }

    #[test]
    fn duplicate_registration_is_idempotent() {
        let mut registry = ClipboardChannelRegistry::default();
        registry.register("peer", 7);
        registry.register("peer", 7);

        registry.unregister("peer", 7);

        assert!(!registry.has_active());
    }

    #[test]
    fn last_distinct_channel_stops_clipboard_ownership() {
        let mut registry = ClipboardChannelRegistry::default();
        registry.register("first", 3);
        registry.register("second", 1);
        registry.unregister("first", 3);
        assert!(registry.has_active());

        registry.unregister("second", 1);

        assert!(!registry.has_active());
    }
}
