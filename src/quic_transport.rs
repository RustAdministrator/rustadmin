#[cfg(not(target_os = "ios"))]
use crate::server::ServerPtr;
#[cfg(not(target_os = "ios"))]
use admission::{Admission, AuthenticationPools, HandshakeAdmission, PendingTicket};
#[cfg(not(target_os = "ios"))]
use hbb_common::config::option2bool;
#[cfg(not(target_os = "ios"))]
use hbb_common::transport::quic::{
    peer_certificate_pin, CertificatePin, Incoming, IncomingHandshake, QuicServerEndpoint,
};
use hbb_common::{
    anyhow::{anyhow, bail, Context},
    config::Config,
    rand::{rngs::OsRng, RngCore},
    tokio,
    transport::{
        application::{ApplicationQuicRole, QuicApplicationStream},
        configuration::{NetworkTransportConfig, RemoteTransportMode},
        identity::{default_identity_directory, LocalTlsIdentity},
        pairing::{
            FileTrustedPeerStore, PairingCandidate, PairingError, TrustedPeerRecord,
            TrustedPeerStore,
        },
        quic::{
            AuthenticatedControlChannel, DeviceIdentity, QuicClientEndpoint, QuicTransportError,
            QuicTransportOptions,
        },
    },
    ResultType, Stream,
};
use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    time::{SystemTime, UNIX_EPOCH},
};
#[cfg(not(target_os = "ios"))]
use std::{sync::Arc, time::Duration};

#[cfg(not(target_os = "ios"))]
mod admission;

/// Time for application negotiation and channel setup on top of the TLS and
/// authentication timeouts before an incoming connection is given up.
#[cfg(not(target_os = "ios"))]
const QUIC_ESTABLISH_GRACE: Duration = Duration::from_secs(20);
#[cfg(not(target_os = "ios"))]
const QUIC_REFUSAL_LOG_INTERVAL: Duration = Duration::from_secs(10);

pub async fn connect_pretrusted(
    peer_id: &str,
    connect_address: &str,
) -> ResultType<Option<Stream>> {
    let config = NetworkTransportConfig::load()?;
    if config.mode == RemoteTransportMode::Tcp {
        return Ok(None);
    }
    match connect_pretrusted_inner(peer_id, connect_address, &config, false).await {
        Ok(stream) => Ok(Some(stream)),
        Err(DirectQuicConnectError::Unavailable(error))
            if config.mode == RemoteTransportMode::QuicPreferred =>
        {
            hbb_common::log::warn!(
                "QUIC direct connection unavailable; falling back to TCP: peer={}, target={}, error={}",
                peer_id,
                connect_address,
                error
            );
            Ok(None)
        }
        Err(error) => Err(error.into_error()),
    }
}

#[derive(Debug)]
pub(crate) struct QuicIdentityRepairRequired(String);

impl std::fmt::Display for QuicIdentityRepairRequired {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "QUIC saved identity verification failed; authenticated re-pairing required: {}",
            self.0
        )
    }
}
impl std::error::Error for QuicIdentityRepairRequired {}

// This transport conveys authentication only. The caller must verify SignedId
// against saved signing trust or prove the configured pairing passphrase before
// returning a usable session. No stored identity is deleted here.
pub(crate) async fn connect_pairing_candidate(peer_id: &str, address: &str) -> ResultType<Stream> {
    let config = NetworkTransportConfig::load()?;
    if config.mode == RemoteTransportMode::Tcp {
        bail!("QUIC authentication recovery is disabled by the selected transport mode");
    }
    connect_pretrusted_inner(peer_id, address, &config, true)
        .await
        .map_err(DirectQuicConnectError::into_error)
}

enum DirectQuicConnectError {
    Unavailable(hbb_common::anyhow::Error),
    Fatal(hbb_common::anyhow::Error),
}

impl DirectQuicConnectError {
    fn fatal(error: impl Into<hbb_common::anyhow::Error>) -> Self {
        Self::Fatal(error.into())
    }

    fn unavailable(error: impl Into<hbb_common::anyhow::Error>) -> Self {
        Self::Unavailable(error.into())
    }

    fn into_error(self) -> hbb_common::anyhow::Error {
        match self {
            Self::Unavailable(error) | Self::Fatal(error) => error,
        }
    }
}

