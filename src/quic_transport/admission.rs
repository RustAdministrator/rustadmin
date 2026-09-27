//! Limits for QUIC connections that are not yet authenticated.
//!
//! A connection is "pending" from the moment the listener takes its first
//! packet until device authentication and application setup finish. Pending
//! connections are limited globally and per source; the authentication step
//! is further split into pools for peers presenting a trusted certificate pin
//! and for first contacts.

use hbb_common::tokio::sync::{Semaphore, SemaphorePermit};
use std::{
    collections::{hash_map::Entry, HashMap},
    net::{IpAddr, Ipv6Addr},
    sync::{Arc, Mutex, PoisonError},
};

pub(super) const MAX_QUIC_PENDING: usize = 32;
pub(super) const MAX_QUIC_PENDING_PER_SOURCE: usize = 4;
/// Above this many pending connections, peers must first prove their source
/// address with a QUIC Retry.
pub(super) const QUIC_RETRY_THRESHOLD: usize = 16;
pub(super) const MAX_TRUSTED_PIN_AUTHENTICATIONS: usize = 16;
pub(super) const MAX_FIRST_CONTACT_AUTHENTICATIONS: usize = 8;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum IncomingDecision {
    Admit,
    Retry,
    Refuse,
}

pub(super) fn incoming_decision(
    pending: usize,
    pending_from_source: usize,
    address_validated: bool,
    may_retry: bool,
) -> IncomingDecision {
    if pending >= MAX_QUIC_PENDING || pending_from_source >= MAX_QUIC_PENDING_PER_SOURCE {
        return IncomingDecision::Refuse;
    }
    // A Retry proves that the peer receives packets at its source address, so
    // spoofed packets cannot fill the remaining slots or a victim's
    // per-source quota. quinn clients answer it without surfacing an error.
    if !address_validated && (pending >= QUIC_RETRY_THRESHOLD || pending_from_source > 0) {
        return if may_retry {
            IncomingDecision::Retry
        } else {
            IncomingDecision::Refuse
        };
    }
    IncomingDecision::Admit
}

/// IPv4 addresses count individually; IPv6 addresses count per /64, the
/// smallest prefix normally assigned to one site.
fn source_key(ip: IpAddr) -> IpAddr {
    match ip.to_canonical() {
        IpAddr::V6(ip) => {
            let mut segments = ip.segments();
            segments[4..].fill(0);
            IpAddr::V6(Ipv6Addr::from(segments))
        }
        ip => ip,
    }
}

#[derive(Default)]
struct PendingConnections {
    total: usize,
    per_source: HashMap<IpAddr, usize>,
}

pub(super) enum Admission {
    Admitted(PendingTicket),
    Retry,
    Refuse,
}

#[derive(Default)]
pub(super) struct HandshakeAdmission {
    state: Arc<Mutex<PendingConnections>>,
}

impl HandshakeAdmission {
    pub(super) fn admit(&self, ip: IpAddr, address_validated: bool, may_retry: bool) -> Admission {
        let source = source_key(ip);
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        let from_source = state.per_source.get(&source).copied().unwrap_or(0);
        match incoming_decision(state.total, from_source, address_validated, may_retry) {
            IncomingDecision::Admit => {
                state.total += 1;
                *state.per_source.entry(source).or_default() += 1;
                Admission::Admitted(PendingTicket {
                    state: self.state.clone(),
                    source,
                })
            }
            IncomingDecision::Retry => Admission::Retry,
            IncomingDecision::Refuse => Admission::Refuse,
        }
    }

    #[cfg(test)]
    pub(super) fn pending(&self) -> usize {
        self.state
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .total
    }
}

/// Counts one pending connection until dropped.
pub(super) struct PendingTicket {
    state: Arc<Mutex<PendingConnections>>,
    source: IpAddr,
}

impl Drop for PendingTicket {
    fn drop(&mut self) {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        state.total = state.total.saturating_sub(1);
        if let Entry::Occupied(mut entry) = state.per_source.entry(self.source) {
            *entry.get_mut() -= 1;
            if *entry.get() == 0 {
                entry.remove();
            }
        }
    }
}

pub(super) struct AuthenticationPools {
    pub(super) trusted_pin: Semaphore,
    pub(super) first_contact: Semaphore,
}

impl Default for AuthenticationPools {
    fn default() -> Self {
        Self {
            trusted_pin: Semaphore::new(MAX_TRUSTED_PIN_AUTHENTICATIONS),
            first_contact: Semaphore::new(MAX_FIRST_CONTACT_AUTHENTICATIONS),
        }
    }
}

impl AuthenticationPools {
    pub(super) fn try_acquire(&self, trusted_pin: bool) -> Option<SemaphorePermit<'_>> {
        if trusted_pin {
            &self.trusted_pin
        } else {
            &self.first_contact
        }
        .try_acquire()
        .ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;

