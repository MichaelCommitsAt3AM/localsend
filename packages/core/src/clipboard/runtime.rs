use super::{
    engine::{ClipboardEvent, Directions, Engine, EngineError},
    secure_channel::{self, ALPN},
};
use crate::crypto::cert::fingerprint_from_cert_der;
use rustls::pki_types::{pem::PemObject, CertificateDer, ServerName};
use std::{
    collections::BTreeSet,
    net::SocketAddr,
    sync::{Arc, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::{watch, Semaphore},
    task::{JoinHandle, JoinSet},
    time::timeout,
};
use tokio_rustls::{TlsAcceptor, TlsConnector};
use tokio_util::sync::CancellationToken;

#[derive(Clone)]
pub struct PeerConfig {
    pub identity: String,
    pub address: SocketAddr,
    pub send: bool,
    pub receive: bool,
}

#[derive(Clone, Default)]
pub struct Update {
    pub revision: u64,
    pub connected: usize,
    pub connected_peers: Vec<String>,
    pub text: Option<String>,
    pub image_png: Option<String>,
    pub origin: Option<String>,
    pub error: Option<String>,
}

struct State {
    engine: Engine,
    active: BTreeSet<String>,
    connected: BTreeSet<String>,
}
struct Shared {
    state: Mutex<State>,
    updates: watch::Sender<Update>,
    changed: watch::Sender<u64>,
    cancel: CancellationToken,
}

/// One bounded latest-value owner shared by all direct peer connections.
/// Secrets are supplied from platform secure storage, never ordinary settings.
pub struct Runtime {
    shared: Arc<Shared>,
    worker: tokio::sync::Mutex<Option<JoinHandle<()>>>,
    pub port: u16,
}

fn wall_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u64::MAX as u128) as u64
}

impl Shared {
    fn update(&self, text: Option<String>, error: Option<String>) {
        if let Ok(state) = self.state.lock() {
            self.publish(state.connected.iter().cloned().collect(), text, error);
        }
    }
    fn publish(&self, connected: Vec<String>, text: Option<String>, error: Option<String>) {
        self.publish_content(connected, text, None, None, error);
    }
    fn publish_content(
        &self,
        connected: Vec<String>,
        text: Option<String>,
        image: Option<String>,
        origin: Option<String>,
        error: Option<String>,
    ) {
        self.updates.send_modify(|update| {
            update.revision = update.revision.wrapping_add(1);
            update.connected = connected.len();
            update.connected_peers = connected;
            // Preserve an unconsumed write across status-only updates.
            if text.is_some() || image.is_some() {
                update.text = text;
                update.image_png = image;
                update.origin = origin;
            }
            update.error = error;
        });
    }
    fn outgoing(&self, peer: &str) -> Option<ClipboardEvent> {
        self.state
            .lock()
            .ok()?
            .engine
            .outbound(peer, Instant::now())
    }
    fn receive(&self, peer: &str, event: ClipboardEvent) -> anyhow::Result<()> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| anyhow::anyhow!("Clipboard state unavailable"))?;
        let own_origin = event.origin == peer;
        let accepted = match state.engine.receive(peer, event, wall_ms(), Instant::now()) {
            Ok(accepted) => accepted,
            // Receive-off must not disable the independently allowed send direction.
            Err(EngineError::Unauthorized) if own_origin => false,
            Err(error) => return Err(error.into()),
        };
        if accepted {
            let text = state.engine.latest_text(Instant::now()).map(str::to_owned);
            let image = state.engine.latest_image(Instant::now()).map(str::to_owned);
            // Engine mutation and latest-write publication share one lock. A later
            // capture cannot be overwritten by an earlier receive publication.
            self.publish_content(
                state.connected.iter().cloned().collect(),
                text,
                image,
                Some(peer.to_owned()),
                None,
            );
        }
        Ok(())
    }
}

