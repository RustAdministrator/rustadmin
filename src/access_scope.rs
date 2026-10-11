//! Which peers may reach the direct-access listeners.
//!
//! `direct-access-scope` empty (installs that never chose) or `any` accepts
//! every address, as before. Any other value is `local`: the peer must be on a
//! loopback, private, link-local, shared (CGNAT, as used by common VPNs) or
//! unique-local address, in a network one of this device's interfaces is in,
//! or in one of the networks listed in `direct-access-extra-networks`. The
//! check runs when a connection is accepted, before any handshake work.

use std::{
    net::IpAddr,
    sync::{Arc, Mutex, OnceLock},
    time::{Duration, Instant},
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AccessScope {
    Any,
    Local,
}

impl AccessScope {
    /// Empty and `any` accept everyone; every other value is `local`, so a
    /// misspelled or future value never widens access.
    pub fn parse(value: &str) -> Self {
        match value.trim().to_ascii_lowercase().as_str() {
            "" | "any" => Self::Any,
            _ => Self::Local,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Any => "any",
            Self::Local => "local",
        }
    }
}

/// A network: an address and how many leading bits of it count.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Prefix {
    addr: IpAddr,
    len: u8,
}

impl Prefix {
    pub fn new(addr: IpAddr, len: u8) -> Option<Self> {
        let addr = normalize(addr);
        let max = if addr.is_ipv4() { 32 } else { 128 };
        (len <= max).then_some(Self { addr, len })
    }

    /// `a.b.c.d/len`, `a:b::/len`, or a single address (a host prefix).
    pub fn parse(text: &str) -> Option<Self> {
        let text = text.trim();
        let (addr_text, len_text) = match text.split_once('/') {
            Some((addr, len)) => (addr, Some(len)),
            None => (text, None),
        };
        let addr: IpAddr = addr_text.trim().parse().ok()?;
        let addr = normalize(addr);
        let max = if addr.is_ipv4() { 32 } else { 128 };
        let len = match len_text {
            Some(len) => len.trim().parse::<u8>().ok()?,
            None => max,
        };
        Self::new(addr, len)
    }

    pub fn contains(&self, ip: IpAddr) -> bool {
        match (self.addr, normalize(ip)) {
            (IpAddr::V4(net), IpAddr::V4(ip)) => {
                masked_eq(u32::from(net) as u128, u32::from(ip) as u128, 32, self.len)
            }
            (IpAddr::V6(net), IpAddr::V6(ip)) => {
                masked_eq(u128::from(net), u128::from(ip), 128, self.len)
            }
            _ => false,
        }
    }
}

fn masked_eq(a: u128, b: u128, width: u32, len: u8) -> bool {
    let len = len as u32;
    if len == 0 {
        return true;
    }
    let shift = width - len.min(width);
    (a >> shift) == (b >> shift)
}

/// IPv4-mapped IPv6 addresses are treated as the IPv4 address they carry.
fn normalize(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V6(v6) => v6
            .to_ipv4_mapped()
            .map(IpAddr::V4)
            .unwrap_or(IpAddr::V6(v6)),
        other => other,
    }
}

/// Addresses that are local by their kind alone.
pub fn is_static_local(ip: IpAddr) -> bool {
    match normalize(ip) {
        IpAddr::V4(v4) => {
            v4.is_loopback()
                || v4.is_private()
                || v4.is_link_local()
                // 100.64.0.0/10, the shared address space VPN overlays use.
                || (v4.octets()[0] == 100 && (v4.octets()[1] & 0xc0) == 0x40)
        }
        IpAddr::V6(v6) => {
            v6.is_loopback()
                // fc00::/7 unique local, fe80::/10 link local.
                || (v6.segments()[0] & 0xfe00) == 0xfc00
                || (v6.segments()[0] & 0xffc0) == 0xfe80
        }
    }
}

