//! Guard in front of the Argon2id pairing-proof check.
//!
//! The proof check costs tens of milliseconds and a large block of memory per
//! attempt and used to run inline on the connection task, for every
//! unauthenticated connection and without any memory of earlier failures. This
//! module bounds how much of that a single source can cause: one check in
//! flight per source, a small process-wide number of concurrent derivations, a
//! short wait for a slot, and an exponential back-off after repeated wrong
//! proofs. A correct proof is never delayed by an earlier success.

use hbb_common::{
    anyhow::anyhow,
    log,
    sodiumoxide::utils::memcmp,
    tokio::{
        self,
        sync::Semaphore,
        time::{timeout, Duration},
    },
    ResultType,
};
use std::{
    collections::HashMap,
    net::{IpAddr, Ipv6Addr},
    sync::{Mutex, OnceLock},
};

/// Wrong proofs a source may send before back-off starts.
pub(crate) const FREE_PROOF_FAILURES: u32 = 5;
const BACKOFF_BASE_MS: u64 = 10_000;
const BACKOFF_MAX_MS: u64 = 300_000;
/// A source that stays quiet this long starts again from zero.
const IDLE_RESET_MS: u64 = 900_000;
const MAX_IN_FLIGHT_PER_SOURCE: u32 = 1;
const MAX_CONCURRENT_KDF: usize = 2;
const MAX_TRACKED_SOURCES: usize = 4096;
const KDF_QUEUE_WAIT: Duration = Duration::from_secs(3);

/// IPv4 sources are tracked by address, IPv6 sources by their /64, since a
/// single host usually owns a whole /64 and could otherwise rotate addresses.
pub(crate) fn source_key(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V4(_) => ip,
        IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                return IpAddr::V4(v4);
            }
            let mut octets = v6.octets();
            for byte in &mut octets[8..] {
                *byte = 0;
            }
            IpAddr::V6(Ipv6Addr::from(octets))
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Refusal {
    /// The source is in back-off after repeated wrong proofs.
    BackOff { retry_after_ms: u64 },
    /// A check for this source is already running, or the tracker is full.
    Busy,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum Verdict {
    Match,
    Mismatch,
    Rejected(Refusal),
}

#[derive(Default)]
struct Entry {
    failures: u32,
    blocked_until_ms: u64,
    last_ms: u64,
    in_flight: u32,
}

#[derive(Default)]
pub(crate) struct ProofFailureTracker {
    entries: HashMap<IpAddr, Entry>,
}

impl ProofFailureTracker {
    fn backoff_ms(failures: u32) -> u64 {
        if failures <= FREE_PROOF_FAILURES {
            return 0;
        }
        let steps = (failures - FREE_PROOF_FAILURES - 1).min(16);
        BACKOFF_BASE_MS
            .saturating_mul(1u64 << steps)
            .min(BACKOFF_MAX_MS)
    }

    /// Reserves the single in-flight slot of `key`, or says why not.
    pub(crate) fn admit(&mut self, key: IpAddr, now_ms: u64) -> Result<(), Refusal> {
        if let Some(entry) = self.entries.get_mut(&key) {
            if entry.in_flight == 0 && now_ms.saturating_sub(entry.last_ms) >= IDLE_RESET_MS {
                *entry = Entry::default();
            }
            if entry.blocked_until_ms > now_ms {
                return Err(Refusal::BackOff {
                    retry_after_ms: entry.blocked_until_ms - now_ms,
                });
            }
            if entry.in_flight >= MAX_IN_FLIGHT_PER_SOURCE {
                return Err(Refusal::Busy);
            }
            entry.in_flight += 1;
            entry.last_ms = now_ms;
            return Ok(());
        }
        if self.entries.len() >= MAX_TRACKED_SOURCES {
            // Make room by forgetting the longest-idle source with nothing in
            // flight; when every slot is busy, refuse instead of growing.
            let victim = self
                .entries
                .iter()
                .filter(|(_, entry)| entry.in_flight == 0)
                .min_by_key(|(_, entry)| entry.last_ms)
                .map(|(key, _)| *key);
            match victim {
                Some(victim) => {
                    self.entries.remove(&victim);
                }
                None => return Err(Refusal::Busy),
            }
        }
        self.entries.insert(
            key,
            Entry {
                in_flight: 1,
                last_ms: now_ms,
                ..Entry::default()
            },
        );
        Ok(())
    }

    /// Releases the slot taken by `admit` and records the outcome. `checked`
    /// is false when no proof was actually evaluated (queue timeout, internal
    /// error), which must not count against the source.
    pub(crate) fn finish(&mut self, key: IpAddr, now_ms: u64, outcome: Option<bool>) {
        let Some(entry) = self.entries.get_mut(&key) else {
            return;
        };
        entry.in_flight = entry.in_flight.saturating_sub(1);
        entry.last_ms = now_ms;
        match outcome {
            Some(true) => {
                *entry = Entry {
                    in_flight: entry.in_flight,
                    last_ms: now_ms,
                    ..Entry::default()
                };
            }
            Some(false) => {
                entry.failures = entry.failures.saturating_add(1);
                let backoff = Self::backoff_ms(entry.failures);
                if backoff > 0 {
                    entry.blocked_until_ms = now_ms.saturating_add(backoff);
                }
            }
            None => {}
        }
        if entry.in_flight == 0 && entry.failures == 0 {
            self.entries.remove(&key);
        }
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.entries.len()
    }
}

fn tracker() -> &'static Mutex<ProofFailureTracker> {
    static TRACKER: OnceLock<Mutex<ProofFailureTracker>> = OnceLock::new();
    TRACKER.get_or_init(Default::default)
}

