use crate::AlarmAuditType;
use hbb_common::get_time;
#[cfg(target_os = "windows")]
use hbb_common::tokio::sync::{Mutex as TokioMutex, OwnedMutexGuard};
#[cfg(target_os = "windows")]
use std::sync::Arc;
use std::sync::Mutex;

const OS_CREDENTIAL_LOGIN_TOTAL_IDLE_RESET_MS: i64 = 120 * 60 * 1_000;
const OS_CREDENTIAL_LOGIN_BACKOFF_BASE_SECONDS: i64 = 15;
const OS_CREDENTIAL_LOGIN_BACKOFF_MAX_SECONDS: i64 = 30 * 60;

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub(crate) enum FailureScope {
    Default,
    TerminalOsLogin,
}

pub(crate) struct OsCredentialPolicyDecision {
    pub allowed: bool,
    pub login_error: Option<String>,
    pub audit: Option<AlarmAuditType>,
}

#[derive(Copy, Clone, Debug, Default)]
struct OsCredentialFailureState {
    total_failures: i32,
    backoff_until_ms: Option<i64>,
    last_failure_ms: Option<i64>,
}

lazy_static::lazy_static! {
    static ref OS_CREDENTIAL_LOGIN_FAILURE_STATE: Mutex<OsCredentialFailureState> =
        Mutex::new(OsCredentialFailureState::default());
}

#[cfg(target_os = "windows")]
lazy_static::lazy_static! {
    static ref OS_CREDENTIAL_LOGIN_MUTEX: Arc<TokioMutex<()>> = Arc::new(TokioMutex::new(()));
}

fn is_os_credential_scope(scope: FailureScope) -> bool {
    matches!(scope, FailureScope::TerminalOsLogin)
}

fn state_for_os_credential_scope(
    scope: FailureScope,
) -> Option<&'static Mutex<OsCredentialFailureState>> {
    if is_os_credential_scope(scope) {
        Some(&OS_CREDENTIAL_LOGIN_FAILURE_STATE)
    } else {
        None
    }
}

fn backoff_audit_type_for_scope(scope: FailureScope) -> Option<AlarmAuditType> {
    match scope {
        FailureScope::TerminalOsLogin => Some(AlarmAuditType::TerminalOsLoginBackoff),
        FailureScope::Default => None,
    }
}

fn os_credential_login_backoff_seconds(total_failures: i32) -> i64 {
    if total_failures <= 2 {
        return 0;
    }
    let exp = (total_failures - 3).min(7);
    let seconds = OS_CREDENTIAL_LOGIN_BACKOFF_BASE_SECONDS * (1_i64 << exp);
    seconds.min(OS_CREDENTIAL_LOGIN_BACKOFF_MAX_SECONDS)
}

fn normalize_backoff(state: &mut OsCredentialFailureState, now_ms: i64) {
    if let Some(until_ms) = state.backoff_until_ms {
        if until_ms <= now_ms {
            state.backoff_until_ms = None;
        }
    }
}

fn reset_totals_on_idle(state: &mut OsCredentialFailureState, now_ms: i64) {
    if let Some(last_ms) = state.last_failure_ms {
        if now_ms.saturating_sub(last_ms) >= OS_CREDENTIAL_LOGIN_TOTAL_IDLE_RESET_MS {
            state.total_failures = 0;
            state.backoff_until_ms = None;
            state.last_failure_ms = None;
        }
    }
}

fn allow_decision() -> OsCredentialPolicyDecision {
    OsCredentialPolicyDecision {
        allowed: true,
        login_error: None,
        audit: None,
    }
}

fn block_decision(
    login_error: String,
    alarm_type: Option<AlarmAuditType>,
) -> OsCredentialPolicyDecision {
    OsCredentialPolicyDecision {
        allowed: false,
        login_error: Some(login_error),
        audit: alarm_type,
    }
}

pub(crate) fn evaluate_os_credential_policy(
    scope: FailureScope,
    now_ms: i64,
) -> OsCredentialPolicyDecision {
    if !is_os_credential_scope(scope) {
        return allow_decision();
    }
    let Some(state_mutex) = state_for_os_credential_scope(scope) else {
        return allow_decision();
    };
    let mut state = state_mutex.lock().unwrap();
    reset_totals_on_idle(&mut state, now_ms);
    normalize_backoff(&mut state, now_ms);

    if let Some(until_ms) = state.backoff_until_ms {
        let remaining_ms = (until_ms - now_ms).max(0);
        let remaining_seconds = ((remaining_ms + 999) / 1_000).max(1);
        let seconds_label = if remaining_seconds == 1 {
            "second"
        } else {
            "seconds"
        };
        block_decision(
            format!(
                "Please try again in {} {}.",
                remaining_seconds, seconds_label
            ),
            backoff_audit_type_for_scope(scope),
        )
    } else {
        allow_decision()
    }
}