async fn connect_pretrusted_inner(
    peer_id: &str,
    connect_address: &str,
    config: &NetworkTransportConfig,
    repair: bool,
) -> Result<Stream, DirectQuicConnectError> {
    let store = FileTrustedPeerStore::new(&config.trusted_peer_store)
        .map_err(DirectQuicConnectError::fatal)?;
    let trusted = if repair {
        None
    } else {
        store.load(peer_id).map_err(DirectQuicConnectError::fatal)?
    };
    let identity = local_tls_identity().map_err(DirectQuicConnectError::fatal)?;
    let peer_address =
        resolve_peer_address(connect_address, config.listen_port, config.enable_ipv6)
            .await
            .map_err(DirectQuicConnectError::unavailable)?;
    let bind_ip = compatible_client_bind(config.listen_address, peer_address.ip());
    let options = quic_options(config);
    let credentials = identity
        .credentials()
        .map_err(DirectQuicConnectError::fatal)?;
    let endpoint = if let Some(trusted) = trusted.as_ref() {
        QuicClientEndpoint::bind(
            SocketAddr::new(bind_ip, 0),
            credentials,
            trusted.certificate_der.clone().into(),
            &options,
        )
    } else {
        hbb_common::log::info!(
            "Starting bounded QUIC first-contact authentication for unpaired peer {peer_id}"
        );
        QuicClientEndpoint::bind_provisional(SocketAddr::new(bind_ip, 0), credentials, &options)
    }
    .map_err(|error| match error {
        QuicTransportError::UdpBind(_)
        | QuicTransportError::UdpDisabled
        | QuicTransportError::EndpointClosed
        | QuicTransportError::Unreachable(_)
        | QuicTransportError::Timeout(_) => DirectQuicConnectError::unavailable(error),
        _ => DirectQuicConnectError::fatal(error),
    })?;
    let connection = endpoint.connect(peer_address).await.map_err(|error| {
        if trusted.is_some()
            && matches!(
                error,
                QuicTransportError::Handshake(_) | QuicTransportError::CertificatePinMismatch
            )
        {
            return DirectQuicConnectError::fatal(QuicIdentityRepairRequired(error.to_string()));
        }
        let unavailable = matches!(
            error,
            QuicTransportError::Timeout(_)
                | QuicTransportError::EndpointClosed
                | QuicTransportError::Unreachable(_)
                | QuicTransportError::UdpBind(_)
        );
        let error = anyhow!("QUIC connection to {peer_address} failed: {error}");
        if unavailable {
            DirectQuicConnectError::unavailable(error)
        } else {
            DirectQuicConnectError::fatal(error)
        }
    })?;
    let local_address = endpoint
        .local_addr()
        .map_err(DirectQuicConnectError::fatal)?;
    let mut session_id = [0u8; 16];
    OsRng.fill_bytes(&mut session_id);
    if session_id.iter().all(|byte| *byte == 0) {
        session_id[0] = 1;
    }
    let device_identity = DeviceIdentity::from_config().map_err(DirectQuicConnectError::fatal)?;
    let authentication = if let Some(trusted) = trusted.as_ref() {
        AuthenticatedControlChannel::authenticate_client(
            connection,
            &device_identity,
            trusted.identity_key,
            session_id,
            options.authentication_timeout,
        )
        .await
    } else {
        AuthenticatedControlChannel::authenticate_client_discover_peer(
            connection,
            &device_identity,
            session_id,
            options.authentication_timeout,
        )
        .await
    }
    .map_err(|error| {
        if trusted.is_some() && matches!(error, QuicTransportError::Authentication(_)) {
            DirectQuicConnectError::fatal(QuicIdentityRepairRequired(error.to_string()))
        } else {
            DirectQuicConnectError::fatal(error)
        }
    })?;
    let mut application = QuicApplicationStream::establish(
        authentication,
        ApplicationQuicRole::Client,
        local_address,
    )
    .await
    .map_err(DirectQuicConnectError::fatal)?;
    application.keep_endpoint_alive(endpoint.lease());
    Ok(Stream::from_quic(application))
}

#[cfg(not(target_os = "ios"))]
pub async fn run_direct_server(server: ServerPtr) {
    loop {
        if let Err(error) = run_direct_server_once(server.clone()).await {
            hbb_common::log::warn!("QUIC direct server stopped: {error}");
            tokio::time::sleep(Duration::from_secs(5)).await;
        }
    }
}