/// The networks of this device's own interfaces.
#[derive(Clone, Debug, Default)]
pub struct InterfaceSnapshot {
    pub networks: Vec<Prefix>,
}

pub fn scope_permits(
    scope: AccessScope,
    peer: IpAddr,
    interfaces: &InterfaceSnapshot,
    extra_networks: &[Prefix],
) -> bool {
    match scope {
        AccessScope::Any => true,
        AccessScope::Local => {
            is_static_local(peer)
                || extra_networks.iter().any(|prefix| prefix.contains(peer))
                || interfaces
                    .networks
                    .iter()
                    .any(|prefix| prefix.contains(peer))
        }
    }
}

/// Splits `direct-access-extra-networks`; entries that do not parse are
/// returned separately so the UI can show them.
pub fn parse_extra_networks(value: &str) -> (Vec<Prefix>, Vec<String>) {
    let mut valid = Vec::new();
    let mut invalid = Vec::new();
    for entry in value
        .split(|c: char| c == ',' || c == ';' || c.is_whitespace())
        .filter(|entry| !entry.is_empty())
    {
        match Prefix::parse(entry) {
            // A /0 would turn "local" into "any" by another name.
            Some(prefix) if prefix.len > 0 => valid.push(prefix),
            _ => invalid.push(entry.to_owned()),
        }
    }
    (valid, invalid)
}

const CACHE_TTL: Duration = Duration::from_secs(5);
const CACHE_MIN_REFRESH: Duration = Duration::from_secs(1);

/// Interface networks, refreshed at most once a second and kept for five.
pub struct InterfaceCache<F: Fn() -> Vec<Prefix>> {
    source: F,
    state: Mutex<CacheState>,
}

struct CacheState {
    snapshot: Arc<InterfaceSnapshot>,
    taken_at: Option<Instant>,
    last_attempt: Option<Instant>,
}

impl<F: Fn() -> Vec<Prefix>> InterfaceCache<F> {
    pub fn new(source: F) -> Self {
        Self {
            source,
            state: Mutex::new(CacheState {
                snapshot: Arc::new(InterfaceSnapshot::default()),
                taken_at: None,
                last_attempt: None,
            }),
        }
    }

    pub fn snapshot(&self, now: Instant) -> Arc<InterfaceSnapshot> {
        let mut state = self.state.lock().unwrap();
        let fresh = state
            .taken_at
            .is_some_and(|taken| now.saturating_duration_since(taken) < CACHE_TTL);
        if fresh {
            return state.snapshot.clone();
        }
        let throttled = state
            .last_attempt
            .is_some_and(|last| now.saturating_duration_since(last) < CACHE_MIN_REFRESH);
        if throttled {
            return state.snapshot.clone();
        }
        state.last_attempt = Some(now);
        state.snapshot = Arc::new(InterfaceSnapshot {
            networks: (self.source)(),
        });
        state.taken_at = Some(now);
        state.snapshot.clone()
    }
}

#[cfg(not(target_os = "ios"))]
fn system_interface_networks() -> Vec<Prefix> {
    let mut networks = Vec::new();
    for interface in default_net::get_interfaces() {
        for v4 in &interface.ipv4 {
            if v4.addr.is_loopback() || v4.addr.is_unspecified() {
                continue;
            }
            // A prefix of 0 or a missing one would make every address local.
            if v4.prefix_len >= 8 {
                networks.extend(Prefix::new(IpAddr::V4(v4.addr), v4.prefix_len));
            } else {
                networks.extend(Prefix::new(IpAddr::V4(v4.addr), 32));
            }
        }
        for v6 in &interface.ipv6 {
            if v6.addr.is_loopback() || v6.addr.is_unspecified() {
                continue;
            }
            if v6.prefix_len >= 16 {
                networks.extend(Prefix::new(IpAddr::V6(v6.addr), v6.prefix_len));
            } else {
                networks.extend(Prefix::new(IpAddr::V6(v6.addr), 128));
            }
        }
    }
    networks
}

