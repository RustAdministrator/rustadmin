//! Rules that only matter when a rendezvous or relay server is configured.
//!
//! A host that is reached directly never sees any of this: the inputs come from
//! the server's messages. Every function here is pure so that the call sites in
//! the mediator and the connection setup stay thin.

use hbb_common::{config::RolloutMode, rendezvous_proto::ControlPermissions};
use std::net::{IpAddr, SocketAddr};

pub const REFUSE_RELAY_WITH_PASSPHRASE: &str =
    "An unencrypted session is not accepted while a pairing passphrase is set";
pub const REFUSE_RELAY_INSECURE: &str =
    "An unencrypted relay session is not allowed on this device";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RelaySecureDecision {
    Allow,
    /// Let it through, but say so in the log.
    Warn,
    Refuse(&'static str),
}

/// Whether a relay or rendezvous session that the server asked to be set up
/// without the key exchange (`secure == false`) may proceed.
///
/// - Any pairing passphrase (rendezvous or direct) makes it a refusal: the
///   passphrase is proven inside that exchange, so there is nothing to protect
///   the session with.
/// - Without a passphrase it is refused only in `enforce` mode and only unless
///   `allow-insecure-relay-session` is on; in `warn` mode it is logged.
/// - `off` is the kill switch.
pub fn relay_secure_policy(
    secure: bool,
    has_passphrase: bool,
    allow_insecure: bool,
    mode: RolloutMode,
) -> RelaySecureDecision {
    if secure || mode == RolloutMode::Off {
        return RelaySecureDecision::Allow;
    }
    if has_passphrase {
        return RelaySecureDecision::Refuse(REFUSE_RELAY_WITH_PASSPHRASE);
    }
    if allow_insecure {
        return RelaySecureDecision::Allow;
    }
    match mode {
        RolloutMode::Enforce => RelaySecureDecision::Refuse(REFUSE_RELAY_INSECURE),
        _ => RelaySecureDecision::Warn,
    }
}

const PERMISSION_SLOTS: u32 = 32;

/// Applies the local policy to the permissions a rendezvous/relay server sent.
///
/// A server may always take a permission away (`disable`). It may give one
/// (`enable`) only when `allow-server-permission-grants` is on; otherwise an
/// `enable` is dropped and the local setting decides. Returns `None` when
/// nothing is left to apply.
pub fn strip_server_grants(
    control_permissions: Option<ControlPermissions>,
    allow_grants: bool,
) -> Option<ControlPermissions> {
    let mut cp = control_permissions?;
    if !allow_grants {
        let mut kept = 0u64;
        for slot in 0..PERMISSION_SLOTS {
            let shift = slot * 2;
            // 1 = disable is kept; 2 = enable and 3 = invalid are dropped.
            if (cp.permissions >> shift) & 0b11 == 0b01 {
                kept |= 0b01 << shift;
            }
        }
        cp.permissions = kept;
    }
    (cp.permissions != 0).then_some(cp)
}

/// True when `strip_server_grants` would drop at least one `enable` grant.
pub fn has_server_grants(control_permissions: &Option<ControlPermissions>) -> bool {
    let Some(cp) = control_permissions else {
        return false;
    };
    (0..PERMISSION_SLOTS).any(|slot| (cp.permissions >> (slot * 2)) & 0b11 == 0b10)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UdpSourceAction {
    Accept,
    /// Let the datagram through and log that its source was unexpected.
    AcceptAndWarn,
    Drop,
}

fn canonical_ip(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(ip),
        v4 => v4,
    }
}

/// Whether `source` is one of the addresses the rendezvous server was resolved
/// to (an IPv4 address mapped into IPv6 counts as that IPv4 address). An empty
/// list means the server's address is not known and nothing can be judged.
pub fn udp_source_matches(source: SocketAddr, expected: &[SocketAddr]) -> Option<bool> {
    if expected.is_empty() {
        return None;
    }
    let source_ip = canonical_ip(source.ip());
    Some(
        expected
            .iter()
            .any(|e| canonical_ip(e.ip()) == source_ip && e.port() == source.port()),
    )
}

pub fn udp_source_action(mode: RolloutMode, matches: Option<bool>) -> UdpSourceAction {
    match (mode, matches) {
        (RolloutMode::Off, _) | (_, None) | (_, Some(true)) => UdpSourceAction::Accept,
        (RolloutMode::Warn, Some(false)) => UdpSourceAction::AcceptAndWarn,
        (RolloutMode::Enforce, Some(false)) => UdpSourceAction::Drop,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use RelaySecureDecision::{Allow, Refuse};

    #[test]
    fn relay_policy_table() {
        use RolloutMode::{Enforce, Off, Warn};
        const WARN: RelaySecureDecision = RelaySecureDecision::Warn;
        // (secure, passphrase, allow, mode) -> decision
        let cases = [
            (true, true, false, Enforce, Allow),
            (true, false, false, Enforce, Allow),
            (
                false,
                true,
                false,
                Warn,
                Refuse(REFUSE_RELAY_WITH_PASSPHRASE),
            ),
            (
                false,
                true,
                true,
                Warn,
                Refuse(REFUSE_RELAY_WITH_PASSPHRASE),
            ),
            (
                false,
                true,
                false,
                Enforce,
                Refuse(REFUSE_RELAY_WITH_PASSPHRASE),
            ),
            (
                false,
                true,
                true,
                Enforce,
                Refuse(REFUSE_RELAY_WITH_PASSPHRASE),
            ),
            (false, false, false, Warn, WARN),
            (false, false, true, Warn, Allow),
            (false, false, false, Enforce, Refuse(REFUSE_RELAY_INSECURE)),
            (false, false, true, Enforce, Allow),
            (false, true, false, Off, Allow),
            (false, false, false, Off, Allow),
        ];
        for (secure, passphrase, allow, mode, want) in cases {
            assert_eq!(
                relay_secure_policy(secure, passphrase, allow, mode),
                want,
                "secure={secure} passphrase={passphrase} allow={allow} mode={mode:?}"
            );
        }
    }

    fn cp(slots: &[(u32, u64)]) -> Option<ControlPermissions> {
        let mut permissions = 0u64;
        for (slot, value) in slots {
            permissions |= value << (slot * 2);
        }
        Some(ControlPermissions {
            permissions,
            ..Default::default()
        })
    }

    #[test]
    fn server_enable_is_dropped_but_disable_is_kept() {
        let sent = cp(&[(0, 2), (2, 1), (3, 2), (4, 3)]);
        assert!(has_server_grants(&sent));
        let stripped = strip_server_grants(sent.clone(), false).unwrap();
        assert_eq!(stripped.permissions, 0b01 << 4);
        // With the option on nothing changes.
        assert_eq!(strip_server_grants(sent.clone(), true), sent);
    }

    #[test]
    fn nothing_left_means_none() {
        assert_eq!(strip_server_grants(cp(&[(0, 2), (1, 2)]), false), None);
        assert_eq!(strip_server_grants(None, false), None);
        assert_eq!(strip_server_grants(None, true), None);
        assert!(!has_server_grants(&None));
        assert!(!has_server_grants(&cp(&[(0, 1)])));
    }

    #[test]
    fn udp_source_comparison_handles_mapped_addresses() {
        let server: SocketAddr = "203.0.113.5:21116".parse().unwrap();
        let mapped: SocketAddr = "[::ffff:203.0.113.5]:21116".parse().unwrap();
        let other: SocketAddr = "203.0.113.6:21116".parse().unwrap();
        let wrong_port: SocketAddr = "203.0.113.5:40000".parse().unwrap();
        assert_eq!(udp_source_matches(server, &[server]), Some(true));
        assert_eq!(udp_source_matches(mapped, &[server]), Some(true));
        assert_eq!(udp_source_matches(server, &[mapped]), Some(true));
        assert_eq!(udp_source_matches(other, &[server]), Some(false));
        assert_eq!(udp_source_matches(wrong_port, &[server]), Some(false));
        assert_eq!(udp_source_matches(server, &[other, server]), Some(true));
        assert_eq!(udp_source_matches(server, &[]), None);
    }

    #[test]
    fn udp_source_action_by_mode() {
        use RolloutMode::{Enforce, Off, Warn};
        assert_eq!(udp_source_action(Warn, Some(true)), UdpSourceAction::Accept);
        assert_eq!(
            udp_source_action(Warn, Some(false)),
            UdpSourceAction::AcceptAndWarn
        );
        assert_eq!(
            udp_source_action(Enforce, Some(false)),
            UdpSourceAction::Drop
        );
        assert_eq!(udp_source_action(Off, Some(false)), UdpSourceAction::Accept);
        assert_eq!(udp_source_action(Enforce, None), UdpSourceAction::Accept);
    }
}
