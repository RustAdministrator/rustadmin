use hbb_common::{
    async_recursion::async_recursion,
    config::{Config, Socks5Server},
    log::{self, info},
    proxy::{Proxy, ProxyScheme},
    tls::{
        get_cached_tls_accept_invalid_cert, get_cached_tls_type, is_plain, upsert_tls_cache,
        TlsType,
    },
};
use reqwest::{blocking::Client as SyncClient, Client as AsyncClient};

/// The proxy of a client that must not send anything: port 0 of the loopback address, which
/// nothing can listen on. A connection to it fails at once and nothing leaves the machine.
const UNUSABLE_PROXY: &str = "http://127.0.0.1:0";

/// Whether an HTTP request may go directly to the server when a proxy is configured but cannot be
/// used. Before, it always did, around the proxy the user had asked for.
fn direct_fallback_when_proxy_unusable() -> bool {
    Config::get_option(hbb_common::config::keys::OPTION_HTTP_PROXY_FAIL_CLOSED) == "N"
}

/// The client for a configured proxy that cannot be used: one whose every request fails, or,
/// with `http-proxy-fail-closed = N`, a client without a proxy as before.
macro_rules! unusable_proxy_client {
    ($Client: ty) => {{
        if direct_fallback_when_proxy_unusable() {
            <$Client>::new()
        } else {
            log::warn!(
                "A proxy is configured but cannot be used: HTTP requests fail instead of going directly to the server"
            );
            match reqwest::Proxy::all(UNUSABLE_PROXY) {
                Ok(proxy) => <$Client>::builder()
                    .no_proxy()
                    .proxy(proxy)
                    .build()
                    .unwrap_or_else(|e| {
                        log::error!("Failed to create the client that refuses requests: {}", e);
                        <$Client>::new()
                    }),
                Err(e) => {
                    log::error!("Failed to set up the proxy that refuses requests: {}", e);
                    <$Client>::new()
                }
            }
        }
    }};
}

macro_rules! configure_http_client {
    ($builder:expr, $tls_type:expr, $danger_accept_invalid_cert:expr, $Client: ty) => {{
        // https://github.com/rustdesk/rustdesk/issues/11569
        // https://docs.rs/reqwest/latest/reqwest/struct.ClientBuilder.html#method.no_proxy
        let mut builder = $builder.no_proxy();

        match $tls_type {
            TlsType::Plain => {}
            TlsType::NativeTls => {
                builder = builder.use_native_tls();
                if $danger_accept_invalid_cert {
                    builder = builder.danger_accept_invalid_certs(true);
                }
            }
            TlsType::Rustls => {
                #[cfg(any(target_os = "android", target_os = "ios"))]
                match hbb_common::verifier::client_config($danger_accept_invalid_cert) {
                    Ok(client_config) => {
                        builder = builder.use_preconfigured_tls(client_config);
                    }
                    Err(e) => {
                        hbb_common::log::error!("Failed to get client config: {}", e);
                    }
                }
                #[cfg(not(any(target_os = "android", target_os = "ios")))]
                {
                    builder = builder.use_rustls_tls();
                    if $danger_accept_invalid_cert {
                        builder = builder.danger_accept_invalid_certs(true);
                    }
                }
            }
        }

        let client = if let Some(conf) = Config::get_socks() {
            let proxy_result = Proxy::from_conf(&conf, None);

            match proxy_result {
                Ok(proxy) => {
                    let proxy_setup = match &proxy.intercept {
                        ProxyScheme::Http { host, .. } => {
                            reqwest::Proxy::all(format!("http://{}", host))
                        }
                        ProxyScheme::Https { host, .. } => {
                            reqwest::Proxy::all(format!("https://{}", host))
                        }
                        ProxyScheme::Socks5 { addr, .. } => {
                            reqwest::Proxy::all(&format!("socks5://{}", addr))
                        }
                    };

                    match proxy_setup {
                        Ok(mut p) => {
                            if let Some(auth) = proxy.intercept.maybe_auth() {
                                if !auth.username().is_empty() && !auth.password().is_empty() {
                                    p = p.basic_auth(auth.username(), auth.password());
                                }
                            }
                            builder = builder.proxy(p);
                            builder.build().unwrap_or_else(|e| {
                                info!("Failed to create a proxied client: {}", e);
                                unusable_proxy_client!($Client)
                            })
                        }
                        Err(e) => {
                            info!("Failed to set up proxy: {}", e);
                            unusable_proxy_client!($Client)
                        }
                    }
                }
                Err(e) => {
                    info!("Failed to configure proxy: {}", e);
                    unusable_proxy_client!($Client)
                }
            }
        } else {
            builder.build().unwrap_or_else(|e| {
                info!("Failed to create a client: {}", e);
                <$Client>::new()
            })
        };

        client
    }};
}

pub fn create_http_client(tls_type: TlsType, danger_accept_invalid_cert: bool) -> SyncClient {
    let builder = SyncClient::builder();
    configure_http_client!(builder, tls_type, danger_accept_invalid_cert, SyncClient)
}