#[cfg(target_os = "ios")]
fn system_interface_networks() -> Vec<Prefix> {
    Vec::new()
}

fn interface_cache() -> &'static InterfaceCache<fn() -> Vec<Prefix>> {
    static CACHE: OnceLock<InterfaceCache<fn() -> Vec<Prefix>>> = OnceLock::new();
    CACHE.get_or_init(|| InterfaceCache::new(system_interface_networks as fn() -> Vec<Prefix>))
}

/// The scope in force right now, from the options.
pub fn current_scope() -> AccessScope {
    use hbb_common::config::{keys, Config};
    AccessScope::parse(&Config::get_option(keys::OPTION_DIRECT_ACCESS_SCOPE))
}

/// Whether a direct connection from `peer` may be accepted at all.
pub fn peer_in_direct_access_scope(peer: IpAddr) -> bool {
    use hbb_common::config::{keys, Config};
    let scope = current_scope();
    if scope == AccessScope::Any {
        return true;
    }
    let (extra, _) = parse_extra_networks(&Config::get_option(
        keys::OPTION_DIRECT_ACCESS_EXTRA_NETWORKS,
    ));
    let interfaces = interface_cache().snapshot(Instant::now());
    scope_permits(scope, peer, &interfaces, &extra)
}

/// Whether the QUIC listener should run. It follows the direct-access switch
/// unless `quic-follow-direct-server=N`.
pub fn quic_listener_wanted(
    transport_is_tcp_only: bool,
    stop_service: bool,
    follow_direct_server: bool,
    direct_server_enabled: bool,
) -> bool {
    if transport_is_tcp_only || stop_service {
        return false;
    }
    !follow_direct_server || direct_server_enabled
}

