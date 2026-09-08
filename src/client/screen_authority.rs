/// Screen content belongs to one authenticated connection runtime. Ending that
/// runtime is terminal: a delayed login or decoder completion cannot revive it.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct ScreenViewAuthority {
    pub connection_generation: u32,
    pub generation: u64,
    pub allowed: bool,
    ended: bool,
}

impl ScreenViewAuthority {
    pub fn begin(&mut self, connection_generation: u32) -> bool {
        if connection_generation <= self.connection_generation {
            return false;
        }
        self.connection_generation = connection_generation;
        self.allowed = false;
        self.ended = false;
        self.generation = self.generation.saturating_add(1);
        true
    }

    pub fn authorize(&mut self, connection_generation: u32) -> bool {
        if connection_generation != self.connection_generation
            || self.generation == 0
            || self.ended
            || self.allowed
        {
            return false;
        }
        self.allowed = true;
        self.generation = self.generation.saturating_add(1);
        true
    }

    pub fn end(&mut self, connection_generation: u32) -> bool {
        if connection_generation < self.connection_generation
            || (connection_generation == self.connection_generation && self.ended)
        {
            return false;
        }
        // close() can beat the newly spawned runtime to begin(). Remember that
        // cancellation so the delayed runtime cannot authenticate afterward.
        self.connection_generation = connection_generation;
        self.allowed = false;
        self.ended = true;
        self.generation = self.generation.saturating_add(1);
        true
    }

    pub fn accepts(&self, connection_generation: u32, generation: u64) -> bool {
        self.allowed
            && self.connection_generation == connection_generation
            && self.generation == generation
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_authenticated_current_runtime_can_render() {
        let mut authority = ScreenViewAuthority::default();
        authority.begin(1);
        assert!(!authority.accepts(1, authority.generation));
        authority.authorize(1);
        let authorized_generation = authority.generation;
        assert!(authority.accepts(1, authorized_generation));
        authority.end(1);
        assert!(!authority.accepts(1, authorized_generation));
        assert!(!authority.authorize(1));
    }

    #[test]
    fn old_shutdown_and_login_cannot_change_replacement_runtime() {
        let mut authority = ScreenViewAuthority::default();
        authority.begin(1);
        authority.authorize(1);
        let old = authority;
        authority.begin(2);
        authority.authorize(2);
        let replacement = authority;
        assert!(!authority.end(1));
        assert!(!authority.authorize(1));
        assert!(!authority.begin(1));
        assert!(!authority.begin(2));
        assert_eq!(authority, replacement);
        assert!(!authority.accepts(1, old.generation));
        assert!(!authority.accepts(2, old.generation));
    }

    #[test]
    fn closing_before_runtime_start_cancels_that_round() {
        let mut authority = ScreenViewAuthority::default();
        assert!(authority.end(1));
        assert!(!authority.begin(1));
        assert!(!authority.authorize(1));
        assert!(!authority.allowed);
        assert!(authority.begin(2));
        assert!(authority.authorize(2));
    }
}