impl Runtime {
    pub fn should_apply_image(&self, image: &str) -> bool {
        !self.shared.cancel.is_cancelled()
            && self.shared.state.lock().ok().is_some_and(|mut state| {
                state
                    .engine
                    .latest_image(Instant::now())
                    .is_some_and(|current| current == image)
            })
    }
    pub fn should_apply(&self, text: &str) -> bool {
        if self.shared.cancel.is_cancelled() {
            return false;
        }
        self.shared.state.lock().ok().is_some_and(|mut state| {
            state
                .engine
                .latest_text(Instant::now())
                .is_some_and(|current| current == text)
        })
    }
    pub async fn start(
        certificate: String,
        private_key: String,
        bind: SocketAddr,
        peers: Vec<PeerConfig>,
    ) -> anyhow::Result<Self> {
        Self::start_with_images(certificate, private_key, bind, peers, false).await
    }
    pub async fn start_with_images(
        certificate: String,
        private_key: String,
        bind: SocketAddr,
        peers: Vec<PeerConfig>,
        images: bool,
    ) -> anyhow::Result<Self> {
        anyhow::ensure!(
            !peers.is_empty() && peers.len() <= super::engine::MAX_PEERS,
            "Pair 1..8 clipboard peers first"
        );
        let der = CertificateDer::from_pem_slice(certificate.as_bytes())?;
        let identity = fingerprint_from_cert_der(der.as_ref());
        let mut engine = Engine::new(identity.clone())?;
        engine.set_images(images);
        let mut pins = BTreeSet::new();
        for peer in &peers {
            anyhow::ensure!(
                pins.insert(peer.identity.clone()),
                "Duplicate clipboard peer"
            );
            anyhow::ensure!(
                peer.address.port() != 0
                    && !peer.address.ip().is_unspecified()
                    && !peer.address.ip().is_multicast(),
                "Invalid clipboard peer address"
            );
            engine.trust(
                peer.identity.clone(),
                Directions {
                    send: peer.send,
                    receive: peer.receive,
                },
            )?;
        }
        let server = TlsAcceptor::from(secure_channel::server_config(
            &certificate,
            &private_key,
            pins,
        )?);
        let mut clients = Vec::new();
        // A canonical initiator avoids two connections racing for the same pair.
        for peer in &peers {
            if identity < peer.identity {
                clients.push((
                    peer.clone(),
                    TlsConnector::from(secure_channel::client_config(
                        &certificate,
                        &private_key,
                        &peer.identity,
                    )?),
                ));
            }
        }
        let listener = TcpListener::bind(bind).await?;
        let port = listener.local_addr()?.port();
        engine.set_enabled(true);
        let (updates, _) = watch::channel(Update::default());
        let (changed, _) = watch::channel(0);
        let shared = Arc::new(Shared {
            state: Mutex::new(State {
                engine,
                active: BTreeSet::new(),
                connected: BTreeSet::new(),
            }),
            updates,
            changed,
            cancel: CancellationToken::new(),
        });
        let worker_shared = shared.clone();
        let worker = tokio::spawn(async move {
            let mut tasks = JoinSet::new();
            for (peer, client) in clients {
                let shared = worker_shared.clone();
                tasks.spawn(async move {
                    reconnect(shared, peer, client).await;
                });
            }
            let slots = Arc::new(Semaphore::new(super::engine::MAX_PEERS * 2));
            let mut expiry = tokio::time::interval(Duration::from_secs(1));
            loop {
                tokio::select! {
                    biased;
                    _ = worker_shared.cancel.cancelled() => break,
                    _ = expiry.tick() => {
                        if let Ok(mut state) = worker_shared.state.lock() {
                            if !state.engine.has_content(Instant::now()) {
                                worker_shared.updates.send_modify(|update| { update.text = None; update.image_png = None; update.origin = None; });
                            }
                        }
                    }
                    Some(_) = tasks.join_next(), if !tasks.is_empty() => {},
                    result = listener.accept() => {
                        let Ok((stream, _)) = result else {
                            worker_shared.update(None, Some("Clipboard listener unavailable".into()));
                            break;
                        };
                        let Ok(permit) = slots.clone().try_acquire_owned() else { continue; };
                        let shared = worker_shared.clone(); let server = server.clone(); let identity = identity.clone();
                        tasks.spawn(async move {
                            let _permit = permit;
                            let accepted = tokio::select! {
                                _ = shared.cancel.cancelled() => return,
                                result = timeout(Duration::from_secs(5), server.accept(stream)) => result,
                            };
                            if let Ok(Ok(tls)) = accepted {
                                if tls.get_ref().1.alpn_protocol() != Some(ALPN) { return; }
                                let Some(cert) = tls.get_ref().1.peer_certificates().and_then(|c| c.first()) else { return; };
                                let peer = fingerprint_from_cert_der(cert.as_ref());
                                if peer >= identity { return; }
                                let _ = connection(shared, peer, tls).await;
                            }
                        });
                    }
                }
            }
            worker_shared.cancel.cancel();
            tasks.abort_all();
            while tasks.join_next().await.is_some() {}
        });
        Ok(Self {
            shared,
            worker: tokio::sync::Mutex::new(Some(worker)),
            port,
        })
    }