/// What the settings UI shows about the scope, as JSON.
pub fn scope_info_json() -> String {
    use hbb_common::config::{keys, Config};
    let scope = current_scope();
    let (extra, invalid) = parse_extra_networks(&Config::get_option(
        keys::OPTION_DIRECT_ACCESS_EXTRA_NETWORKS,
    ));
    let interfaces = interface_cache().snapshot(Instant::now());
    let describe = |prefix: &Prefix| format!("{}/{}", prefix.addr, prefix.len);
    serde_json::json!({
        "scope": scope.as_str(),
        "configured": Config::get_option(keys::OPTION_DIRECT_ACCESS_SCOPE),
        "extra_networks": extra.iter().map(describe).collect::<Vec<_>>(),
        "invalid_extra_networks": invalid,
        "interface_networks": interfaces.networks.iter().map(describe).collect::<Vec<_>>(),
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ip(text: &str) -> IpAddr {
        text.parse().unwrap()
    }

    #[test]
    fn only_empty_and_any_mean_any() {
        assert_eq!(AccessScope::parse(""), AccessScope::Any);
        assert_eq!(AccessScope::parse("  "), AccessScope::Any);
        assert_eq!(AccessScope::parse("any"), AccessScope::Any);
        assert_eq!(AccessScope::parse("ANY"), AccessScope::Any);
        assert_eq!(AccessScope::parse("local"), AccessScope::Local);
        // Unknown values narrow, never widen.
        for value in ["lan", "Local-Only", "1", "yes", "internet"] {
            assert_eq!(AccessScope::parse(value), AccessScope::Local, "{value}");
        }
    }

    #[test]
    fn static_local_covers_private_shared_and_link_local_ranges() {
        for local in [
            "127.0.0.1",
            "10.1.2.3",
            "172.16.0.1",
            "172.31.255.255",
            "192.168.1.9",
            "169.254.10.10",
            "100.64.0.1",
            "100.127.255.254",
            "::1",
            "fd12:3456::1",
            "fe80::1",
            "::ffff:192.168.1.5",
        ] {
            assert!(is_static_local(ip(local)), "{local}");
        }
        for remote in [
            "8.8.8.8",
            "172.32.0.1",
            "100.63.255.255",
            "100.128.0.1",
            "203.0.113.5",
            "2001:db8::1",
            "::ffff:8.8.8.8",
        ] {
            assert!(!is_static_local(ip(remote)), "{remote}");
        }
    }

    #[test]
    fn prefixes_parse_and_match() {
        let net = Prefix::parse("203.0.113.0/24").unwrap();
        assert!(net.contains(ip("203.0.113.77")));
        assert!(!net.contains(ip("203.0.114.1")));
        assert!(net.contains(ip("::ffff:203.0.113.5")));
        let host = Prefix::parse("198.51.100.7").unwrap();
        assert!(host.contains(ip("198.51.100.7")));
        assert!(!host.contains(ip("198.51.100.8")));
        let v6 = Prefix::parse("2001:db8:1::/48").unwrap();
        assert!(v6.contains(ip("2001:db8:1:ffff::1")));
        assert!(!v6.contains(ip("2001:db8:2::1")));
        // A family mismatch never matches.
        assert!(!v6.contains(ip("203.0.113.1")));
        for bad in ["", "abc", "10.0.0.0/33", "::/129", "10.0.0.0/x", "1.2.3/24"] {
            assert!(Prefix::parse(bad).is_none(), "{bad}");
        }
    }

    #[test]
    fn extra_networks_reject_garbage_and_the_whole_internet() {
        let (valid, invalid) =
            parse_extra_networks("203.0.113.0/24, 198.51.100.7;bad, 0.0.0.0/0  ::/0 10.0.0.0/8");
        assert_eq!(valid.len(), 3);
        assert_eq!(
            invalid,
            vec!["bad".to_owned(), "0.0.0.0/0".to_owned(), "::/0".to_owned()]
        );
    }

    #[test]
    fn scope_decisions() {
        let interfaces = InterfaceSnapshot {
            networks: vec![Prefix::parse("198.51.100.0/24").unwrap()],
        };
        let extra = vec![Prefix::parse("203.0.113.0/28").unwrap()];
        // Any accepts everything.
        assert!(scope_permits(
            AccessScope::Any,
            ip("8.8.8.8"),
            &interfaces,
            &[]
        ));
        // Local: static ranges, interface networks and extra networks only.
        for allowed in ["192.168.0.5", "198.51.100.200", "203.0.113.9"] {
            assert!(
                scope_permits(AccessScope::Local, ip(allowed), &interfaces, &extra),
                "{allowed}"
            );
        }
        for refused in ["8.8.8.8", "203.0.113.200", "2001:db8::5"] {
            assert!(
                !scope_permits(AccessScope::Local, ip(refused), &interfaces, &extra),
                "{refused}"
            );
        }
    }

    #[test]
    fn interface_cache_keeps_a_snapshot_and_rate_limits_refreshes() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let calls = Arc::new(AtomicUsize::new(0));
        let counter = calls.clone();
        let cache = InterfaceCache::new(move || {
            counter.fetch_add(1, Ordering::SeqCst);
            vec![Prefix::parse("10.0.0.0/8").unwrap()]
        });
        let start = Instant::now();
        assert_eq!(cache.snapshot(start).networks.len(), 1);
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        // Within the TTL: no new read.
        cache.snapshot(start + Duration::from_secs(4));
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        // Past the TTL: one read, and not a second one right after.
        cache.snapshot(start + Duration::from_secs(6));
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        cache.snapshot(start + Duration::from_millis(6_100));
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn quic_listener_follows_the_direct_switch_unless_told_not_to() {
        // (tcp only, stop service, follow, direct enabled) -> wanted
        assert!(quic_listener_wanted(false, false, true, true));
        assert!(!quic_listener_wanted(false, false, true, false));
        assert!(quic_listener_wanted(false, false, false, false));
        assert!(!quic_listener_wanted(true, false, false, true));
        assert!(!quic_listener_wanted(false, true, false, true));
    }
}
