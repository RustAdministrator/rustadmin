//! Bounded, generation-owned user-helper startup policy. No OS work under this API.
use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

pub(super) const STARTUP_TIMEOUT: Duration = Duration::from_secs(3);
const ABANDONED_TIMEOUT: Duration = Duration::from_secs(5);
const FIRST_COOLDOWN: Duration = Duration::from_secs(5);
const SECOND_COOLDOWN: Duration = Duration::from_secs(30);
const MAX_FAILURES: u32 = 3;
const MAX_STARTING: usize = 2;
const MAX_KEYS: usize = 64;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd)]
pub(super) struct HelperKey {
    pub desktop_generation: u64,
    pub display: usize,
    pub backend: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) struct AttemptToken {
    pub key: HelperKey,
    pub generation: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Phase {
    Ready,
    Queued,
    Starting(Instant),
    Running,
    Cooldown(Instant),
    Suppressed,
}

struct Entry {
    phase: Phase,
    attempt: u64,
    failures: u32,
}

impl Default for Entry {
    fn default() -> Self {
        Self {
            phase: Phase::Ready,
            attempt: 0,
            failures: 0,
        }
    }
}

impl Entry {
    fn fail(&mut self, now: Instant) {
        self.failures = self.failures.saturating_add(1);
        self.phase = if self.failures >= MAX_FAILURES {
            Phase::Suppressed
        } else {
            Phase::Cooldown(
                now + if self.failures == 1 {
                    FIRST_COOLDOWN
                } else {
                    SECOND_COOLDOWN
                },
            )
        };
    }
}

pub(super) struct HelperCoordinator {
    desktop: Option<(u32, bool)>,
    desktop_generation: u64,
    next_attempt: u64,
    entries: BTreeMap<HelperKey, Entry>,
    enabled: bool,
    process_retry_at: Option<Instant>,
}

impl Default for HelperCoordinator {
    fn default() -> Self {
        Self {
            desktop: None,
            desktop_generation: 0,
            next_attempt: 0,
            entries: BTreeMap::new(),
            enabled: true,
            process_retry_at: None,
        }
    }
}

impl HelperCoordinator {
    // The caller serializes sampling of the process session/security context.
    // Never use a capture thread's selected-desktop flag as a global identity.
    pub(super) fn observe_desktop(&mut self, session: u32, secure: bool) -> u64 {
        if self.desktop != Some((session, secure)) {
            self.desktop = Some((session, secure));
            self.reset(self.enabled);
        }
        self.desktop_generation
    }

    pub(super) fn reset(&mut self, enabled: bool) {
        self.desktop_generation = self.desktop_generation.saturating_add(1);
        self.entries.clear();
        self.process_retry_at = None;
        self.enabled = enabled;
    }

    fn expire(&mut self, now: Instant) {
        for entry in self.entries.values_mut() {
            if matches!(entry.phase, Phase::Starting(start) if now.saturating_duration_since(start) >= ABANDONED_TIMEOUT)
            {
                entry.fail(now);
            }
        }
    }

    pub(super) fn begin(&mut self, key: HelperKey, now: Instant) -> Option<AttemptToken> {
        if !self.enabled
            || key.desktop_generation != self.desktop_generation
            || self.next_attempt == u64::MAX
        {
            return None;
        }
        self.expire(now);
        if !self.entries.contains_key(&key) && self.entries.len() >= MAX_KEYS {
            return None;
        }
        let busy = self
            .entries
            .values()
            .filter(|entry| matches!(entry.phase, Phase::Starting(_)))
            .count()
            >= MAX_STARTING;
        let process_blocked = self.process_retry_at.is_some_and(|at| now < at);
        let entry = self.entries.entry(key).or_default();
        match entry.phase {
            Phase::Ready | Phase::Queued => {}
            Phase::Cooldown(at) if now >= at => {}
            _ => return None,
        }
        if busy || process_blocked {
            entry.phase = Phase::Queued;
            return None;
        }
        self.next_attempt += 1;
        entry.attempt = self.next_attempt;
        entry.phase = Phase::Starting(now);
        Some(AttemptToken {
            key,
            generation: entry.attempt,
        })
    }

    fn owned_entry(&mut self, token: AttemptToken) -> Option<&mut Entry> {
        self.entries
            .get_mut(&token.key)
            .filter(|entry| entry.attempt == token.generation)
    }

    pub(super) fn success(&mut self, token: AttemptToken) -> bool {
        let Some(entry) = self.owned_entry(token) else {
            return false;
        };
        if !matches!(entry.phase, Phase::Starting(_)) {
            return false;
        }
        entry.phase = Phase::Running;
        entry.failures = 0;
        true
    }

    pub(super) fn failure(
        &mut self,
        token: AttemptToken,
        now: Instant,
        process_launch: bool,
    ) -> bool {
        let Some(entry) = self.owned_entry(token) else {
            return false;
        };
        if !matches!(entry.phase, Phase::Starting(_) | Phase::Running) {
            return false;
        }
        entry.fail(now);
        // Only an actual process launch failure closes the process gate. Frame
        // timeout, WGC/DXGI failure and success on another display cannot do so.
        if process_launch {
            self.process_retry_at = Some(now + FIRST_COOLDOWN);
        }
        true
    }

    pub(super) fn cancel(&mut self, token: AttemptToken) -> bool {
        let Some(entry) = self.owned_entry(token) else {
            return false;
        };
        if !matches!(entry.phase, Phase::Starting(_) | Phase::Running) {
            return false;
        }
        entry.phase = Phase::Ready;
        true
    }

    pub(super) fn retry_due(&mut self, key: HelperKey, now: Instant) -> bool {
        self.expire(now);
        if !self.enabled
            || key.desktop_generation != self.desktop_generation
            || self.process_retry_at.is_some_and(|at| now < at)
            || self
                .entries
                .values()
                .filter(|entry| matches!(entry.phase, Phase::Starting(_)))
                .count()
                >= MAX_STARTING
        {
            return false;
        }
        self.entries
            .get(&key)
            .is_some_and(|entry| match entry.phase {
                Phase::Queued => true,
                Phase::Cooldown(at) => now >= at,
                _ => false,
            })
    }

    pub(super) fn state(&self, key: HelperKey) -> &'static str {
        if !self.enabled {
            return "manual";
        }
        if key.desktop_generation != self.desktop_generation {
            return "retired-desktop";
        }
        match self.entries.get(&key).map(|entry| entry.phase) {
            None | Some(Phase::Ready) => "ready",
            Some(Phase::Queued) => "queued",
            Some(Phase::Starting(_)) => "starting",
            Some(Phase::Running) => "running",
            Some(Phase::Cooldown(_)) => "cooldown",
            Some(Phase::Suppressed) => "suppressed",
        }
    }

    pub(super) fn protects_refresh(&mut self, display: usize, now: Instant) -> bool {
        self.expire(now);
        let busy = self
            .entries
            .values()
            .filter(|entry| matches!(entry.phase, Phase::Starting(_)))
            .count()
            >= MAX_STARTING;
        let process_blocked = self.process_retry_at.is_some_and(|at| now < at);
        self.entries.iter().any(|(key, entry)| {
            key.display == display
                && match entry.phase {
                    Phase::Starting(_) => true,
                    Phase::Cooldown(at) => now < at,
                    Phase::Queued => busy || process_blocked,
                    _ => false,
                }
        })
    }
}