fn kdf_slots() -> &'static Semaphore {
    static SLOTS: OnceLock<Semaphore> = OnceLock::new();
    SLOTS.get_or_init(|| Semaphore::new(MAX_CONCURRENT_KDF))
}

fn now_ms() -> u64 {
    super::permission_prompt::mono_ms()
}

/// Everything the proof depends on, owned so that it can move to a blocking
/// thread.
pub(crate) struct ProofInput {
    pub passphrase: String,
    pub salt: [u8; hbb_common::sodiumoxide::crypto::pwhash::argon2id13::SALTBYTES],
    pub peer_id: String,
    pub responder_sign_pk: [u8; 32],
    pub responder_box_pk: [u8; 32],
    pub initiator_box_pk: [u8; 32],
}

/// Checks `claimed` against the proof expected for `input`, bounded per source.
/// On a match the key for the host acknowledgement MAC is returned as well.
pub(crate) async fn check_pairing_proof(
    source: IpAddr,
    input: ProofInput,
    claimed: [u8; crate::common::DIRECT_PAIRING_PROOF_LEN],
) -> ResultType<(Verdict, Option<[u8; 32]>)> {
    let key = source_key(source);
    if let Err(refusal) = tracker().lock().unwrap().admit(key, now_ms()) {
        log::warn!("Pairing proof from {key} refused before the key derivation: {refusal:?}");
        return Ok((Verdict::Rejected(refusal), None));
    }
    let outcome = evaluate(input, claimed).await;
    let counted = match &outcome {
        Ok(Some((matched, _))) => Some(*matched),
        _ => None,
    };
    tracker().lock().unwrap().finish(key, now_ms(), counted);
    match outcome {
        Ok(Some((true, ack_key))) => Ok((Verdict::Match, Some(ack_key))),
        Ok(Some((false, _))) => Ok((Verdict::Mismatch, None)),
        Ok(None) => Ok((Verdict::Rejected(Refusal::Busy), None)),
        Err(error) => Err(error),
    }
}

