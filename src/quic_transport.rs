#[cfg(not(target_os = "ios"))]
use crate::server::ServerPtr;
#[cfg(not(target_os = "ios"))]
use hbb_common::config::option2bool;
#[cfg(not(target_os = "ios"))]
use hbb_common::transport::quic::{peer_certificate_pin, CertificatePin, QuicServerEndpoint};
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

pub async fn connect_pretrusted(
    peer_id: &str,
    connect_address: &str,
) -> ResultType<Option<Stream>> {
    let config = NetworkTransportConfig::load()?;
    if config.mode == RemoteTransportMode::Tcp {
        return Ok(None);
    }
    match connect_pretrusted_inner(peer_id, connect_address, &config).await {
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
) -> Result<Stream, DirectQuicConnectError> {
    let store = FileTrustedPeerStore::new(&config.trusted_peer_store)
        .map_err(DirectQuicConnectError::fatal)?;
    let trusted = store.load(peer_id).map_err(DirectQuicConnectError::fatal)?;
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
        let unavailable = matches!(
            error,
            QuicTransportError::Timeout(_)
                | QuicTransportError::EndpointClosed
                | QuicTransportError::Unreachable(_)
                | QuicTransportError::UdpBind(_)
        );
        let error = anyhow!(error).context(format!(
            "QUIC UDP connection to {peer_address} failed; check the routed path and UDP port {}",
            peer_address.port()
        ));
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
    .map_err(DirectQuicConnectError::fatal)?;
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
    let endpoint_address = endpoint.local_addr()?;
    let identity = Arc::new(DeviceIdentity::from_config()?);
    let first_contact_slots = Arc::new(tokio::sync::Semaphore::new(8));
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
        let connection = match endpoint.accept().await {
            Ok(connection) => connection,
            Err(QuicTransportError::Timeout(_)) => continue,
            Err(QuicTransportError::Handshake(error)) => {
                hbb_common::log::warn!("Rejected QUIC TLS handshake: {error}");
                continue;
            }
            Err(QuicTransportError::CertificatePinMismatch)
            | Err(QuicTransportError::MissingPeerCertificate) => {
                hbb_common::log::warn!("Rejected QUIC peer with an untrusted certificate");
                continue;
            }
            Err(error) => return Err(error.into()),
        };
        let pin = match peer_certificate_pin(&connection) {
            Ok(pin) => pin,
            Err(error) => {
                hbb_common::log::warn!("Rejected QUIC peer without a pinned certificate: {error}");
                continue;
            }
        };
        let peer = store
            .load_all()?
            .iter()
            .find(|peer| CertificatePin(peer.certificate_pin) == pin)
            .cloned();
        let first_contact_permit = if peer.is_none() {
            match first_contact_slots.clone().try_acquire_owned() {
                Ok(permit) => Some(permit),
                Err(_) => {
                    hbb_common::log::warn!(
                        "Rejected provisional QUIC peer because all first-contact slots are busy"
                    );
                    continue;
                }
            }
        } else {
            None
        };
        let remote_address = connection.remote_address();
        let server = server.clone();
        let identity = identity.clone();
        let authentication_timeout = options.authentication_timeout;
        tokio::spawn(async move {
            let _first_contact_permit = first_contact_permit;
            let peer_label = peer
                .as_ref()
                .map(|peer| peer.peer_id.as_str())
                .unwrap_or("unpaired");
            let result = async {
                let authentication = if let Some(peer) = peer.as_ref() {
                    AuthenticatedControlChannel::authenticate_server_discover_session(
                        connection,
                        identity.as_ref(),
                        peer.identity_key,
                        authentication_timeout,
                    )
                    .await?
                } else {
                    AuthenticatedControlChannel::authenticate_server_discover_peer(
                        connection,
                        identity.as_ref(),
                        authentication_timeout,
                    )
                    .await?
                };
                let application = QuicApplicationStream::establish(
                    authentication,
                    ApplicationQuicRole::Server,
                    endpoint_address,
                )
                .await?;
                crate::server::create_direct_tcp_connection(
                    server,
                    Stream::from_quic(application),
                    remote_address,
                    None,
                )
                .await
            }
            .await;
            if let Err(error) = result {
                hbb_common::log::warn!(
                    "QUIC direct session failed: peer={}, address={}, error={}",
                    peer_label,
                    remote_address,
                    error
                );
            }
        });
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

pub fn remember_paired_peer(
    peer_id: &str,
    identity_key: [u8; 32],
    certificate_der: &[u8],
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
