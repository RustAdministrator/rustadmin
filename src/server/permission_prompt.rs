//! Process-wide bookkeeping for permission requests that are shown to the local
//! user, and the pure decisions built on it.
//!
//! While a request is on screen, input from other low-permission sessions must
//! not be able to reach the dialog: the local user is about to decide for the
//! whole session and must be sure that remote input did not steer the answer.

use crate::common::input::{MOUSE_TYPE_MASK, MOUSE_TYPE_UP};
use hbb_common::message_proto::{key_event, KeyEvent, MouseEvent};
use std::{
    collections::BTreeMap,
    sync::{
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
        Arc, Mutex,
    },
    time::Instant,
};

/// How long a prompt can hold the registry; the same limit the connection uses
/// for a pending permission request.
pub(crate) const PROMPT_TTL_MS: u64 = 120_000;

struct State {
    next: u64,
    /// token -> deadline (milliseconds on the monotonic clock of `mono_ms`).
    deadlines: BTreeMap<u64, u64>,
}

pub(crate) struct PromptRegistry {
    state: Mutex<State>,
    active: AtomicUsize,
    /// Last time low-permission input was handed to the OS; 0 = never.
    last_low_priv_input_ms: AtomicU64,
}

impl PromptRegistry {
    pub(crate) const fn new() -> Self {
        Self {
            state: Mutex::new(State {
                next: 1,
                deadlines: BTreeMap::new(),
            }),
            active: AtomicUsize::new(0),
            last_low_priv_input_ms: AtomicU64::new(0),
        }
    }

    /// Registers a prompt; returns its token and the start time.
    pub(crate) fn register(&self, now_ms: u64) -> (u64, u64) {
        let Ok(mut state) = self.state.lock() else {
            return (0, now_ms);
        };
        let token = state.next;
        state.next += 1;
        state
            .deadlines
            .insert(token, now_ms.saturating_add(PROMPT_TTL_MS));
        self.active.store(state.deadlines.len(), Ordering::Relaxed);
        (token, now_ms)
    }

    pub(crate) fn release(&self, token: u64) {
        if let Ok(mut state) = self.state.lock() {
            state.deadlines.remove(&token);
            self.active.store(state.deadlines.len(), Ordering::Relaxed);
        }
    }

    /// True while at least one prompt is registered and not expired.
    pub(crate) fn is_active(&self, now_ms: u64) -> bool {
        if self.active.load(Ordering::Relaxed) == 0 {
            return false;
        }
        let Ok(mut state) = self.state.lock() else {
            // Fail closed: an unusable registry keeps input paused.
            return true;
        };
        state.deadlines.retain(|_, deadline| *deadline > now_ms);
        self.active.store(state.deadlines.len(), Ordering::Relaxed);
        !state.deadlines.is_empty()
    }

    /// Records that low-permission input reached the OS at `now_ms`.
    pub(crate) fn note_low_priv_input(&self, now_ms: u64) {
        self.last_low_priv_input_ms
            .store(now_ms.max(1), Ordering::Relaxed);
    }

    /// True when low-permission input reached the OS at or after `started_ms`.
    pub(crate) fn low_priv_input_since(&self, started_ms: u64) -> bool {
        let last = self.last_low_priv_input_ms.load(Ordering::Relaxed);
        last != 0 && last >= started_ms
    }
}

pub(crate) static PERMISSION_PROMPTS: PromptRegistry = PromptRegistry::new();

lazy_static::lazy_static! {
    static ref MONO_START: Instant = Instant::now();
}

/// Milliseconds on a monotonic clock that starts at the first call (>= 1).
pub(crate) fn mono_ms() -> u64 {
    MONO_START.elapsed().as_millis() as u64 + 1
}

/// Releases its registry slot when dropped.
#[derive(Debug)]
pub(crate) struct PromptGuard {
    token: u64,
    started_ms: u64,
}

impl PromptGuard {
    pub(crate) fn register() -> Self {
        let (token, started_ms) = PERMISSION_PROMPTS.register(mono_ms());
        Self { token, started_ms }
    }

    pub(crate) fn started_ms(&self) -> u64 {
        self.started_ms
    }
}

impl Drop for PromptGuard {
    fn drop(&mut self) {
        PERMISSION_PROMPTS.release(self.token);
    }
}

/// Whether another prompt anywhere in the process pauses low-permission input.
pub(crate) fn global_prompt_active() -> bool {
    PERMISSION_PROMPTS.is_active(mono_ms())
        && hbb_common::config::permission_prompt_global_input_block_enabled()
}

/// A low-permission session is paused by its own prompt or, with the global
/// block on, by any other prompt.
pub(crate) fn should_pause_input(low_priv: bool, local_active: bool, global_active: bool) -> bool {
    low_priv && (local_active || global_active)
}

/// Input that was queued before a prompt appeared is dropped at dispatch, but
/// releases always pass so that no key or button stays held down.
pub(crate) fn drop_queued_input(paused: bool, release_only: bool) -> bool {
    paused && !release_only
}

/// State the input thread of one connection re-checks for every queued event,
/// so that input accepted just before a prompt appeared cannot reach the OS
/// after the prompt is on screen.
#[derive(Clone)]
pub(crate) struct InputPauseFlags {
    low_priv: Arc<AtomicBool>,
    own_prompt: Arc<AtomicBool>,
}

impl Default for InputPauseFlags {
    fn default() -> Self {
        Self {
            // Until the session kind is known the connection is low-permission.
            low_priv: Arc::new(AtomicBool::new(true)),
            own_prompt: Arc::new(AtomicBool::new(false)),
        }
    }
}

impl InputPauseFlags {
    pub(crate) fn set_low_priv(&self, value: bool) {
        self.low_priv.store(value, Ordering::SeqCst);
    }

