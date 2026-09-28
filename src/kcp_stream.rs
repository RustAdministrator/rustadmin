use hbb_common::{
    anyhow,
    bytes::{Bytes, BytesMut},
    config, log,
    tcp::{DynTcpStream, FramedStream},
    tokio::{self, net::UdpSocket, sync::mpsc, sync::oneshot},
    ResultType, Stream,
};
use kcp_sys::{
    endpoint::KcpEndpoint,
    packet_def::{KcpPacket, KcpPacketHeader},
    stream,
};
use std::{net::SocketAddr, sync::Arc};

pub struct KcpStream {
    _endpoint: KcpEndpoint,
    stop_sender: Option<oneshot::Sender<()>>,
}

impl KcpStream {
    fn create_framed(stream: stream::KcpStream, local_addr: Option<SocketAddr>) -> Stream {
        Stream::Tcp(FramedStream::from_dyn(
            DynTcpStream(Box::new(stream)),
            local_addr.unwrap_or(config::Config::get_any_listen_addr(true)),
        ))
    }

    pub async fn accept(
        udp_socket: Arc<UdpSocket>,
        timeout: std::time::Duration,
        init_packet: Option<BytesMut>,
    ) -> ResultType<(Self, Stream)> {
        let mut endpoint = KcpEndpoint::new();
        endpoint.run().await;

        let (input, output) = (
            endpoint.input_sender(),
            endpoint
                .output_receiver()
                .ok_or_else(|| anyhow::anyhow!("Failed to get output receiver"))?,
        );
        let (stop_sender, stop_receiver) = oneshot::channel();
        if let Some(packet) = init_packet {
            if packet.len() >= std::mem::size_of::<KcpPacketHeader>() {
                input.send(packet.into()).await?;
            }
        }
        Self::kcp_io(udp_socket.clone(), input, output, stop_receiver).await;

        let conn_id = tokio::time::timeout(timeout, endpoint.accept()).await??;
        if let Some(stream) = stream::KcpStream::new(&endpoint, conn_id) {
            Ok((
                Self {
                    _endpoint: endpoint,
                    stop_sender: Some(stop_sender),
                },
                Self::create_framed(stream, udp_socket.local_addr().ok()),
            ))
        } else {
            Err(anyhow::anyhow!("Failed to create KcpStream"))
        }
    }

    pub async fn connect(
        udp_socket: Arc<UdpSocket>,
        timeout: std::time::Duration,
    ) -> ResultType<(Self, Stream)> {
        let mut endpoint = KcpEndpoint::new();
        endpoint.run().await;

        let (input, output) = (
            endpoint.input_sender(),
            endpoint
                .output_receiver()
                .ok_or_else(|| anyhow::anyhow!("Failed to get output receiver"))?,
        );
        let (stop_sender, stop_receiver) = oneshot::channel();
        Self::kcp_io(udp_socket.clone(), input, output, stop_receiver).await;

        let conn_id = endpoint.connect(timeout, 0, 0, Bytes::new()).await?;
        if let Some(stream) = stream::KcpStream::new(&endpoint, conn_id) {
            Ok((
                Self {
                    _endpoint: endpoint,
                    stop_sender: Some(stop_sender),
                },
                Self::create_framed(stream, udp_socket.local_addr().ok()),
            ))
        } else {
            Err(anyhow::anyhow!("Failed to create KcpStream"))
        }
    }

    async fn kcp_io(
        udp_socket: Arc<UdpSocket>,
        input: mpsc::Sender<KcpPacket>,
        mut output: mpsc::Receiver<KcpPacket>,
        mut stop_receiver: oneshot::Receiver<()>,
    ) {
        let udp = udp_socket.clone();
        tokio::spawn(async move {
            let mut buf = vec![0; 1500];
            loop {
                tokio::select! {
                    _ = &mut stop_receiver => {
                        log::debug!("KCP io loop received stop signal");
                        break;
                    }
                    Some(data) = output.recv() => {
                        if let Err(e) = udp.send(&data.inner()).await {
                            log::debug!("KCP send error: {:?}", e);
                            break;
                        }
                    }
                    result = udp.recv_from(&mut buf) => {
                        match result {
                            Ok((size, _)) => {
                                if size < std::mem::size_of::<KcpPacketHeader>() {
                                    continue;
                                }
                                input
                                    .send(BytesMut::from(&buf[..size]).into())
                                    .await.ok();
                            }
                            Err(e) => {
                                log::debug!("KCP recv_from error: {:?}", e);
                                break;
                            }
                        }
                    }
                    else => {
                        log::debug!("KCP endpoint input closed");
                        break;
                    }
                }
            }
        });
    }
}

impl Drop for KcpStream {
    fn drop(&mut self) {
        if let Some(sender) = self.stop_sender.take() {
            let _ = sender.send(());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use hbb_common::{
        sodiumoxide::crypto::secretbox,
        tcp::{NonceMode, SessionRole},
    };
    use std::time::Duration;

    #[tokio::test]
    async fn kcp_streams_exchange_frames_in_both_nonce_modes() {
        let key = secretbox::Key([29; secretbox::KEYBYTES]);
        let timeout = Duration::from_secs(5);
        for (viewer_mode, host_mode) in [
            (NonceMode::Legacy, NonceMode::Legacy),
            (
                NonceMode::Directional(SessionRole::Viewer),
                NonceMode::Directional(SessionRole::Host),
            ),
        ] {
            let host_socket = Arc::new(UdpSocket::bind("127.0.0.1:0").await.unwrap());
            let viewer_socket = Arc::new(UdpSocket::bind("127.0.0.1:0").await.unwrap());
            host_socket
                .connect(viewer_socket.local_addr().unwrap())
                .await
                .unwrap();
            viewer_socket
                .connect(host_socket.local_addr().unwrap())
                .await
                .unwrap();
            let (host, viewer) = tokio::join!(
                KcpStream::accept(host_socket, timeout, None),
                KcpStream::connect(viewer_socket, timeout)
            );
            let (_host_kcp, mut host) = host.unwrap();
            let (_viewer_kcp, mut viewer) = viewer.unwrap();
            viewer.set_key_with_mode(key.clone(), viewer_mode);
            host.set_key_with_mode(key.clone(), host_mode);
            let exchange = async {
                viewer.send_raw(b"viewer-1".to_vec()).await.unwrap();
                assert_eq!(&host.next().await.unwrap().unwrap()[..], b"viewer-1");
                host.send_raw(b"host-1".to_vec()).await.unwrap();
                assert_eq!(&viewer.next().await.unwrap().unwrap()[..], b"host-1");
            };
            tokio::time::timeout(timeout, exchange).await.unwrap();
        }
    }
}