/// Travels with the capturer, so every early return and SWITCH cancels only its
/// own attempt. A settled old lease cannot modify a newer attempt for that key.
pub(super) struct HelperAttemptLease {
    owner: Arc<Mutex<HelperCoordinator>>,
    token: AttemptToken,
    first_frame: bool,
    started_at: Instant,
}

impl HelperAttemptLease {
    pub(super) fn new(owner: Arc<Mutex<HelperCoordinator>>, token: AttemptToken) -> Self {
        Self {
            owner,
            token,
            first_frame: false,
            started_at: Instant::now(),
        }
    }

    pub(super) fn success(&mut self) -> bool {
        let mut owner = self.owner.lock().unwrap();
        if !self.first_frame {
            if !owner.success(self.token) {
                return false;
            }
            self.first_frame = true;
        }
        owner
            .owned_entry(self.token)
            .is_some_and(|entry| entry.phase == Phase::Running)
    }

    pub(super) fn startup_timed_out(&self) -> bool {
        !self.first_frame && self.started_at.elapsed() >= STARTUP_TIMEOUT
    }

    pub(super) fn failure(&mut self, process_launch: bool) {
        if self
            .owner
            .lock()
            .unwrap()
            .failure(self.token, Instant::now(), process_launch)
        {
            hbb_common::log::warn!(
                "user capture helper failed: key={:?}, attempt={}, process_launch={process_launch}",
                self.token.key,
                self.token.generation
            );
        }
    }
}

