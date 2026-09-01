#[derive(Default)]
pub(crate) struct RenderTargetOwner {
    pointer: Option<usize>,
    latest_token: Option<u64>,
}

impl RenderTargetOwner {
    pub(crate) fn register(&mut self, pointer: usize, token: u64) -> bool {
        if pointer == 0 {
            return false;
        }
        match self.latest_token {
            Some(latest) if token < latest => false,
            Some(latest) if token == latest => self.pointer == Some(pointer),
            _ => {
                self.latest_token = Some(token);
                self.pointer = Some(pointer);
                true
            }
        }
    }

    pub(crate) fn unregister(&mut self, token: u64) -> bool {
        if self.latest_token != Some(token) || self.pointer.is_none() {
            return false;
        }
        self.pointer = None;
        true
    }

    pub(crate) fn register_legacy(&mut self, pointer: usize) {
        self.latest_token = None;
        self.pointer = (pointer != 0).then_some(pointer);
    }

    pub(crate) fn pointer(&self) -> Option<usize> {
        self.pointer
    }

    pub(crate) fn token(&self) -> Option<u64> {
        self.latest_token
    }
}

#[cfg(test)]
mod tests {
    use super::RenderTargetOwner;

    #[test]
    fn stale_unregister_does_not_clear_new_target() {
        let mut owner = RenderTargetOwner::default();
        assert!(owner.register(11, 1));
        assert!(owner.register(22, 2));

        assert!(!owner.unregister(1));
        assert_eq!(owner.pointer(), Some(22));
    }

    #[test]
    fn retired_token_cannot_register_again() {
        let mut owner = RenderTargetOwner::default();
        assert!(owner.register(11, 4));
        assert!(owner.unregister(4));

        assert!(!owner.register(11, 4));
        assert_eq!(owner.pointer(), None);
    }

    #[test]
    fn newer_target_can_replace_retired_target() {
        let mut owner = RenderTargetOwner::default();
        assert!(owner.register(11, 7));
        assert!(owner.unregister(7));

        assert!(owner.register(22, 8));
        assert_eq!(owner.pointer(), Some(22));
        assert_eq!(owner.token(), Some(8));
    }

    #[test]
    fn duplicate_registration_is_idempotent() {
        let mut owner = RenderTargetOwner::default();
        assert!(owner.register(11, 9));
        assert!(owner.register(11, 9));
        assert!(!owner.register(22, 9));
        assert_eq!(owner.pointer(), Some(11));
    }
}