#[cfg(not(target_os = "ios"))]
async fn run_direct_server_once(server: ServerPtr) -> ResultType<()> {
    let config = NetworkTransportConfig::load()?;
    if config.mode == RemoteTransportMode::Tcp
        || option2bool("stop-service", &Config::get_option("stop-service"))
    {
        tokio::time::sleep(Duration::from_secs(5)).await;
        return Ok(());
    }
    let store = FileTrustedPeerStore::new(&config.trusted_peer_store)?;
    let identity = local_tls_identity()?;
    let options = quic_options(&config);
    let bind_address = SocketAddr::new(config.listen_address, config.listen_port);
    let endpoint =
        QuicServerEndpoint::bind_provisional(bind_address, identity.credentials()?, &options)?;
    let context = Arc::new(DirectServerContext {
        store,
        identity: DeviceIdentity::from_config()?,
        authentication_timeout: options.authentication_timeout,
        establish_deadline: establish_deadline(&options),
        endpoint_address: endpoint.local_addr()?,
        pools: AuthenticationPools::default(),
    });
    let admission = HandshakeAdmission::default();
    let mut refused = 0u64;
    let mut refusal_logged_at: Option<std::time::Instant> = None;
    loop {
        let current = NetworkTransportConfig::load()?;
        if current.mode == RemoteTransportMode::Tcp
            || current.listen_address != config.listen_address
            || current.listen_port != config.listen_port
            || option2bool("stop-service", &Config::get_option("stop-service"))
        {
            endpoint.close_and_wait().await;
            return Ok(());
        }
        let incoming = match endpoint.accept_incoming().await {
            Ok(incoming) => incoming,
            Err(QuicTransportError::Timeout(_)) => continue,
            Err(error) => return Err(error.into()),
        };
        let remote_address = incoming.remote_address();
        if !crate::common::ip_allowed_by_whitelist(
            &Config::get_option("whitelist"),
            remote_address.ip(),
        ) {
            // Before any admission slot, handshake or key derivation.
            incoming.refuse();
            continue;
        }
        let ticket = match admission.admit(
            remote_address.ip(),
            incoming.remote_address_validated(),
            incoming.may_retry(),
        ) {
            Admission::Admitted(ticket) => ticket,
            Admission::Retry => {
                // A failed Retry drops, and thereby refuses, the connection.
                if let Err(error) = incoming.retry() {
                    hbb_common::log::debug!("QUIC Retry to {remote_address} failed: {error}");
                }
                continue;
            }
            Admission::Refuse => {
                incoming.refuse();
                refused += 1;
                if refusal_logged_at
                    .map_or(true, |logged| logged.elapsed() >= QUIC_REFUSAL_LOG_INTERVAL)
                {
                    hbb_common::log::warn!(
                        "Refused {refused} QUIC connection(s) over the unauthenticated connection limits; last from {remote_address}"
                    );
                    refused = 0;
                    refusal_logged_at = Some(std::time::Instant::now());
                }
                continue;
            }
        };
        let handshake = endpoint.incoming_handshake();
        let context = context.clone();
        let server = server.clone();
        tokio::spawn(async move {
            let result = match establish_incoming(&context, handshake, incoming, ticket).await {
                Ok((stream, peer_label)) => crate::server::create_direct_tcp_connection(
                    server,
                    stream,
                    remote_address,
                    None,
                )
                .await
                .map_err(|error| anyhow!("peer={peer_label}: {error}")),
                Err(error) => Err(error),
            };
            if let Err(error) = result {
                hbb_common::log::warn!(
                    "QUIC direct session failed: address={}, error={}",
                    remote_address,
                    error
                );
            }
        });
    }
}

#[cfg(not(target_os = "ios"))]
struct DirectServerContext {
    store: FileTrustedPeerStore,
    identity: DeviceIdentity,
    authentication_timeout: Duration,
    establish_deadline: Duration,
    endpoint_address: SocketAddr,
    pools: AuthenticationPools,
}

#[cfg(not(target_os = "ios"))]
fn establish_deadline(options: &QuicTransportOptions) -> Duration {
    options
        .connect_timeout
        .saturating_add(options.authentication_timeout)
        .saturating_add(QUIC_ESTABLISH_GRACE)
}

