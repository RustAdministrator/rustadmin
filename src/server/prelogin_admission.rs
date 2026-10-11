//! Ceilings for connections that have not logged in yet.
//!
//! A connection holds a ticket from the moment it is accepted until it is
//! authorized or closed. Two hard ceilings are always enforced, so that no
//! amount of silent connections can exhaust the host. Below them sit two
//! softer limits that only log by default (`prelogin-limit-mode=warn`) and can
//! be enforced or switched off; this lets a deployment see what its normal
//! number of waiting sessions looks like before anything is refused.

use hbb_common::{config::keys, log};
use std::{
    collections::HashMap,
    net::IpAddr,
    sync::{Mutex, OnceLock},
};

/// Never exceeded, whatever the mode: waiting connections in total / per source.
pub(crate) const HARD_MAX_TOTAL: usize = 256;
pub(crate) const HARD_MAX_PER_SOURCE: usize = 64;
const DEFAULT_SOFT_MAX_TOTAL: usize = 64;
const DEFAULT_SOFT_MAX_PER_SOURCE: usize = 8;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum LimitMode {
    Off,
    Warn,
    Enforce,
}

impl LimitMode {
    pub(crate) fn parse(value: &str) -> Self {
        match value.trim().to_ascii_lowercase().as_str() {
            "off" => Self::Off,
            "enforce" => Self::Enforce,
            // Empty and unknown values keep the default.
            _ => Self::Warn,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct Limits {
    pub mode: LimitMode,
    pub soft_per_source: usize,
    pub soft_total: usize,
}

fn parse_count(value: &str, default: usize) -> usize {
    match value.trim().parse::<usize>() {
        // Zero would refuse everything in enforce mode; treat it as unset.
        Ok(count) if count > 0 => count,
        _ => default,
    }
}

impl Limits {
    pub(crate) fn from_values(mode: &str, per_source: &str, total: &str) -> Self {
        Self {
            mode: LimitMode::parse(mode),
            soft_per_source: parse_count(per_source, DEFAULT_SOFT_MAX_PER_SOURCE),
            soft_total: parse_count(total, DEFAULT_SOFT_MAX_TOTAL),
        }
    }

    fn load() -> Self {
        use hbb_common::config::Config;
        Self::from_values(
            &Config::get_option(keys::OPTION_PRELOGIN_LIMIT_MODE),
            &Config::get_option(keys::OPTION_PRELOGIN_MAX_PER_SOURCE),
            &Config::get_option(keys::OPTION_PRELOGIN_MAX_TOTAL),
        )
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Decision {
    Admit,
    /// Over a soft limit that is only reported.
    AdmitOverSoft,
    Refuse(Reason),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Reason {
    HardTotal,
    HardPerSource,
    SoftTotal,
    SoftPerSource,
}

/// `source_count` and `total_count` are the tickets held before this one.
pub(crate) fn decide(
    limits: &Limits,
    loopback: bool,
    source_count: usize,
    total_count: usize,
) -> Decision {
    if loopback {
        // Local helpers and the UI must keep working when the host is flooded.
        return Decision::Admit;
    }
    if total_count >= HARD_MAX_TOTAL {
        return Decision::Refuse(Reason::HardTotal);
    }
    if source_count >= HARD_MAX_PER_SOURCE {
        return Decision::Refuse(Reason::HardPerSource);
    }
    if limits.mode == LimitMode::Off {
        return Decision::Admit;
    }
    let over = if source_count >= limits.soft_per_source {
        Some(Reason::SoftPerSource)
    } else if total_count >= limits.soft_total {
        Some(Reason::SoftTotal)
    } else {
        None
    };
    match (over, limits.mode) {
        (Some(reason), LimitMode::Enforce) => Decision::Refuse(reason),
        (Some(_), _) => Decision::AdmitOverSoft,
        (None, _) => Decision::Admit,
    }
}

#[derive(Default)]
struct State {
    per_source: HashMap<IpAddr, usize>,
    total: usize,
}

fn state() -> &'static Mutex<State> {
    static STATE: OnceLock<Mutex<State>> = OnceLock::new();
    STATE.get_or_init(Default::default)
}

/// Held while a connection has not logged in; dropping it frees the slot.
#[derive(Debug)]
pub struct PreloginTicket {
    key: Option<IpAddr>,
}

impl Drop for PreloginTicket {
    fn drop(&mut self) {
        if let Some(key) = self.key.take() {
            let mut state = state().lock().unwrap();
            state.total = state.total.saturating_sub(1);
            if let Some(count) = state.per_source.get_mut(&key) {
                *count = count.saturating_sub(1);
                if *count == 0 {
                    state.per_source.remove(&key);
                }
            }
        }
    }
}

/// Takes a slot for a new connection from `source`, or says why not.
pub(crate) fn try_admit(source: IpAddr) -> Result<PreloginTicket, Reason> {
    admit_with(&Limits::load(), source)
}

fn admit_with(limits: &Limits, source: IpAddr) -> Result<PreloginTicket, Reason> {
    let key = super::pairing_guard::source_key(source);
    let loopback = source.is_loopback();
    let mut state = state().lock().unwrap();
    let source_count = state.per_source.get(&key).copied().unwrap_or(0);
    match decide(limits, loopback, source_count, state.total) {
        Decision::Refuse(reason) => {
            log::warn!(
                "Refused connection from {source}: {reason:?} ({source_count} from this source, {} waiting in total)",
                state.total
            );
            Err(reason)
        }
        decision => {
            if decision == Decision::AdmitOverSoft {
                log::warn!(
                    "Connection from {source} is over the soft pre-login limit ({source_count} from this source, {} waiting in total); mode is warn",
                    state.total
                );
            }
            if loopback {
                // Not counted: it must not take slots from remote peers either.
                return Ok(PreloginTicket { key: None });
            }
            state.total += 1;
            *state.per_source.entry(key).or_insert(0) += 1;
            Ok(PreloginTicket { key: Some(key) })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn limits(mode: LimitMode) -> Limits {
        Limits {
            mode,
            soft_per_source: 3,
            soft_total: 10,
        }
    }

    #[test]
    fn defaults_warn_and_garbage_falls_back() {
        let default = Limits::from_values("", "", "");
        assert_eq!(default.mode, LimitMode::Warn);
        assert_eq!(default.soft_per_source, DEFAULT_SOFT_MAX_PER_SOURCE);
        assert_eq!(default.soft_total, DEFAULT_SOFT_MAX_TOTAL);
        let odd = Limits::from_values("loud", "0", "many");
        assert_eq!(odd.mode, LimitMode::Warn);
        assert_eq!(odd.soft_per_source, DEFAULT_SOFT_MAX_PER_SOURCE);
        assert_eq!(odd.soft_total, DEFAULT_SOFT_MAX_TOTAL);
        let set = Limits::from_values(" Enforce ", "2", "5");
        assert_eq!(set.mode, LimitMode::Enforce);
        assert_eq!((set.soft_per_source, set.soft_total), (2, 5));
        assert_eq!(LimitMode::parse("OFF"), LimitMode::Off);
    }

    #[test]
    fn warn_mode_admits_over_the_soft_limits() {
        let l = limits(LimitMode::Warn);
        assert_eq!(decide(&l, false, 2, 5), Decision::Admit);
        assert_eq!(decide(&l, false, 3, 5), Decision::AdmitOverSoft);
        assert_eq!(decide(&l, false, 0, 10), Decision::AdmitOverSoft);
    }

    #[test]
    fn enforce_mode_refuses_over_the_soft_limits() {
        let l = limits(LimitMode::Enforce);
        assert_eq!(decide(&l, false, 2, 5), Decision::Admit);
        assert_eq!(
            decide(&l, false, 3, 5),
            Decision::Refuse(Reason::SoftPerSource)
        );
        assert_eq!(
            decide(&l, false, 0, 10),
            Decision::Refuse(Reason::SoftTotal)
        );
    }

    #[test]
    fn hard_ceilings_hold_in_every_mode() {
        for mode in [LimitMode::Off, LimitMode::Warn, LimitMode::Enforce] {
            let l = limits(mode);
            assert_eq!(
                decide(&l, false, HARD_MAX_PER_SOURCE, 1),
                Decision::Refuse(Reason::HardPerSource),
                "{mode:?}"
            );
            assert_eq!(
                decide(&l, false, 0, HARD_MAX_TOTAL),
                Decision::Refuse(Reason::HardTotal),
                "{mode:?}"
            );
        }
        // Off ignores only the soft limits.
        let off = limits(LimitMode::Off);
        assert_eq!(decide(&off, false, 50, 100), Decision::Admit);
    }

    #[test]
    fn loopback_is_never_refused() {
        let l = limits(LimitMode::Enforce);
        assert_eq!(
            decide(&l, true, HARD_MAX_PER_SOURCE, HARD_MAX_TOTAL),
            Decision::Admit
        );
    }

    /// Shared state is global, so these tests use limits that other tests
    /// running in parallel cannot reach.
    fn roomy(per_source: usize) -> Limits {
        Limits {
            mode: LimitMode::Enforce,
            soft_per_source: per_source,
            soft_total: 1000,
        }
    }

    #[test]
    fn tickets_count_per_source_and_release_on_drop() {
        let l = roomy(3);
        let a: IpAddr = "198.51.100.1".parse().unwrap();
        let b: IpAddr = "198.51.100.2".parse().unwrap();
        let _t1 = admit_with(&l, a).unwrap();
        let t2 = admit_with(&l, a).unwrap();
        let _t3 = admit_with(&l, a).unwrap();
        assert_eq!(admit_with(&l, a).unwrap_err(), Reason::SoftPerSource);
        // Another source is unaffected.
        let _other = admit_with(&l, b).unwrap();
        drop(t2);
        assert!(admit_with(&l, a).is_ok());
    }

    #[test]
    fn loopback_tickets_take_no_slot() {
        let l = roomy(1);
        let local: IpAddr = "127.0.0.1".parse().unwrap();
        let tickets: Vec<_> = (0..20).map(|_| admit_with(&l, local).unwrap()).collect();
        assert!(tickets.iter().all(|ticket| ticket.key.is_none()));
        assert!(!state().lock().unwrap().per_source.contains_key(&local));
    }
}