    fn admitted(admission: Admission) -> PendingTicket {
        match admission {
            Admission::Admitted(ticket) => ticket,
            Admission::Retry => panic!("expected admission, got Retry"),
            Admission::Refuse => panic!("expected admission, got Refuse"),
        }
    }

    #[test]
    fn decision_retries_unvalidated_sources_under_load_or_repeat() {
        use IncomingDecision::*;
        assert_eq!(incoming_decision(0, 0, false, true), Admit);
        assert_eq!(incoming_decision(15, 0, false, true), Admit);
        assert_eq!(incoming_decision(16, 0, false, true), Retry);
        assert_eq!(incoming_decision(16, 0, true, false), Admit);
        assert_eq!(incoming_decision(1, 1, false, true), Retry);
        assert_eq!(incoming_decision(1, 1, true, false), Admit);
        assert_eq!(incoming_decision(16, 0, false, false), Refuse);
        assert_eq!(incoming_decision(32, 0, true, false), Refuse);
        assert_eq!(incoming_decision(4, 4, true, false), Refuse);
    }

    #[test]
    fn per_source_limit_refuses_the_next_connection_from_one_address() {
        let admission = HandshakeAdmission::default();
        let attacker = IpAddr::V4(Ipv4Addr::new(203, 0, 113, 7));
        let mut tickets = Vec::new();
        for _ in 0..MAX_QUIC_PENDING_PER_SOURCE {
            tickets.push(admitted(admission.admit(attacker, true, false)));
        }
        assert!(matches!(
            admission.admit(attacker, true, false),
            Admission::Refuse
        ));
        let other = IpAddr::V4(Ipv4Addr::new(198, 51, 100, 1));
        let _other = admitted(admission.admit(other, false, true));
        tickets.pop();
        let _again = admitted(admission.admit(attacker, true, false));
        assert_eq!(admission.pending(), MAX_QUIC_PENDING_PER_SOURCE + 1);
    }

    #[test]
    fn a_spoofed_source_cannot_hold_more_than_one_unvalidated_slot() {
        let admission = HandshakeAdmission::default();
        let victim = IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10));
        let _spoofed = admitted(admission.admit(victim, false, true));
        assert!(matches!(
            admission.admit(victim, false, true),
            Admission::Retry
        ));
        // The real owner of the address answers the Retry and is admitted.
        let _victim = admitted(admission.admit(victim, true, false));
    }

    #[test]
    fn ipv6_sources_share_a_slash_64_and_mapped_ipv4_is_canonical() {
        let admission = HandshakeAdmission::default();
        let mut tickets = Vec::new();
        for host in 1..=MAX_QUIC_PENDING_PER_SOURCE as u16 {
            let ip = IpAddr::V6(Ipv6Addr::new(0x2001, 0xdb8, 1, 2, 0, 0, 0, host));
            tickets.push(admitted(admission.admit(ip, true, false)));
        }
        let same_prefix = IpAddr::V6(Ipv6Addr::new(0x2001, 0xdb8, 1, 2, 9, 9, 9, 9));
        assert!(matches!(
            admission.admit(same_prefix, true, false),
            Admission::Refuse
        ));
        let other_prefix = IpAddr::V6(Ipv6Addr::new(0x2001, 0xdb8, 1, 3, 0, 0, 0, 1));
        tickets.push(admitted(admission.admit(other_prefix, true, false)));

        let v4 = Ipv4Addr::new(203, 0, 113, 9);
        tickets.push(admitted(admission.admit(IpAddr::V4(v4), true, false)));
        assert!(matches!(
            admission.admit(IpAddr::V6(v4.to_ipv6_mapped()), false, true),
            Admission::Retry
        ));
    }

    #[test]
    fn global_limit_applies_across_sources_and_tickets_release_slots() {
        let admission = HandshakeAdmission::default();
        let mut tickets: Vec<_> = (0..MAX_QUIC_PENDING)
            .map(|i| {
                let ip = IpAddr::V4(Ipv4Addr::new(10, 0, (i / 256) as u8, (i % 256) as u8));
                admitted(admission.admit(ip, true, false))
            })
            .collect();
        let fresh = IpAddr::V4(Ipv4Addr::new(10, 9, 9, 9));
        assert!(matches!(
            admission.admit(fresh, true, false),
            Admission::Refuse
        ));
        tickets.clear();
        assert_eq!(admission.pending(), 0);
        let _ticket = admitted(admission.admit(fresh, false, true));
    }

    #[test]
    fn authentication_pools_are_separate() {
        let pools = AuthenticationPools::default();
        let first_contact: Vec<_> = (0..MAX_FIRST_CONTACT_AUTHENTICATIONS)
            .map(|_| pools.try_acquire(false).unwrap())
            .collect();
        assert!(pools.try_acquire(false).is_none());
        let trusted = pools.try_acquire(true);
        assert!(
            trusted.is_some(),
            "first contacts must not starve trusted peers"
        );
        drop(first_contact);
        assert!(pools.try_acquire(false).is_some());
    }
}