    pub fn capture(&self, text: Option<String>) -> anyhow::Result<()> {
        self.capture_content(text, None)
    }
    pub fn capture_image(&self, image: String) -> anyhow::Result<()> {
        self.capture_content(None, Some(image))
    }
    fn capture_content(&self, text: Option<String>, image: Option<String>) -> anyhow::Result<()> {
        anyhow::ensure!(
            !self.shared.cancel.is_cancelled(),
            "Clipboard synchronization stopped"
        );
        let mut state = self
            .shared
            .state
            .lock()
            .map_err(|_| anyhow::anyhow!("Clipboard state unavailable"))?;
        let changed = match (text, image) {
            (_, Some(image)) => state.engine.capture_image(image, wall_ms(), Instant::now()),
            (Some(text), _) => state.engine.capture(text, wall_ms(), Instant::now()),
            _ => {
                state.engine.discard_content();
                Ok(false)
            }
        };
        // A new native local capture supersedes any queued remote write.
        if changed.as_ref().is_ok_and(|changed| *changed)
            || !state.engine.has_content(Instant::now())
        {
            self.shared.updates.send_modify(|u| {
                u.text = None;
                u.image_png = None;
                u.origin = None;
            });
        }
        if changed? {
            self.shared
                .changed
                .send_modify(|revision| *revision = revision.wrapping_add(1));
        }
        Ok(())
    }

    /// A single consumer pulls one latest update. No unbounded FRB stream queues.
    pub async fn next_update(&self, after: u64) -> Option<Update> {
        let mut receiver = self.shared.updates.subscribe();
        loop {
            let update = receiver.borrow_and_update().clone();
            if update.revision != after {
                self.shared.updates.send_modify(|stored| {
                    if stored.revision == update.revision {
                        stored.text = None;
                        stored.image_png = None;
                        stored.origin = None;
                    }
                });
                return Some(update);
            }
            tokio::select! {
                _ = self.shared.cancel.cancelled() => return None,
                result = receiver.changed() => if result.is_err() { return None; }
            }
        }
    }

    pub async fn stop(&self) {
        self.shared.cancel.cancel();
        if let Ok(mut state) = self.shared.state.lock() {
            state.engine.set_enabled(false);
            state.connected.clear();
        }
        self.shared.updates.send_modify(|u| {
            u.text = None;
            u.image_png = None;
            u.origin = None;
            u.connected = 0;
            u.connected_peers.clear();
        });
        if let Some(worker) = self.worker.lock().await.take() {
            let _ = worker.await;
        }
    }
}
impl Drop for Runtime {
    fn drop(&mut self) {
        self.shared.cancel.cancel();
    }
}

struct ConnectionGuard {
    shared: Arc<Shared>,
    peer: String,
}
impl Drop for ConnectionGuard {
    fn drop(&mut self) {
        if let Ok(mut state) = self.shared.state.lock() {
            state.active.remove(&self.peer);
            state.connected.remove(&self.peer);
        }
        self.shared.update(None, None);
    }
}