pub fn create_http_client_async(
    tls_type: TlsType,
    danger_accept_invalid_cert: bool,
) -> AsyncClient {
    let builder = AsyncClient::builder();
    configure_http_client!(builder, tls_type, danger_accept_invalid_cert, AsyncClient)
}

pub fn get_url_for_tls<'a>(url: &'a str, proxy_conf: &'a Option<Socks5Server>) -> &'a str {
    if is_plain(url) {
        if let Some(conf) = proxy_conf {
            if conf.proxy.starts_with("https://") {
                return &conf.proxy;
            }
        }
    }
    url
}

pub fn create_http_client_with_url(url: &str) -> SyncClient {
    let proxy_conf = Config::get_socks();
    let tls_url = get_url_for_tls(url, &proxy_conf);
    let tls_type = get_cached_tls_type(tls_url);
    let is_tls_type_cached = tls_type.is_some();
    let tls_type = tls_type.unwrap_or(TlsType::Rustls);
    let tls_danger_accept_invalid_cert = get_cached_tls_accept_invalid_cert(tls_url);
    create_http_client_with_url_(
        url,
        tls_url,
        tls_type,
        is_tls_type_cached,
        tls_danger_accept_invalid_cert,
        tls_danger_accept_invalid_cert,
    )
}

fn create_http_client_with_url_(
    url: &str,
    tls_url: &str,
    tls_type: TlsType,
    is_tls_type_cached: bool,
    danger_accept_invalid_cert: Option<bool>,
    original_danger_accept_invalid_cert: Option<bool>,
) -> SyncClient {
    let mut client = create_http_client(tls_type, danger_accept_invalid_cert.unwrap_or(false));
    if is_tls_type_cached && original_danger_accept_invalid_cert.is_some() {
        return client;
    }
    if let Err(e) = client.head(url).send() {
        if e.is_request() {
            match (tls_type, is_tls_type_cached, danger_accept_invalid_cert) {
                (TlsType::Rustls, _, None) => {
                    log::warn!(
                        "Failed to connect to server {} with rustls-tls: {:?}, trying accept invalid cert",
                        tls_url,
                        e
                    );
                    client = create_http_client_with_url_(
                        url,
                        tls_url,
                        tls_type,
                        is_tls_type_cached,
                        Some(true),
                        original_danger_accept_invalid_cert,
                    );
                }
                (TlsType::Rustls, false, Some(_)) => {
                    log::warn!(
                        "Failed to connect to server {} with rustls-tls: {:?}, trying native-tls",
                        tls_url,
                        e
                    );
                    client = create_http_client_with_url_(
                        url,
                        tls_url,
                        TlsType::NativeTls,
                        is_tls_type_cached,
                        original_danger_accept_invalid_cert,
                        original_danger_accept_invalid_cert,
                    );
                }
                (TlsType::NativeTls, _, None) => {
                    log::warn!(
                        "Failed to connect to server {} with native-tls: {:?}, trying accept invalid cert",
                        tls_url,
                        e
                    );
                    client = create_http_client_with_url_(
                        url,
                        tls_url,
                        tls_type,
                        is_tls_type_cached,
                        Some(true),
                        original_danger_accept_invalid_cert,
                    );
                }
                _ => {
                    log::error!(
                        "Failed to connect to server {} with {:?}, err: {:?}.",
                        tls_url,
                        tls_type,
                        e
                    );
                }
            }
        } else {
            log::warn!(
                "Failed to connect to server {} with {:?}, err: {}.",
                tls_url,
                tls_type,
                e
            );
        }
    } else {
        log::info!(
            "Successfully connected to server {} with {:?}",
            tls_url,
            tls_type
        );
        upsert_tls_cache(
            tls_url,
            tls_type,
            danger_accept_invalid_cert.unwrap_or(false),
        );
    }
    client
}

pub async fn create_http_client_async_with_url(url: &str) -> AsyncClient {
    let proxy_conf = Config::get_socks();
    let tls_url = get_url_for_tls(url, &proxy_conf);
    let tls_type = get_cached_tls_type(tls_url);
    let is_tls_type_cached = tls_type.is_some();
    let tls_type = tls_type.unwrap_or(TlsType::Rustls);
    let danger_accept_invalid_cert = get_cached_tls_accept_invalid_cert(tls_url);
    create_http_client_async_with_url_(
        url,
        tls_url,
        tls_type,
        is_tls_type_cached,
        danger_accept_invalid_cert,
        danger_accept_invalid_cert,
    )
    .await
}