/// `Ok(None)`: no slot became free in time, nothing was evaluated.
async fn evaluate(
    input: ProofInput,
    claimed: [u8; crate::common::DIRECT_PAIRING_PROOF_LEN],
) -> ResultType<Option<(bool, [u8; 32])>> {
    let permit = match timeout(KDF_QUEUE_WAIT, kdf_slots().acquire()).await {
        Ok(Ok(permit)) => permit,
        Ok(Err(_)) => return Err(anyhow!("Handshake failed: pairing guard unavailable")),
        Err(_) => return Ok(None),
    };
    let (expected, ack_key) = tokio::task::spawn_blocking(move || {
        crate::common::compute_direct_pairing_proof_and_ack_key(
            &input.passphrase,
            &input.salt,
            &input.peer_id,
            &input.responder_sign_pk,
            &input.responder_box_pk,
            &input.initiator_box_pk,
        )
    })
    .await
    .map_err(|_| anyhow!("Handshake failed: pairing check was interrupted"))??;
    drop(permit);
    Ok(Some((memcmp(&claimed, &expected), ack_key)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;

    fn v4(last: u8) -> IpAddr {
        IpAddr::V4(Ipv4Addr::new(192, 0, 2, last))
    }

    fn fail(tracker: &mut ProofFailureTracker, key: IpAddr, now: u64) {
        tracker.admit(key, now).unwrap();
        tracker.finish(key, now, Some(false));
    }

    #[test]
    fn five_wrong_proofs_are_free_then_back_off_starts() {
        let mut tracker = ProofFailureTracker::default();
        let key = v4(1);
        for attempt in 0..FREE_PROOF_FAILURES as u64 {
            fail(&mut tracker, key, attempt);
        }
        // The sixth wrong proof is evaluated, and arms the first back-off.
        fail(&mut tracker, key, 10);
        assert_eq!(
            tracker.admit(key, 11),
            Err(Refusal::BackOff {
                retry_after_ms: BACKOFF_BASE_MS - 1
            })
        );
        assert!(tracker.admit(key, 10 + BACKOFF_BASE_MS).is_ok());
    }

    #[test]
    fn back_off_doubles_up_to_the_cap() {
        assert_eq!(ProofFailureTracker::backoff_ms(5), 0);
        assert_eq!(ProofFailureTracker::backoff_ms(6), 10_000);
        assert_eq!(ProofFailureTracker::backoff_ms(7), 20_000);
        assert_eq!(ProofFailureTracker::backoff_ms(8), 40_000);
        assert_eq!(ProofFailureTracker::backoff_ms(40), BACKOFF_MAX_MS);
        assert_eq!(ProofFailureTracker::backoff_ms(u32::MAX), BACKOFF_MAX_MS);
    }

    #[test]
    fn a_correct_proof_clears_the_failures_of_that_source() {
        let mut tracker = ProofFailureTracker::default();
        let key = v4(2);
        for attempt in 0..4u64 {
            fail(&mut tracker, key, attempt);
        }
        tracker.admit(key, 5).unwrap();
        tracker.finish(key, 5, Some(true));
        assert_eq!(tracker.len(), 0);
        // Five more wrong proofs are free again.
        for attempt in 0..FREE_PROOF_FAILURES as u64 {
            fail(&mut tracker, key, 10 + attempt);
        }
        assert!(tracker.admit(key, 20).is_ok());
    }

    #[test]
    fn only_one_check_per_source_runs_at_a_time() {
        let mut tracker = ProofFailureTracker::default();
        let key = v4(3);
        tracker.admit(key, 0).unwrap();
        assert_eq!(tracker.admit(key, 1), Err(Refusal::Busy));
        assert!(tracker.admit(v4(4), 1).is_ok());
        tracker.finish(key, 2, None);
        assert!(tracker.admit(key, 3).is_ok());
    }

    #[test]
    fn an_unevaluated_attempt_is_not_counted() {
        let mut tracker = ProofFailureTracker::default();
        let key = v4(5);
        for attempt in 0..50u64 {
            tracker.admit(key, attempt).unwrap();
            tracker.finish(key, attempt, None);
        }
        assert_eq!(tracker.len(), 0);
    }

    #[test]
    fn idle_sources_start_again_after_the_reset_period() {
        let mut tracker = ProofFailureTracker::default();
        let key = v4(6);
        // Spaced past the longest back-off but inside the idle period.
        let step = BACKOFF_MAX_MS + 1;
        let mut last = 0;
        for attempt in 0..8u64 {
            last = attempt * step;
            fail(&mut tracker, key, last);
        }
        assert!(matches!(
            tracker.admit(key, last + 1),
            Err(Refusal::BackOff { .. })
        ));
        assert!(tracker.admit(key, last + IDLE_RESET_MS).is_ok());
    }

    #[test]
    fn ipv6_sources_share_their_64() {
        let a: IpAddr = "2001:db8:1:2:aaaa::1".parse().unwrap();
        let b: IpAddr = "2001:db8:1:2:bbbb::9".parse().unwrap();
        let other: IpAddr = "2001:db8:1:3::1".parse().unwrap();
        assert_eq!(source_key(a), source_key(b));
        assert_ne!(source_key(a), source_key(other));
        let mapped: IpAddr = "::ffff:192.0.2.9".parse().unwrap();
        assert_eq!(source_key(mapped), v4(9));
    }

    #[test]
    fn a_full_tracker_forgets_the_oldest_idle_source_and_never_grows() {
        let mut tracker = ProofFailureTracker::default();
        for index in 0..MAX_TRACKED_SOURCES as u32 {
            let key = IpAddr::V4(Ipv4Addr::from(0x0a00_0000 + index));
            fail(&mut tracker, key, index as u64);
        }
        assert_eq!(tracker.len(), MAX_TRACKED_SOURCES);
        let newcomer = v4(200);
        assert!(tracker.admit(newcomer, 1_000_000).is_ok());
        assert_eq!(tracker.len(), MAX_TRACKED_SOURCES);
    }

    #[test]
    fn a_full_tracker_of_busy_sources_refuses_new_ones() {
        let mut tracker = ProofFailureTracker::default();
        for index in 0..MAX_TRACKED_SOURCES as u32 {
            let key = IpAddr::V4(Ipv4Addr::from(0x0a00_0000 + index));
            tracker.admit(key, 0).unwrap();
        }
        assert_eq!(tracker.admit(v4(201), 1), Err(Refusal::Busy));
    }
}