async fn connection<S: AsyncRead + AsyncWrite + Unpin>(
    shared: Arc<Shared>,
    peer: String,
    mut stream: S,
) -> anyhow::Result<()> {
    {
        let mut state = shared
            .state
            .lock()
            .map_err(|_| anyhow::anyhow!("Clipboard state unavailable"))?;
        anyhow::ensure!(
            state.active.insert(peer.clone()),
            "Clipboard peer already connected"
        );
    }
    let _guard = ConnectionGuard {
        shared: shared.clone(),
        peer: peer.clone(),
    };
    let clock = shared
        .state
        .lock()
        .map_err(|_| anyhow::anyhow!("Clipboard state unavailable"))?
        .engine
        .clock();
    let images = shared
        .state
        .lock()
        .map(|s| s.engine.images_enabled())
        .unwrap_or(false);
    let peer_clock = timeout(Duration::from_secs(5), async {
        stream.write_u64(clock).await?;
        stream.write_u8(u8::from(images)).await?;
        stream.flush().await?;
        let clock = stream.read_u64().await?;
        let images = stream.read_u8().await?;
        if images > 1 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "Invalid clipboard capability",
            ));
        }
        Ok::<_, std::io::Error>((clock, images == 1))
    })
    .await??;
    {
        let mut state = shared
            .state
            .lock()
            .map_err(|_| anyhow::anyhow!("Clipboard state unavailable"))?;
        anyhow::ensure!(!shared.cancel.is_cancelled(), "Clipboard runtime stopped");
        state.engine.observe_clock(peer_clock.0, Instant::now())?;
        // Only a pinned, fully initialized session is shown as connected in the UI.
        state.connected.insert(peer.clone());
    }
    shared.update(None, None);
    let (mut reader, mut writer) = tokio::io::split(stream);
    let mut changed = shared.changed.subscribe();
    let receive = async {
        let mut bucket_start = Instant::now();
        let mut messages = 0;
        loop {
            let event = timeout(
                Duration::from_secs(65),
                secure_channel::read_message(&mut reader),
            )
            .await??;
            if bucket_start.elapsed() >= Duration::from_secs(1) {
                bucket_start = Instant::now();
                messages = 0;
            }
            messages += 1;
            anyhow::ensure!(messages <= 32, "Clipboard peer rate limit exceeded");
            if let Some(event) = event {
                shared.receive(&peer, event)?;
            }
        }
        #[allow(unreachable_code)]
        Ok::<(), anyhow::Error>(())
    };
    let send = async {
        let mut last_clock = 0;
        let mut heartbeat = tokio::time::interval(Duration::from_secs(20));
        loop {
            if let Some(event) = shared.outgoing(&peer) {
                if event.clock != last_clock && (event.image_png.is_none() || peer_clock.1) {
                    timeout(
                        Duration::from_secs(10),
                        secure_channel::write_event(&mut writer, &event),
                    )
                    .await??;
                    last_clock = event.clock;
                }
            }
            tokio::select! {
                result = changed.changed() => { result?; }
                _ = heartbeat.tick() => {
                    timeout(Duration::from_secs(10), async { writer.write_u32(0).await?; writer.flush().await }).await??;
                }
            }
        }
        #[allow(unreachable_code)]
        Ok::<(), anyhow::Error>(())
    };
    tokio::select! {
        _ = shared.cancel.cancelled() => Ok(()),
        result = async { tokio::try_join!(receive, send).map(|_| ()) } => result,
    }
}