impl Drop for HelperAttemptLease {
    fn drop(&mut self) {
        self.owner.lock().unwrap().cancel(self.token);
    }
}

#[derive(Debug)]
pub(super) struct HelperLaunchFailure;
impl std::fmt::Display for HelperLaunchFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("user capture helper process launch failed")
    }
}
impl std::error::Error for HelperLaunchFailure {}

#[cfg(test)]
mod tests {
    use super::*;
    fn key(owner: &mut HelperCoordinator, display: usize, backend: u32) -> HelperKey {
        HelperKey {
            desktop_generation: owner.observe_desktop(1, false),
            display,
            backend,
        }
    }

    #[test]
    fn success_on_a_cannot_settle_b_and_failures_are_keyed() {
        let mut owner = HelperCoordinator::default();
        let now = Instant::now();
        let a = key(&mut owner, 0, 2);
        let b = key(&mut owner, 1, 2);
        let ta = owner.begin(a, now).unwrap();
        let tb = owner.begin(b, now).unwrap();
        assert!(owner.success(ta));
        assert_eq!(owner.state(b), "starting");
        assert!(owner.failure(tb, now, false));
        assert!(!owner.success(ta));
        assert_eq!(owner.state(b), "cooldown");
        assert!(owner.retry_due(b, now + FIRST_COOLDOWN));
        let dxgi = key(&mut owner, 1, 1);
        assert!(owner.begin(dxgi, now).is_some());
    }

    #[test]
    fn old_attempt_and_desktop_completions_cannot_settle_replacement() {
        let mut owner = HelperCoordinator::default();
        let now = Instant::now();
        let k = key(&mut owner, 0, 2);
        let old = owner.begin(k, now).unwrap();
        assert!(owner.cancel(old));
        let current = owner.begin(k, now).unwrap();
        assert!(!owner.failure(old, now, false));
        assert!(!owner.success(old));
        assert!(!owner.cancel(old));
        assert_eq!(owner.state(k), "starting");
        owner.observe_desktop(1, true);
        owner.observe_desktop(1, false);
        let new_key = key(&mut owner, 0, 2);
        assert!(owner.begin(new_key, now).is_some());
        assert!(!owner.success(current));
        assert!(!owner.cancel(current));
    }

    #[test]
    fn concurrency_queues_without_failure_and_drop_releases_slot() {
        let owner = Arc::new(Mutex::new(HelperCoordinator::default()));
        let now = Instant::now();
        let (a, b, c, ta) = {
            let mut p = owner.lock().unwrap();
            let a = key(&mut p, 0, 2);
            let b = key(&mut p, 1, 2);
            let c = key(&mut p, 2, 2);
            let ta = p.begin(a, now).unwrap();
            assert!(p.begin(b, now).is_some());
            assert!(p.begin(c, now).is_none());
            assert_eq!(p.state(c), "queued");
            (a, b, c, ta)
        };
        drop(HelperAttemptLease::new(owner.clone(), ta));
        let mut p = owner.lock().unwrap();
        assert_eq!(p.state(a), "ready");
        assert_eq!(p.state(b), "starting");
        assert!(p.retry_due(c, now));
        assert!(p.begin(c, now).is_some());
    }