    pub(crate) fn set_own_prompt(&self, value: bool) {
        self.own_prompt.store(value, Ordering::SeqCst);
    }

    pub(crate) fn is_low_priv(&self) -> bool {
        self.low_priv.load(Ordering::SeqCst)
    }

    pub(crate) fn paused(&self) -> bool {
        should_pause_input(
            self.low_priv.load(Ordering::SeqCst),
            self.own_prompt.load(Ordering::SeqCst),
            global_prompt_active(),
        )
    }
}

pub(crate) fn key_is_release_only(event: &KeyEvent, press: bool) -> bool {
    if press || event.down {
        return false;
    }
    !matches!(
        event.union,
        Some(key_event::Union::Seq(_)) | Some(key_event::Union::Unicode(_))
    )
}

pub(crate) fn mouse_is_release_only(event: &MouseEvent) -> bool {
    (event.mask & MOUSE_TYPE_MASK) == MOUSE_TYPE_UP
}

/// An approval is refused when low-permission input reached the OS after the
/// request was shown (and the safety is not switched off).
pub(crate) fn approval_blocked_by_input(
    approved: bool,
    input_since_request: bool,
    protection_on: bool,
) -> bool {
    approved && input_since_request && protection_on
}

#[cfg(test)]
mod tests {
    use super::*;
    use hbb_common::message_proto::{ControlKey, KeyEvent, MouseEvent};

    #[test]
    fn registry_empty_is_inactive() {
        let registry = PromptRegistry::new();
        assert!(!registry.is_active(10));
    }

    #[test]
    fn registered_prompt_is_active_until_release() {
        let registry = PromptRegistry::new();
        let (token, _) = registry.register(100);
        assert!(registry.is_active(101));
        registry.release(token);
        assert!(!registry.is_active(102));
        // Releasing twice is harmless.
        registry.release(token);
    }

    #[test]
    fn prompt_expires_after_the_ttl_and_is_pruned() {
        let registry = PromptRegistry::new();
        registry.register(1_000);
        assert!(registry.is_active(1_000 + PROMPT_TTL_MS - 1));
        assert!(!registry.is_active(1_000 + PROMPT_TTL_MS));
        assert!(!registry.is_active(1_000 + PROMPT_TTL_MS + 5));
    }

    #[test]
    fn two_prompts_need_both_released() {
        let registry = PromptRegistry::new();
        let (a, _) = registry.register(10);
        let (b, _) = registry.register(20);
        registry.release(a);
        assert!(registry.is_active(30));
        registry.release(b);
        assert!(!registry.is_active(31));
    }

    #[test]
    fn input_before_the_prompt_started_does_not_taint_it() {
        let registry = PromptRegistry::new();
        registry.note_low_priv_input(500);
        let (_, started) = registry.register(600);
        assert!(!registry.low_priv_input_since(started));
        registry.note_low_priv_input(600);
        assert!(registry.low_priv_input_since(started));
        registry.note_low_priv_input(900);
        assert!(registry.low_priv_input_since(started));
    }

    #[test]
    fn pause_table_covers_every_combination() {
        for low in [false, true] {
            for local in [false, true] {
                for global in [false, true] {
                    assert_eq!(
                        should_pause_input(low, local, global),
                        low && (local || global)
                    );
                }
            }
        }
        // An unattended session is never paused.
        assert!(!should_pause_input(false, true, true));
    }

    #[test]
    fn queued_input_is_dropped_while_paused_but_releases_pass() {
        let mut key_down = KeyEvent::new();
        key_down.down = true;
        key_down.set_control_key(ControlKey::Return);
        assert!(!key_is_release_only(&key_down, false));
        assert!(!key_is_release_only(&key_down, true));
        let mut key_up = KeyEvent::new();
        key_up.down = false;
        key_up.set_control_key(ControlKey::Return);
        assert!(key_is_release_only(&key_up, false));
        let mut text = KeyEvent::new();
        text.set_seq("x".to_owned());
        assert!(!key_is_release_only(&text, false));
        let mut unicode = KeyEvent::new();
        unicode.set_unicode('x' as u32);
        assert!(!key_is_release_only(&unicode, false));

        let mouse = |kind: i32| MouseEvent {
            mask: kind | (1 << 3),
            ..Default::default()
        };
        assert!(mouse_is_release_only(&mouse(
            crate::common::input::MOUSE_TYPE_UP
        )));
        for kind in [
            crate::common::input::MOUSE_TYPE_DOWN,
            crate::common::input::MOUSE_TYPE_MOVE,
            crate::common::input::MOUSE_TYPE_WHEEL,
        ] {
            assert!(!mouse_is_release_only(&mouse(kind)));
        }

        assert!(drop_queued_input(true, false));
        assert!(!drop_queued_input(true, true));
        assert!(!drop_queued_input(false, false));
    }

    #[test]
    fn pause_flags_follow_the_session_kind_and_the_own_prompt() {
        let flags = InputPauseFlags::default();
        assert!(!flags.paused());
        flags.set_own_prompt(true);
        assert!(flags.paused());
        // The clone shared with the input thread sees the same state.
        let thread_view = flags.clone();
        flags.set_low_priv(false);
        assert!(!thread_view.paused());
        flags.set_low_priv(true);
        assert!(thread_view.paused());
        flags.set_own_prompt(false);
        assert!(!thread_view.paused());
    }

    #[test]
    fn approval_is_refused_only_after_input_with_the_protection_on() {
        assert!(approval_blocked_by_input(true, true, true));
        assert!(!approval_blocked_by_input(true, false, true));
        assert!(!approval_blocked_by_input(true, true, false));
        assert!(!approval_blocked_by_input(false, true, true));
    }
}