async fn reconnect(shared: Arc<Shared>, peer: PeerConfig, client: TlsConnector) {
    let mut delay = 1u64;
    loop {
        let attempt = async {
            let stream =
                timeout(Duration::from_secs(5), TcpStream::connect(peer.address)).await??;
            stream.set_nodelay(true)?;
            let name = ServerName::try_from("clipboard.local")?;
            let tls = timeout(Duration::from_secs(5), client.connect(name, stream)).await??;
            anyhow::ensure!(
                tls.get_ref().1.alpn_protocol() == Some(ALPN),
                "Clipboard protocol mismatch"
            );
            delay = 1;
            connection(shared.clone(), peer.identity.clone(), tls).await
        };
        tokio::select! {
            _ = shared.cancel.cancelled() => return,
            _ = attempt => {},
        }
        shared.update(
            None,
            Some("Clipboard peer disconnected; reconnecting".into()),
        );
        let jitter = rand::random::<u64>() % 501;
        tokio::select! {
            _ = shared.cancel.cancelled() => return,
            _ = tokio::time::sleep(Duration::from_millis(delay * 1_000 + jitter)) => {},
        }
        delay = (delay * 2).min(30);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::cert::{generate_self_signed, SelfSignedCert};
    async fn images_runtime(
        cert: &SelfSignedCert,
        peer: &SelfSignedCert,
        port: u16,
        enabled: bool,
    ) -> Runtime {
        Runtime::start_with_images(
            cert.certificate_pem.clone(),
            cert.private_key_pem.clone(),
            SocketAddr::from(([127, 0, 0, 1], 0)),
            vec![config(&peer.fingerprint, port)],
            enabled,
        )
        .await
        .unwrap()
    }
    #[tokio::test]
    async fn connected_identities_track_individual_sessions_and_clear_on_stop() {
        let mut certs = (0..3)
            .map(|_| generate_self_signed().unwrap())
            .collect::<Vec<_>>();
        certs.sort_by(|a, b| a.fingerprint.cmp(&b.fingerprint));
        let hub_cert = &certs[2];
        let hub = Runtime::start(
            hub_cert.certificate_pem.clone(),
            hub_cert.private_key_pem.clone(),
            SocketAddr::from(([127, 0, 0, 1], 0)),
            vec![
                config(&certs[0].fingerprint, 1),
                config(&certs[1].fingerprint, 1),
            ],
        )
        .await
        .unwrap();
        let first = start(&certs[0], hub_cert, hub.port).await;
        connected(&first).await;
        let second = start(&certs[1], hub_cert, hub.port).await;
        connected(&second).await;
        let update = timeout(Duration::from_secs(5), async {
            let mut revision = 0;
            loop {
                let update = hub.next_update(revision).await.unwrap();
                revision = update.revision;
                if update.connected == 2 {
                    break update;
                }
            }
        })
        .await
        .unwrap();
        assert_eq!(
            update.connected_peers,
            vec![certs[0].fingerprint.clone(), certs[1].fingerprint.clone()]
        );
        first.stop().await;
        let update = timeout(Duration::from_secs(5), async {
            let mut revision = update.revision;
            loop {
                let update = hub.next_update(revision).await.unwrap();
                revision = update.revision;
                if update.connected == 1 {
                    break update;
                }
            }
        })
        .await
        .unwrap();
        assert_eq!(update.connected_peers, vec![certs[1].fingerprint.clone()]);
        hub.stop().await;
        assert!(hub.shared.updates.borrow().connected_peers.is_empty());
        assert_eq!(hub.shared.updates.borrow().connected, 0);
        second.stop().await;
    }

    #[tokio::test]
    async fn incomplete_session_is_not_reported_as_connected() {
        let mut ca = generate_self_signed().unwrap();
        let mut cb = generate_self_signed().unwrap();
        if ca.fingerprint > cb.fingerprint {
            std::mem::swap(&mut ca, &mut cb);
        }
        let runtime = start(&cb, &ca, 1).await;
        let (stream, _stalled_peer) = tokio::io::duplex(128);
        let shared = runtime.shared.clone();
        let peer = ca.fingerprint.clone();
        let task = tokio::spawn(connection(shared.clone(), peer.clone(), stream));
        timeout(Duration::from_secs(5), async {
            while !shared.state.lock().unwrap().active.contains(&peer) {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        shared.update(None, None);
        assert!(shared.updates.borrow().connected_peers.is_empty());
        assert_eq!(shared.updates.borrow().connected, 0);
        task.abort();
        let _ = task.await;
        assert!(shared.state.lock().unwrap().active.is_empty());
        runtime.stop().await;
    }

    #[tokio::test]
    async fn images_round_trip_and_suppress_remote_echo_and_stale_apply() {
        let mut ca = generate_self_signed().unwrap();
        let mut cb = generate_self_signed().unwrap();
        if ca.fingerprint > cb.fingerprint {
            std::mem::swap(&mut ca, &mut cb);
        }
        let b = images_runtime(&cb, &ca, 1, true).await;
        let a = images_runtime(&ca, &cb, b.port, true).await;
        let ar = connected(&a).await;
        let br = connected(&b).await;
        let png = super::super::engine::image_fixture(123);
        a.capture_image(png.clone()).unwrap();
        let update = timeout(Duration::from_secs(5), b.next_update(br))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(update.image_png.as_deref(), Some(png.as_str()));
        assert_eq!(update.origin.as_deref(), Some(ca.fingerprint.as_str()));
        assert!(update.text.is_none());
        assert!(b.should_apply_image(&png));
        b.capture_image(png.clone()).unwrap();
        assert!(timeout(Duration::from_millis(100), a.next_update(ar))
            .await
            .is_err());
        b.capture(Some("supersedes image".into())).unwrap();
        assert!(!b.should_apply_image(&png));
        a.stop().await;
        b.stop().await;
    }
    #[tokio::test]
    async fn images_off_on_peer_skips_image_without_interrupting_text() {
        let mut ca = generate_self_signed().unwrap();
        let mut cb = generate_self_signed().unwrap();
        if ca.fingerprint > cb.fingerprint {
            std::mem::swap(&mut ca, &mut cb);
        }
        let b = images_runtime(&cb, &ca, 1, false).await;
        let a = images_runtime(&ca, &cb, b.port, true).await;
        connected(&a).await;
        let mut br = connected(&b).await;
        a.capture_image(super::super::engine::image_fixture(123))
            .unwrap();
        assert!(timeout(Duration::from_millis(100), b.next_update(br))
            .await
            .is_err());
        a.capture(Some("text still works".into())).unwrap();
        assert_eq!(receive_text(&b, &mut br).await, "text still works");
        a.stop().await;
        b.stop().await;
    }

    fn config(identity: &str, port: u16) -> PeerConfig {
        PeerConfig {
            identity: identity.into(),
            address: SocketAddr::from(([127, 0, 0, 1], port)),
            send: true,
            receive: true,
        }
    }
    async fn start(cert: &SelfSignedCert, peer: &SelfSignedCert, port: u16) -> Runtime {
        Runtime::start(
            cert.certificate_pem.clone(),
            cert.private_key_pem.clone(),
            SocketAddr::from(([127, 0, 0, 1], 0)),
            vec![config(&peer.fingerprint, port)],
        )
        .await
        .unwrap()
    }
    async fn connected(runtime: &Runtime) -> u64 {
        timeout(Duration::from_secs(5), async {
            let mut revision = 0;
            loop {
                let update = runtime.next_update(revision).await.unwrap();
                revision = update.revision;
                if update.connected == 1 {
                    return revision;
                }
            }
        })
        .await
        .unwrap()
    }
    async fn receive_text(runtime: &Runtime, after: &mut u64) -> String {
        timeout(Duration::from_secs(5), async {
            loop {
                let update = runtime.next_update(*after).await.unwrap();
                *after = update.revision;
                if let Some(text) = update.text {
                    return text;
                }
            }
        })
        .await
        .unwrap()
    }
    #[tokio::test]
    async fn receive_off_keeps_connection_available_for_send() {
        let mut a_cert = generate_self_signed().unwrap();
        let mut b_cert = generate_self_signed().unwrap();
        if a_cert.fingerprint > b_cert.fingerprint {
            std::mem::swap(&mut a_cert, &mut b_cert);
        }
        let mut peer = config(&a_cert.fingerprint, 1);
        peer.receive = false;
        let b = Runtime::start(
            b_cert.certificate_pem.clone(),
            b_cert.private_key_pem.clone(),
            SocketAddr::from(([127, 0, 0, 1], 0)),
            vec![peer],
        )
        .await
        .unwrap();
        let a = start(&a_cert, &b_cert, b.port).await;
        let mut a_rev = connected(&a).await;
        let b_rev = connected(&b).await;
        a.capture(Some("not-authorized-for-receive".into()))
            .unwrap();
        assert!(timeout(Duration::from_millis(100), b.next_update(b_rev))
            .await
            .is_err());
        assert!(!b.should_apply("not-authorized-for-receive"));
        b.capture(Some("allowed-send-direction".into())).unwrap();
        assert_eq!(receive_text(&a, &mut a_rev).await, "allowed-send-direction");
        a.stop().await;
        b.stop().await;
    }
    #[tokio::test]
    async fn bidirectional_delivery_echo_suppression_restart_and_cleanup() {
        let mut a_cert = generate_self_signed().unwrap();
        let mut b_cert = generate_self_signed().unwrap();
        if a_cert.fingerprint > b_cert.fingerprint {
            std::mem::swap(&mut a_cert, &mut b_cert);
        }
        let b = start(&b_cert, &a_cert, 1).await;
        let a = start(&a_cert, &b_cert, b.port).await;
        let mut a_rev = connected(&a).await;
        let mut b_rev = connected(&b).await;
        a.capture(Some("mobile-to-desktop".into())).unwrap();
        assert_eq!(receive_text(&b, &mut b_rev).await, "mobile-to-desktop");
        assert!(b.should_apply("mobile-to-desktop"));
        b.capture(Some("mobile-to-desktop".into())).unwrap();
        assert!(timeout(Duration::from_millis(100), a.next_update(a_rev))
            .await
            .is_err());
        b.capture(Some("desktop-to-mobile".into())).unwrap();
        assert_eq!(receive_text(&a, &mut a_rev).await, "desktop-to-mobile");
        assert!(!b.should_apply("mobile-to-desktop"));
        a.stop().await;
        assert!(a.capture(Some("after-stop".into())).is_err());
        timeout(Duration::from_secs(5), async {
            loop {
                let update = b.next_update(b_rev).await.unwrap();
                b_rev = update.revision;
                if update.connected == 0 {
                    break;
                }
            }
        })
        .await
        .unwrap();
        // A process starts with a new clock, then learns the authenticated peer's
        // ordering metadata. A queued fresh copy survives that rebase.
        let restarted = start(&a_cert, &b_cert, b.port).await;
        restarted
            .capture(Some("fresh-after-restart".into()))
            .unwrap();
        assert_eq!(receive_text(&b, &mut b_rev).await, "fresh-after-restart");
        restarted.stop().await;
        b.stop().await;
        assert!(!b.should_apply("fresh-after-restart"));
        assert!(b.shared.state.lock().unwrap().active.is_empty());
    }
}