    #[test]
    fn abandoned_attempt_and_cooldowns_are_bounded_per_key() {
        let mut p = HelperCoordinator::default();
        let now = Instant::now();
        let k = key(&mut p, 0, 2);
        let old = p.begin(k, now).unwrap();
        assert!(!p.retry_due(k, now + ABANDONED_TIMEOUT));
        assert!(!p.success(old));
        let retry = p
            .begin(k, now + ABANDONED_TIMEOUT + FIRST_COOLDOWN)
            .unwrap();
        assert!(p.failure(retry, now, false));
        assert!(p.begin(k, now + SECOND_COOLDOWN / 2).is_none());
        let last = p.begin(k, now + SECOND_COOLDOWN).unwrap();
        assert!(p.failure(last, now + SECOND_COOLDOWN, false));
        assert!(p.begin(k, now + Duration::from_secs(1000)).is_none());
        assert_eq!(p.state(k), "suppressed");
    }

    #[test]
    fn only_process_launch_failure_closes_global_gate() {
        let mut p = HelperCoordinator::default();
        let now = Instant::now();
        let a = key(&mut p, 0, 2);
        let b = key(&mut p, 1, 2);
        let ta = p.begin(a, now).unwrap();
        assert!(p.failure(ta, now, true));
        assert!(p.begin(b, now).is_none());
        assert!(p.begin(b, now + FIRST_COOLDOWN).is_some());
        assert_eq!(p.entries[&b].failures, 0);
        p.reset(false);
        let k = HelperKey {
            desktop_generation: p.desktop_generation,
            ..a
        };
        assert!(p.begin(k, now).is_none());
    }

    #[test]
    fn viewer_refresh_cannot_interrupt_starting_queued_or_cooling_attempts() {
        let mut p = HelperCoordinator::default();
        let now = Instant::now();
        let a = key(&mut p, 0, 2);
        let b = key(&mut p, 1, 2);
        let c = key(&mut p, 2, 2);
        let ta = p.begin(a, now).unwrap();
        let tb = p.begin(b, now).unwrap();
        assert!(p.begin(c, now).is_none());
        assert!(p.protects_refresh(0, now));
        assert!(p.protects_refresh(1, now));
        assert!(p.protects_refresh(2, now));
        assert!(!p.protects_refresh(3, now));
        p.failure(ta, now, false);
        assert!(p.protects_refresh(0, now + FIRST_COOLDOWN / 2));
        assert!(!p.protects_refresh(2, now)); // Its queued launch can now run.
        p.success(tb);
        assert!(!p.protects_refresh(1, now));
        assert!(!p.protects_refresh(0, now + FIRST_COOLDOWN));
    }

    #[test]
    fn settled_lease_cannot_emit_frames_or_cancel_a_replacement_after_reset() {
        let owner = Arc::new(Mutex::new(HelperCoordinator::default()));
        let now = Instant::now();
        let token = {
            let mut p = owner.lock().unwrap();
            let k = key(&mut p, 0, 2);
            p.begin(k, now).unwrap()
        };
        let mut lease = HelperAttemptLease::new(owner.clone(), token);
        assert!(lease.success());
        let replacement = {
            let mut p = owner.lock().unwrap();
            p.reset(true);
            let k = key(&mut p, 0, 2);
            p.begin(k, now).unwrap()
        };
        assert!(!lease.success());
        drop(lease);
        assert!(owner.lock().unwrap().success(replacement));
    }

    #[test]
    fn helper_key_storage_is_bounded_and_desktop_change_releases_it() {
        let mut p = HelperCoordinator::default();
        let now = Instant::now();
        for display in 0..MAX_KEYS {
            let k = key(&mut p, display, 2);
            let token = p.begin(k, now).unwrap();
            assert!(p.cancel(token));
        }
        let overflow = key(&mut p, MAX_KEYS, 2);
        assert!(p.begin(overflow, now).is_none());
        assert_eq!(p.entries.len(), MAX_KEYS);
        p.observe_desktop(2, false);
        assert!(p.entries.is_empty());
    }
}