/// Runs the TLS handshake, device authentication and application setup of one
/// incoming connection and returns the stream with a peer label for logs.
///
/// The pending ticket and the authentication permit cover only this bounded
/// phase; they are released before the session runs, so sessions waiting for
/// a login cannot block new peers.
#[cfg(not(target_os = "ios"))]
async fn establish_incoming(
    context: &DirectServerContext,
    handshake: IncomingHandshake,
    incoming: Incoming,
    ticket: PendingTicket,
) -> ResultType<(Stream, String)> {
    let result = tokio::time::timeout(context.establish_deadline, async {
        let connection = handshake
            .complete(incoming)
            .await
            .map_err(|error| match error {
                QuicTransportError::CertificatePinMismatch
                | QuicTransportError::MissingPeerCertificate => {
                    anyhow!("rejected QUIC peer with an untrusted certificate")
                }
                error => anyhow!("rejected QUIC TLS handshake: {error}"),
            })?;
        let pin = peer_certificate_pin(&connection)
            .map_err(|error| anyhow!("rejected QUIC peer without a pinned certificate: {error}"))?;
        let peer = context
            .store
            .load_all()?
            .into_iter()
            .find(|peer| CertificatePin(peer.certificate_pin) == pin);
        let peer_label = peer
            .as_ref()
            .map(|peer| peer.peer_id.clone())
            .unwrap_or_else(|| "unpaired".to_owned());
        let _permit = context.pools.try_acquire(peer.is_some()).ok_or_else(|| {
            anyhow!("rejected QUIC peer {peer_label}: all authentication slots are busy")
        })?;
        let established = async {
            let authentication = if let Some(peer) = peer.as_ref() {
                AuthenticatedControlChannel::authenticate_server_discover_session(
                    connection,
                    &context.identity,
                    peer.identity_key,
                    context.authentication_timeout,
                )
                .await?
            } else {
                AuthenticatedControlChannel::authenticate_server_discover_peer(
                    connection,
                    &context.identity,
                    context.authentication_timeout,
                )
                .await?
            };
            QuicApplicationStream::establish(
                authentication,
                ApplicationQuicRole::Server,
                context.endpoint_address,
            )
            .await
        }
        .await
        .map_err(|error| anyhow!("peer={peer_label}: {error}"))?;
        Ok::<_, hbb_common::anyhow::Error>((Stream::from_quic(established), peer_label))
    })
    .await;
    drop(ticket);
    match result {
        Ok(result) => result,
        Err(_) => bail!(
            "QUIC connection was not established within {:?}",
            context.establish_deadline
        ),
    }
}

pub fn local_quic_certificate_der() -> ResultType<Vec<u8>> {
    Ok(local_tls_identity()?.certificate_bytes().to_vec())
}

pub fn has_paired_peer(peer_id: &str) -> ResultType<bool> {
    let config = NetworkTransportConfig::load()?;
    let store = FileTrustedPeerStore::new(&config.trusted_peer_store)?;
    Ok(store.load(peer_id)?.is_some())
}

pub fn paired_peers() -> ResultType<Vec<TrustedPeerRecord>> {
    let config = NetworkTransportConfig::load()?;
    let store = FileTrustedPeerStore::new(&config.trusted_peer_store)?;
    store.load_all().map_err(Into::into)
}

pub fn forget_paired_peer_ids(peer_ids: &[String]) -> ResultType<Vec<String>> {
    let config = NetworkTransportConfig::load()?;
    let mut store = FileTrustedPeerStore::new(&config.trusted_peer_store)?;
    let mut removed_ids = Vec::new();
    for peer_id in peer_ids {
        match store.remove(peer_id) {
            Ok(true) => {
                hbb_common::log::info!("Removed confirmed QUIC identity for peer {peer_id}");
                removed_ids.push(peer_id.clone());
            }
            Ok(false) => {}
            Err(PairingError::InvalidPeerId) => {}
            Err(error) => return Err(error.into()),
        }
    }
    Ok(removed_ids)
}

#[cfg(any(not(target_os = "ios"), test))]
pub fn remember_paired_peer(
    peer_id: &str,
    identity_key: [u8; 32],
    certificate_der: &[u8],
) -> ResultType<()> {
    remember_peer(peer_id, identity_key, certificate_der, false)
}