pub(crate) fn record_os_credential_failure(scope: FailureScope) {
    if !is_os_credential_scope(scope) {
        return;
    }
    let Some(state_mutex) = state_for_os_credential_scope(scope) else {
        return;
    };
    let mut state = state_mutex.lock().unwrap();
    let now_ms = get_time();
    reset_totals_on_idle(&mut state, now_ms);
    normalize_backoff(&mut state, now_ms);
    state.total_failures = state.total_failures.saturating_add(1);
    state.last_failure_ms = Some(now_ms);
    let backoff_seconds = os_credential_login_backoff_seconds(state.total_failures);
    if backoff_seconds > 0 {
        state.backoff_until_ms = Some(now_ms + backoff_seconds * 1_000);
    }
}

/// Per source and account failures of the pre-authorization account check
/// (legacy order only), kept next to the host-wide back-off above.
const KEYED_MAX_ENTRIES: usize = 1024;
const KEYED_FREE_FAILURES: i32 = 3;

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub(crate) struct OsCredentialKey {
    source: std::net::IpAddr,
    user: String,
}

impl OsCredentialKey {
    pub(crate) fn new(source: Option<std::net::IpAddr>, user: &str) -> Self {
        Self {
            source: super::pairing_guard::source_key(
                source.unwrap_or(std::net::IpAddr::V4(std::net::Ipv4Addr::UNSPECIFIED)),
            ),
            user: user.trim().to_lowercase(),
        }
    }
}

#[derive(Default)]
struct KeyedState {
    failures: i32,
    backoff_until_ms: i64,
    last_ms: i64,
}

#[derive(Default)]
struct KeyedFailures {
    entries: std::collections::HashMap<OsCredentialKey, KeyedState>,
}

impl KeyedFailures {
    fn remaining_ms(&mut self, key: &OsCredentialKey, now_ms: i64) -> i64 {
        let Some(state) = self.entries.get_mut(key) else {
            return 0;
        };
        if now_ms.saturating_sub(state.last_ms) >= OS_CREDENTIAL_LOGIN_TOTAL_IDLE_RESET_MS {
            self.entries.remove(key);
            return 0;
        }
        (state.backoff_until_ms - now_ms).max(0)
    }

    fn record_failure(&mut self, key: &OsCredentialKey, now_ms: i64) {
        if !self.entries.contains_key(key) && self.entries.len() >= KEYED_MAX_ENTRIES {
            if let Some(oldest) = self
                .entries
                .iter()
                .min_by_key(|(_, state)| state.last_ms)
                .map(|(key, _)| key.clone())
            {
                self.entries.remove(&oldest);
            }
        }
        let state = self.entries.entry(key.clone()).or_default();
        state.failures = state.failures.saturating_add(1);
        state.last_ms = now_ms;
        let steps = state.failures - KEYED_FREE_FAILURES;
        if steps > 0 {
            let seconds = (OS_CREDENTIAL_LOGIN_BACKOFF_BASE_SECONDS << (steps - 1).min(7) as u32)
                .min(OS_CREDENTIAL_LOGIN_BACKOFF_MAX_SECONDS);
            state.backoff_until_ms = now_ms + seconds * 1_000;
        }
    }

    fn record_success(&mut self, key: &OsCredentialKey) {
        self.entries.remove(key);
    }
}

lazy_static::lazy_static! {
    static ref KEYED_FAILURES: Mutex<KeyedFailures> = Mutex::new(KeyedFailures::default());
}

pub(crate) fn keyed_backoff_remaining_ms(key: &OsCredentialKey, now_ms: i64) -> i64 {
    KEYED_FAILURES.lock().unwrap().remaining_ms(key, now_ms)
}

pub(crate) fn keyed_record_failure(key: &OsCredentialKey, now_ms: i64) {
    KEYED_FAILURES.lock().unwrap().record_failure(key, now_ms);
}

pub(crate) fn keyed_record_success(key: &OsCredentialKey) {
    KEYED_FAILURES.lock().unwrap().record_success(key);
}