#[async_recursion]
async fn create_http_client_async_with_url_(
    url: &str,
    tls_url: &str,
    tls_type: TlsType,
    is_tls_type_cached: bool,
    danger_accept_invalid_cert: Option<bool>,
    original_danger_accept_invalid_cert: Option<bool>,
) -> AsyncClient {
    let mut client =
        create_http_client_async(tls_type, danger_accept_invalid_cert.unwrap_or(false));
    if is_tls_type_cached && original_danger_accept_invalid_cert.is_some() {
        return client;
    }
    if let Err(e) = client.head(url).send().await {
        match (tls_type, is_tls_type_cached, danger_accept_invalid_cert) {
            (TlsType::Rustls, _, None) => {
                log::warn!(
                    "Failed to connect to server {} with rustls-tls: {:?}, trying accept invalid cert",
                    tls_url,
                    e
                );
                client = create_http_client_async_with_url_(
                    url,
                    tls_url,
                    tls_type,
                    is_tls_type_cached,
                    Some(true),
                    original_danger_accept_invalid_cert,
                )
                .await;
            }
            (TlsType::Rustls, false, Some(_)) => {
                log::warn!(
                    "Failed to connect to server {} with rustls-tls: {:?}, trying native-tls",
                    tls_url,
                    e
                );
                client = create_http_client_async_with_url_(
                    url,
                    tls_url,
                    TlsType::NativeTls,
                    is_tls_type_cached,
                    original_danger_accept_invalid_cert,
                    original_danger_accept_invalid_cert,
                )
                .await;
            }
            (TlsType::NativeTls, _, None) => {
                log::warn!(
                    "Failed to connect to server {} with native-tls: {:?}, trying accept invalid cert",
                    tls_url,
                    e
                );
                client = create_http_client_async_with_url_(
                    url,
                    tls_url,
                    tls_type,
                    is_tls_type_cached,
                    Some(true),
                    original_danger_accept_invalid_cert,
                )
                .await;
            }
            _ => {
                log::error!(
                    "Failed to connect to server {} with {:?}, err: {:?}.",
                    tls_url,
                    tls_type,
                    e
                );
            }
        }
    } else {
        log::info!(
            "Successfully connected to server {} with {:?}",
            tls_url,
            tls_type
        );
        upsert_tls_cache(
            tls_url,
            tls_type,
            danger_accept_invalid_cert.unwrap_or(false),
        );
    }
    client
}

#[cfg(test)]
mod tests {
    /// The two tests change the same process-wide settings.
    static SETTINGS: std::sync::Mutex<()> = std::sync::Mutex::new(());
    /// A local HTTP server that answers every request with 200, for `requests` requests.
    fn local_http_server(requests: usize) -> u16 {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for stream in listener.incoming().take(requests) {
                let Ok(mut stream) = stream else { continue };
                let mut request = [0u8; 1024];
                let _ = stream.read(&mut request);
                let _ = stream.write_all(
                    b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
                );
            }
        });
        port
    }

    /// A proxy is configured but cannot be used (here: a scheme the proxy code does not know).
    /// The HTTP client then went straight to the server, around the proxy the user asked for.
    #[test]
    fn http_request_does_not_go_around_a_configured_proxy_that_cannot_be_used() {
        use hbb_common::config::{keys, OVERWRITE_SETTINGS};
        let _settings = SETTINGS
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let port = local_http_server(1);
        let previous = OVERWRITE_SETTINGS.write().unwrap().insert(
            keys::OPTION_PROXY_URL.to_owned(),
            "ftp://proxy.invalid:21".to_owned(),
        );
        let client = super::create_http_client(hbb_common::tls::TlsType::Plain, false);
        let response = client
            .get(format!("http://127.0.0.1:{}/", port))
            .timeout(std::time::Duration::from_secs(5))
            .send();
        {
            let mut settings = OVERWRITE_SETTINGS.write().unwrap();
            match previous {
                Some(previous) => settings.insert(keys::OPTION_PROXY_URL.to_owned(), previous),
                None => settings.remove(keys::OPTION_PROXY_URL),
            };
        }
        assert!(
            response.is_err(),
            "the request went around the configured proxy: {:?}",
            response.map(|response| response.status())
        );
    }

    /// With `http-proxy-fail-closed = N` the request goes directly to the server, as before.
    #[test]
    fn http_request_goes_directly_with_the_kill_switch() {
        use hbb_common::config::{keys, Config, OVERWRITE_SETTINGS};
        let _settings = SETTINGS
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let port = local_http_server(1);
        let previous_proxy = OVERWRITE_SETTINGS.write().unwrap().insert(
            keys::OPTION_PROXY_URL.to_owned(),
            "ftp://proxy.invalid:21".to_owned(),
        );
        let previous_switch = OVERWRITE_SETTINGS.write().unwrap().insert(
            keys::OPTION_HTTP_PROXY_FAIL_CLOSED.to_owned(),
            "N".to_owned(),
        );
        assert_eq!(Config::get_option(keys::OPTION_HTTP_PROXY_FAIL_CLOSED), "N");
        let client = super::create_http_client(hbb_common::tls::TlsType::Plain, false);
        let response = client
            .get(format!("http://127.0.0.1:{}/", port))
            .timeout(std::time::Duration::from_secs(5))
            .send();
        {
            let mut settings = OVERWRITE_SETTINGS.write().unwrap();
            for (key, previous) in [
                (keys::OPTION_PROXY_URL, previous_proxy),
                (keys::OPTION_HTTP_PROXY_FAIL_CLOSED, previous_switch),
            ] {
                match previous {
                    Some(previous) => settings.insert(key.to_owned(), previous),
                    None => settings.remove(key),
                };
            }
        }
        assert_eq!(
            response.map(|response| response.status().as_u16()).ok(),
            Some(200)
        );
    }
}