pub(crate) fn remember_authenticated_peer(
    peer_id: &str,
    identity_key: [u8; 32],
    certificate_der: &[u8],
) -> ResultType<()> {
    remember_peer(peer_id, identity_key, certificate_der, true)
}

fn remember_peer(
    peer_id: &str,
    identity_key: [u8; 32],
    certificate_der: &[u8],
    allow_replace: bool,
) -> ResultType<()> {
    if certificate_der.is_empty() {
        return Ok(());
    }
    let config = NetworkTransportConfig::load()?;
    let mut store = FileTrustedPeerStore::new(&config.trusted_peer_store)?;
    let candidate =
        PairingCandidate::new(peer_id.to_owned(), identity_key, certificate_der.to_vec())?;
    let record = candidate.clone().confirm(
        &candidate.fingerprint(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
            .min(u128::from(u64::MAX)) as u64,
    )?;
    match store.load(peer_id)? {
        Some(existing)
            if existing.identity_key == record.identity_key
                && existing.certificate_pin == record.certificate_pin
                && existing.certificate_der == record.certificate_der =>
        {
            Ok(())
        }
        Some(_) if allow_replace => {
            store.replace_authenticated(record)?;
            hbb_common::log::info!(
                "Replaced QUIC identity after authenticated pairing for peer {peer_id}"
            );
            Ok(())
        }
        Some(_) => bail!(
            "QUIC identity for peer {peer_id} changed; explicit trust replacement is required"
        ),
        None => {
            store.insert(record)?;
            hbb_common::log::info!("Stored confirmed QUIC identity for peer {peer_id}");
            Ok(())
        }
    }
}

fn local_tls_identity() -> ResultType<LocalTlsIdentity> {
    let directory = default_identity_directory(&Config::file());
    LocalTlsIdentity::load_or_create(directory).map_err(Into::into)
}

fn quic_options(config: &NetworkTransportConfig) -> QuicTransportOptions {
    QuicTransportOptions {
        connect_timeout: config.connect_timeout,
        authentication_timeout: config.connect_timeout,
        keepalive_interval: config.keepalive_interval,
        ..Default::default()
    }
}

fn compatible_client_bind(configured: IpAddr, peer: IpAddr) -> IpAddr {
    match (configured, peer) {
        (configured @ IpAddr::V4(_), IpAddr::V4(_)) => configured,
        (configured @ IpAddr::V6(_), IpAddr::V6(_)) => configured,
        (_, IpAddr::V4(_)) => IpAddr::V4(Ipv4Addr::UNSPECIFIED),
        (_, IpAddr::V6(_)) => IpAddr::V6(Ipv6Addr::UNSPECIFIED),
    }
}

async fn resolve_peer_address(
    address: &str,
    quic_port: u16,
    enable_ipv6: bool,
) -> ResultType<SocketAddr> {
    let mut addresses = tokio::net::lookup_host(address)
        .await
        .with_context(|| format!("could not resolve direct peer address {address}"))?;
    let mut resolved = addresses
        .find(|candidate| enable_ipv6 || candidate.is_ipv4())
        .ok_or_else(|| anyhow!("direct peer address {address} resolved to no endpoints"))?;
    resolved.set_port(quic_port);
    Ok(resolved)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn changed_tls_certificate_recovery_does_not_modify_saved_trust() {
        let directory =
            std::env::temp_dir().join(format!("rustadmin-quic-repair-{}", uuid::Uuid::new_v4()));
        let old_tls = LocalTlsIdentity::load_or_create(directory.join("old")).unwrap();
        let new_tls = LocalTlsIdentity::load_or_create(directory.join("new")).unwrap();
        let mut config =
            NetworkTransportConfig::from_values(&Default::default(), directory.join("trust"))
                .unwrap();
        let mut store = FileTrustedPeerStore::new(&config.trusted_peer_store).unwrap();
        let candidate = PairingCandidate::new(
            "repair-peer".to_owned(),
            [7; 32],
            old_tls.certificate_bytes().to_vec(),
        )
        .unwrap();
        let record = candidate
            .clone()
            .confirm(&candidate.fingerprint(), 1)
            .unwrap();
        store.insert(record.clone()).unwrap();
        let options = quic_options(&config);
        let server = QuicServerEndpoint::bind_provisional(
            "127.0.0.1:0".parse().unwrap(),
            new_tls.credentials().unwrap(),
            &options,
        )
        .unwrap();
        config.listen_port = server.local_addr().unwrap().port();
        let (pk, sk) = hbb_common::sodiumoxide::crypto::sign::gen_keypair();
        let identity = DeviceIdentity::from_bytes(&sk.0, &pk.0).unwrap();
        let (done_tx, done_rx) = tokio::sync::oneshot::channel::<()>();
        let (ready_tx, ready_rx) = tokio::sync::oneshot::channel::<()>();
        let task = tokio::spawn(async move {
            // The first client's saved certificate rejects this endpoint.
            let _ = server.accept().await;
            let connection = server.accept().await.unwrap();
            let auth = AuthenticatedControlChannel::authenticate_server_discover_peer(
                connection,
                &identity,
                options.authentication_timeout,
            )
            .await
            .unwrap();
            let _application = QuicApplicationStream::establish(
                auth,
                ApplicationQuicRole::Server,
                server.local_addr().unwrap(),
            )
            .await
            .unwrap();
            let _ = ready_tx.send(());
            let _ = done_rx.await;
        });
        let result =
            connect_pretrusted_inner("repair-peer", "127.0.0.1:21118", &config, false).await;
        let error = match result {
            Err(error) => error.into_error(),
            Ok(_) => panic!("changed TLS identity was accepted without recovery"),
        };
        assert!(
            error.downcast_ref::<QuicIdentityRepairRequired>().is_some(),
            "{error}"
        );
        let stream =
            match connect_pretrusted_inner("repair-peer", "127.0.0.1:21118", &config, true).await {
                Ok(stream) => stream,
                Err(error) => panic!("candidate connection failed: {}", error.into_error()),
            };
        assert!(stream.is_quic());
        assert_eq!(store.load("repair-peer").unwrap(), Some(record));
        ready_rx.await.unwrap();
        drop(stream);
        let _ = done_tx.send(());
        task.await.unwrap();
        std::fs::remove_dir_all(directory).unwrap();
    }

    struct DirectServerFixture {
        directory: std::path::PathBuf,
        config: NetworkTransportConfig,
        endpoint: QuicServerEndpoint,
        context: DirectServerContext,
        admission: admission::HandshakeAdmission,
    }

    fn direct_server_fixture(values: &[(&str, &str)]) -> DirectServerFixture {
        let directory =
            std::env::temp_dir().join(format!("rustadmin-quic-admission-{}", uuid::Uuid::new_v4()));
        let values = values
            .iter()
            .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
            .collect();
        let mut config =
            NetworkTransportConfig::from_values(&values, directory.join("viewer-trust")).unwrap();
        let options = quic_options(&config);
        let tls = LocalTlsIdentity::load_or_create(directory.join("host-tls")).unwrap();
        let endpoint = QuicServerEndpoint::bind_provisional(
            "127.0.0.1:0".parse().unwrap(),
            tls.credentials().unwrap(),
            &options,
        )
        .unwrap();
        config.listen_port = endpoint.local_addr().unwrap().port();
        let (pk, sk) = hbb_common::sodiumoxide::crypto::sign::gen_keypair();
        let context = DirectServerContext {
            store: FileTrustedPeerStore::new(directory.join("host-trust")).unwrap(),
            identity: DeviceIdentity::from_bytes(&sk.0, &pk.0).unwrap(),
            authentication_timeout: options.authentication_timeout,
            establish_deadline: establish_deadline(&options),
            endpoint_address: endpoint.local_addr().unwrap(),
            pools: AuthenticationPools::default(),
        };
        DirectServerFixture {
            directory,
            config,
            endpoint,
            context,
            admission: Default::default(),
        }
    }

    async fn admit_next(fixture: &DirectServerFixture) -> (Incoming, PendingTicket) {
        let incoming = fixture.endpoint.accept_incoming().await.unwrap();
        match fixture.admission.admit(
            incoming.remote_address().ip(),
            incoming.remote_address_validated(),
            incoming.may_retry(),
        ) {
            Admission::Admitted(ticket) => (incoming, ticket),
            Admission::Retry | Admission::Refuse => panic!("first connection was not admitted"),
        }
    }

    #[tokio::test]
    async fn established_first_contacts_release_their_slots_while_sessions_stay_open() {
        // More idle sessions than first-contact slots: before, each session
        // kept its slot until it ended, so the last one was refused.
        let sessions = admission::MAX_FIRST_CONTACT_AUTHENTICATIONS + 1;
        let fixture = Arc::new(direct_server_fixture(&[]));
        let host = {
            let fixture = fixture.clone();
            tokio::spawn(async move {
                let mut streams = Vec::new();
                for _ in 0..sessions {
                    let (incoming, ticket) = admit_next(&fixture).await;
                    assert_eq!(fixture.admission.pending(), 1);
                    let (stream, peer_label) = match establish_incoming(
                        &fixture.context,
                        fixture.endpoint.incoming_handshake(),
                        incoming,
                        ticket,
                    )
                    .await
                    {
                        Ok(established) => established,
                        Err(error) => panic!("first contact failed: {error}"),
                    };
                    assert!(stream.is_quic());
                    assert_eq!(peer_label, "unpaired");
                    assert_eq!(fixture.admission.pending(), 0);
                    assert_eq!(
                        fixture.context.pools.first_contact.available_permits(),
                        admission::MAX_FIRST_CONTACT_AUTHENTICATIONS
                    );
                    streams.push(stream);
                }
                streams
            })
        };
        let mut viewer_streams = Vec::new();
        for _ in 0..sessions {
            match connect_pretrusted_inner(
                "first-contact-peer",
                "127.0.0.1:21118",
                &fixture.config,
                true,
            )
            .await
            {
                Ok(stream) => viewer_streams.push(stream),
                Err(error) => panic!("viewer connection failed: {}", error.into_error()),
            }
        }
        let host_streams = host.await.unwrap();
        assert_eq!(host_streams.len(), sessions);
        drop((host_streams, viewer_streams));
        std::fs::remove_dir_all(&fixture.directory).unwrap();
    }

    #[tokio::test]
    async fn a_failed_authentication_releases_the_pending_slot_and_permit() {
        let fixture = Arc::new(direct_server_fixture(&[(
            hbb_common::config::keys::OPTION_QUIC_CONNECT_TIMEOUT_MS,
            "500",
        )]));
        let host = {
            let fixture = fixture.clone();
            tokio::spawn(async move {
                let (incoming, ticket) = admit_next(&fixture).await;
                let result = establish_incoming(
                    &fixture.context,
                    fixture.endpoint.incoming_handshake(),
                    incoming,
                    ticket,
                )
                .await;
                assert!(
                    result.is_err(),
                    "a peer that never authenticates was accepted"
                );
                assert_eq!(fixture.admission.pending(), 0);
                assert_eq!(
                    fixture.context.pools.first_contact.available_permits(),
                    admission::MAX_FIRST_CONTACT_AUTHENTICATIONS
                );
            })
        };
        // Completes TLS but never sends the device authentication.
        let viewer_tls =
            LocalTlsIdentity::load_or_create(fixture.directory.join("viewer-tls")).unwrap();
        let viewer = QuicClientEndpoint::bind_provisional(
            "127.0.0.1:0".parse().unwrap(),
            viewer_tls.credentials().unwrap(),
            &quic_options(&fixture.config),
        )
        .unwrap();
        let _connection = viewer
            .connect(fixture.endpoint.local_addr().unwrap())
            .await
            .unwrap();
        host.await.unwrap();
        std::fs::remove_dir_all(&fixture.directory).unwrap();
    }

    #[test]
    fn client_bind_address_matches_peer_family() {
        assert_eq!(
            compatible_client_bind(
                IpAddr::V4(Ipv4Addr::new(10, 1, 2, 3)),
                IpAddr::V4(Ipv4Addr::LOCALHOST)
            ),
            IpAddr::V4(Ipv4Addr::new(10, 1, 2, 3))
        );
        assert_eq!(
            compatible_client_bind(
                IpAddr::V4(Ipv4Addr::UNSPECIFIED),
                IpAddr::V6(Ipv6Addr::LOCALHOST)
            ),
            IpAddr::V6(Ipv6Addr::UNSPECIFIED)
        );
    }
}