#[cfg(target_os = "windows")]
pub(crate) fn try_acquire_os_credential_login_gate() -> Result<OwnedMutexGuard<()>, ()> {
    OS_CREDENTIAL_LOGIN_MUTEX
        .clone()
        .try_lock_owned()
        .map_err(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    static TEST_MUTEX: Mutex<()> = Mutex::new(());

    fn clear_os_credential_failure_state(scope: FailureScope) {
        if let Some(state_mutex) = state_for_os_credential_scope(scope) {
            *state_mutex.lock().unwrap() = OsCredentialFailureState::default();
        }
    }

    #[test]
    fn os_credential_policy_prioritizes_backoff() {
        let _guard = TEST_MUTEX.lock().unwrap();
        clear_os_credential_failure_state(FailureScope::TerminalOsLogin);
        let now_ms = get_time();
        for _ in 0..3 {
            record_os_credential_failure(FailureScope::TerminalOsLogin);
        }
        let decision = evaluate_os_credential_policy(FailureScope::TerminalOsLogin, now_ms);
        assert!(!decision.allowed);
        assert!(decision.login_error.is_some());
        clear_os_credential_failure_state(FailureScope::TerminalOsLogin);
    }

    #[test]
    fn os_credential_policy_idle_window_resets_total_counter() {
        let _guard = TEST_MUTEX.lock().unwrap();
        clear_os_credential_failure_state(FailureScope::TerminalOsLogin);
        for _ in 0..13 {
            record_os_credential_failure(FailureScope::TerminalOsLogin);
        }
        let blocked = evaluate_os_credential_policy(FailureScope::TerminalOsLogin, get_time());
        assert!(!blocked.allowed);

        let after_failures_ms = get_time();
        let after_idle_ms = after_failures_ms + OS_CREDENTIAL_LOGIN_TOTAL_IDLE_RESET_MS + 1_000;
        let allowed = evaluate_os_credential_policy(FailureScope::TerminalOsLogin, after_idle_ms);
        assert!(allowed.allowed);
        clear_os_credential_failure_state(FailureScope::TerminalOsLogin);
    }

    #[test]
    fn os_credential_policy_audits_every_backoff_block() {
        let _guard = TEST_MUTEX.lock().unwrap();
        clear_os_credential_failure_state(FailureScope::TerminalOsLogin);

        for _ in 0..3 {
            record_os_credential_failure(FailureScope::TerminalOsLogin);
        }
        let now_ms = get_time();
        let first = evaluate_os_credential_policy(FailureScope::TerminalOsLogin, now_ms);
        let second = evaluate_os_credential_policy(FailureScope::TerminalOsLogin, now_ms + 1_000);
        assert!(!first.allowed);
        assert!(!second.allowed);
        assert!(first.audit.is_some());
        assert!(second.audit.is_some());

        clear_os_credential_failure_state(FailureScope::TerminalOsLogin);
    }

    fn key(last: u8, user: &str) -> OsCredentialKey {
        OsCredentialKey::new(
            Some(std::net::IpAddr::V4(std::net::Ipv4Addr::new(
                192, 0, 2, last,
            ))),
            user,
        )
    }

    #[test]
    fn keyed_failures_back_off_per_source_and_account() {
        let mut tracker = KeyedFailures::default();
        let a = key(1, "Administrator");
        for attempt in 0..KEYED_FREE_FAILURES {
            assert_eq!(tracker.remaining_ms(&a, attempt as i64), 0);
            tracker.record_failure(&a, attempt as i64);
        }
        assert_eq!(tracker.remaining_ms(&a, 10), 0);
        tracker.record_failure(&a, 10);
        assert!(tracker.remaining_ms(&a, 11) > 0);
        // Case and padding of the account name do not give a fresh budget.
        assert!(tracker.remaining_ms(&key(1, " administrator "), 11) > 0);
        // Another source or another account is untouched.
        assert_eq!(tracker.remaining_ms(&key(2, "Administrator"), 11), 0);
        assert_eq!(tracker.remaining_ms(&key(1, "other"), 11), 0);
        // Success clears it; idleness clears it as well.
        tracker.record_success(&a);
        assert_eq!(tracker.remaining_ms(&a, 12), 0);
    }

    #[test]
    fn keyed_failures_forget_idle_entries_and_stay_bounded() {
        let mut tracker = KeyedFailures::default();
        let a = key(1, "admin");
        for attempt in 0..6 {
            tracker.record_failure(&a, attempt);
        }
        assert!(tracker.remaining_ms(&a, 10) > 0);
        assert_eq!(
            tracker.remaining_ms(&a, OS_CREDENTIAL_LOGIN_TOTAL_IDLE_RESET_MS + 10),
            0
        );
        for index in 0..(KEYED_MAX_ENTRIES + 50) {
            tracker.record_failure(&key(1, &format!("user{index}")), index as i64);
        }
        assert_eq!(tracker.entries.len(), KEYED_MAX_ENTRIES);
    }
}
