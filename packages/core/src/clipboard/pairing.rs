//! Ephemeral, bounded enrollment channel. No clipboard payloads are accepted.
//! QR pins the host certificate and conveys a one-use 256-bit invitation.
//! Enrollment requires receiver approval and possession of its displayed secret.
//! SPAKE2 authenticates the code, with confirmation bound to the TLS connection.
use super::{engine::valid_identity, secure_channel};
use crate::crypto::cert::fingerprint_from_cert_der;
use rustls::pki_types::{pem::PemObject, CertificateDer, ServerName};
use serde::{Deserialize, Serialize};
use spake2::{Ed25519Group, Identity, Password, Spake2};
use std::{
    net::{IpAddr, SocketAddr},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::{mpsc, watch},
    task::JoinSet,
    time::timeout,
};
use tokio_rustls::{TlsAcceptor, TlsConnector, TlsStream};
use tokio_util::sync::CancellationToken;

pub const ALPN: &[u8] = b"localsend-clipboard-pairing/2";
const LIFETIME: Duration = Duration::from_secs(180);
const MAX_FRAME: usize = 2048;
const MAX_CODE_ATTEMPTS: usize = 3;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Invitation {
    pub version: u8,
    pub kind: String,
    pub fingerprint: String,
    pub port: u16,
    pub addresses: Vec<String>,
    pub token: String,
    pub expires: u64,
}
impl Invitation {
    pub fn parse(value: &str) -> anyhow::Result<Self> {
        anyhow::ensure!(value.len() <= 4096, "Invalid pairing invitation");
        let result: Self = serde_json::from_str(value)
            .map_err(|_| anyhow::anyhow!("Invalid pairing invitation"))?;
        result.validate()?;
        Ok(result)
    }
    fn validate(&self) -> anyhow::Result<()> {
        anyhow::ensure!(
            self.version == 2
                && self.kind == "localsend-clipboard-pair"
                && valid_identity(&self.fingerprint)
                && self.token.len() == 64
                && self.token.bytes().all(|b| b.is_ascii_hexdigit())
                && self.port != 0
                && !self.addresses.is_empty()
                && self.addresses.len() <= 16
                && self.expires > now()
                && self.expires <= now() + 300,
            "Invalid or expired pairing invitation"
        );
        for address in &self.addresses {
            valid_address(address.parse()?)?;
        }
        Ok(())
    }
}

#[derive(Clone, Default)]
pub struct Update {
    pub revision: u64,
    pub phase: String,
    pub code: String,
    pub fingerprint: String,
    pub address: String,
    pub name: String,
    pub expires: u64,
}
struct Shared {
    updates: watch::Sender<Update>,
    approval: watch::Sender<Option<bool>>,
    saved: watch::Sender<Option<bool>>,
    code_tx: mpsc::Sender<String>,
    code_rx: tokio::sync::Mutex<mpsc::Receiver<String>>,
    cancel: CancellationToken,
}
impl Shared {
    fn phase(&self, phase: &str) {
        self.updates.send_modify(|u| {
            u.revision += 1;
            u.phase = phase.into();
            if phase != "display_code" {
                u.code.clear();
            }
        });
    }
    fn cancel(&self) {
        if !self.cancel.is_cancelled() {
            self.updates.send_modify(|u| {
                u.revision += 1;
                u.code.clear();
                if !matches!(u.phase.as_str(), "complete" | "failed" | "expired") {
                    u.phase = "cancelled".into();
                }
            });
            self.cancel.cancel();
        }
    }
}
pub struct Session {
    shared: Arc<Shared>,
    invitation: Option<String>,
    worker: tokio::sync::Mutex<Option<tokio::task::JoinHandle<()>>>,
    pub port: u16,
}
impl Drop for Session {
    fn drop(&mut self) {
        self.shared.cancel();
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Hello {
    version: u8,
    name: String,
    clipboard_port: u16,
    token: Option<String>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Decision {
    approved: bool,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct PakeMessage {
    message: Vec<u8>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CodeProof {
    proof: Vec<u8>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CodeResult {
    accepted: bool,
    proof: Vec<u8>,
}
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
fn valid_address(ip: IpAddr) -> anyhow::Result<()> {
    anyhow::ensure!(
        ip.is_ipv4()
            && !ip.is_unspecified()
            && !ip.is_multicast()
            && !ip.is_loopback()
            && ip != IpAddr::from([255, 255, 255, 255]),
        "Invalid pairing address"
    );
    Ok(())
}
fn valid_hello(hello: &Hello) -> anyhow::Result<()> {
    anyhow::ensure!(
        hello.version == 2
            && !hello.name.is_empty()
            && hello.name.len() <= 128
            && !hello.name.chars().any(char::is_control)
            && hello.clipboard_port != 0,
        "Invalid pairing request"
    );
    Ok(())
}
async fn write_frame<T: Serialize>(
    stream: &mut (impl AsyncWrite + Unpin),
    value: &T,
) -> anyhow::Result<()> {
    let bytes = serde_json::to_vec(value)?;
    anyhow::ensure!(bytes.len() <= MAX_FRAME, "Pairing frame too large");
    stream.write_u32(bytes.len() as u32).await?;
    stream.write_all(&bytes).await?;
    stream.flush().await?;
    Ok(())
}
async fn read_frame<T: for<'a> Deserialize<'a>>(
    stream: &mut (impl AsyncRead + Unpin),
) -> anyhow::Result<T> {
    let length = stream.read_u32().await? as usize;
    anyhow::ensure!(
        length > 0 && length <= MAX_FRAME,
        "Invalid pairing frame size"
    );
    let mut bytes = vec![0; length];
    stream.read_exact(&mut bytes).await?;
    serde_json::from_slice(&bytes).map_err(|_| anyhow::anyhow!("Invalid pairing message"))
}
async fn decision(sender: &watch::Sender<Option<bool>>) -> anyhow::Result<bool> {
    let mut receiver = sender.subscribe();
    loop {
        if let Some(value) = *receiver.borrow_and_update() {
            return Ok(value);
        }
        receiver.changed().await?;
    }
}

impl Session {
    fn new() -> Self {
        let (code_tx, code_rx) = mpsc::channel(1);
        let (updates, _) = watch::channel(Update {
            phase: "waiting".into(),
            expires: now() + LIFETIME.as_secs(),
            ..Default::default()
        });
        Self {
            shared: Arc::new(Shared {
                updates,
                approval: watch::channel(None).0,
                saved: watch::channel(None).0,
                code_tx,
                code_rx: tokio::sync::Mutex::new(code_rx),
                cancel: CancellationToken::new(),
            }),
            invitation: None,
            worker: tokio::sync::Mutex::new(None),
            port: 0,
        }
    }
    pub fn invitation(&self) -> Option<String> {
        self.invitation.clone()
    }
    pub fn approve(&self, approved: bool) -> anyhow::Result<()> {
        anyhow::ensure!(
            self.shared.updates.borrow().phase == "request",
            "Pairing is not awaiting approval"
        );
        self.shared.approval.send_if_modified(|value| {
            if value.is_none() {
                *value = Some(approved);
                true
            } else {
                false
            }
        });
        Ok(())
    }
    pub fn submit_code(&self, code: String) -> anyhow::Result<()> {
        anyhow::ensure!(
            code.len() == 8 && code.bytes().all(|b| b.is_ascii_digit()),
            "Enter an eight-digit pairing code"
        );
        let submitted = self.shared.updates.send_if_modified(|u| {
            if !matches!(u.phase.as_str(), "enter_code" | "code_incorrect") {
                return false;
            }
            u.phase = "verifying_code".into();
            u.revision += 1;
            u.code.clear();
            true
        });
        anyhow::ensure!(submitted, "Pairing is not awaiting a code");
        self.shared
            .code_tx
            .try_send(code)
            .map_err(|_| anyhow::anyhow!("Pairing code already submitted"))?;
        Ok(())
    }
    pub fn persisted(&self, saved: bool) -> anyhow::Result<()> {
        anyhow::ensure!(
            self.shared.updates.borrow().phase == "authorized",
            "Pairing is not awaiting secure storage"
        );
        self.shared.saved.send_if_modified(|value| {
            if value.is_none() {
                *value = Some(saved);
                true
            } else {
                false
            }
        });
        Ok(())
    }
    pub async fn stop(&self) {
        self.shared.cancel();
        if let Some(worker) = self.worker.lock().await.take() {
            let _ = worker.await;
        }
    }
    pub async fn next_update(&self, after: u64) -> Option<Update> {
        let mut receiver = self.shared.updates.subscribe();
        loop {
            let update = receiver.borrow_and_update().clone();
            if update.revision > after {
                return Some(update);
            }
            tokio::select! {
                _ = self.shared.cancel.cancelled() => {
                    // Another consumer may stop the listener immediately after
                    // completion. Deliver its final state to the UI first.
                    let final_update = receiver.borrow().clone();
                    return (final_update.revision > after).then_some(final_update);
                },
                changed = receiver.changed() => { if changed.is_err() { return None; } }
            }
        }
    }
    pub async fn host(
        certificate: String,
        key: String,
        bind: SocketAddr,
        addresses: Vec<String>,
        name: String,
        clipboard_port: u16,
    ) -> anyhow::Result<Self> {
        valid_hello(&Hello {
            version: 2,
            name: name.clone(),
            clipboard_port,
            token: None,
        })?;
        let listener = TcpListener::bind(bind).await?;
        let (_, config) = secure_channel::pairing_configs(&certificate, &key, None)?;
        let fingerprint = fingerprint_from_cert_der(
            CertificateDer::from_pem_slice(certificate.as_bytes())?.as_ref(),
        );
        let token = rand::random::<[u8; 32]>()
            .iter()
            .map(|b| format!("{b:02X}"))
            .collect::<String>();
        let mut session = Self::new();
        session.port = listener.local_addr()?.port();
        let invitation = Invitation {
            version: 2,
            kind: "localsend-clipboard-pair".into(),
            fingerprint,
            port: session.port,
            addresses,
            token: token.clone(),
            expires: now() + LIFETIME.as_secs(),
        };
        invitation.validate()?;
        session.invitation = Some(serde_json::to_string(&invitation)?);
        let shared = session.shared.clone();
        let worker = tokio::spawn(async move {
            let acceptor = TlsAcceptor::from(config);
            let claimed = Arc::new(AtomicBool::new(false));
            let work = async {
                let mut tasks = JoinSet::new();
                let mut attempts = 0;
                loop {
                    if attempts >= 24 && tasks.is_empty() {
                        anyhow::bail!("Pairing attempt limit reached");
                    }
                    tokio::select! {
                        accepted = listener.accept(), if attempts < 24 && !claimed.load(Ordering::SeqCst) => {
                            let (tcp, remote) = accepted?; attempts += 1;
                            if tasks.len() >= 4 { continue; }
                            let acceptor = acceptor.clone(); let shared = shared.clone(); let token = token.clone();
                            let claimed = claimed.clone(); let name = name.clone();
                            tasks.spawn(async move {
                                let mut owns = false;
                                let initial = async {
                                    let mut tls = acceptor.accept(tcp).await?;
                                    anyhow::ensure!(tls.get_ref().1.alpn_protocol() == Some(ALPN), "Invalid pairing protocol");
                                    let hello: Hello = read_frame(&mut tls).await?; valid_hello(&hello)?;
                                    if let Some(offered) = &hello.token {
                                        // Fixed-length comparison without an early differing-byte exit.
                                        anyhow::ensure!(offered.len() == token.len() && offered.bytes().zip(token.bytes()).fold(0u8, |a,(b,c)| a|(b^c)) == 0, "Invalid invitation");
                                    }
                                    anyhow::ensure!(!claimed.swap(true, Ordering::SeqCst), "Pairing session already claimed");
                                    owns = true;
                                    write_frame(&mut tls, &Hello { version:2, name, clipboard_port, token:None }).await?;
                                    Ok::<_,anyhow::Error>((TlsStream::Server(tls), hello))
                                };
                                if let Ok(Ok((tls, hello))) = timeout(Duration::from_secs(5), initial).await {
                                    let result = exchange(tls, remote.ip(), hello, shared.clone()).await;
                                    if result.is_err() { shared.phase("failed"); }
                                } else if owns {
                                    shared.phase("failed");
                                }
                                owns
                            });
                        }
                        result = tasks.join_next(), if !tasks.is_empty() => {
                            if matches!(result, Some(Ok(true))) { return Ok::<_,anyhow::Error>(()); }
                        }
                    }
                }
            };
            tokio::select! {
                _ = shared.cancel.cancelled() => {},
                result = timeout(LIFETIME, work) => { if result.is_err() { shared.phase("expired"); } else if matches!(result, Ok(Err(_))) { shared.phase("failed"); } }
            }
        });
        *session.worker.lock().await = Some(worker);
        Ok(session)
    }
    pub async fn join(
        certificate: String,
        key: String,
        invitation: Option<String>,
        address: Option<SocketAddr>,
        name: String,
        clipboard_port: u16,
    ) -> anyhow::Result<Self> {
        valid_hello(&Hello {
            version: 2,
            name: name.clone(),
            clipboard_port,
            token: None,
        })?;
        let invite = invitation.as_deref().map(Invitation::parse).transpose()?;
        let (config, _) = secure_channel::pairing_configs(
            &certificate,
            &key,
            invite.as_ref().map(|i| i.fingerprint.as_str()),
        )?;
        let addresses = if let Some(invite) = &invite {
            invite
                .addresses
                .iter()
                .map(|ip| Ok(SocketAddr::new(ip.parse()?, invite.port)))
                .collect::<anyhow::Result<Vec<_>>>()?
        } else {
            let address = address.ok_or_else(|| anyhow::anyhow!("Missing pairing address"))?;
            valid_address(address.ip())?;
            anyhow::ensure!(address.port() != 0, "Invalid pairing port");
            vec![address]
        };
        let session = Self::new();
        let shared = session.shared.clone();
        let worker = tokio::spawn(async move {
            let work = async {
                let connector = TlsConnector::from(config);
                let mut connected = None;
                for address in addresses {
                    let connect = async {
                        let tcp = TcpStream::connect(address).await?;
                        let tls = connector
                            .connect(ServerName::try_from("clipboard.local")?, tcp)
                            .await?;
                        anyhow::ensure!(
                            tls.get_ref().1.alpn_protocol() == Some(ALPN),
                            "Invalid pairing protocol"
                        );
                        Ok::<_, anyhow::Error>((tls, address))
                    };
                    if let Ok(Ok(value)) = timeout(Duration::from_secs(3), connect).await {
                        connected = Some(value);
                        break;
                    }
                }
                let (mut tls, address) =
                    connected.ok_or_else(|| anyhow::anyhow!("Pairing host unreachable"))?;
                write_frame(
                    &mut tls,
                    &Hello {
                        version: 2,
                        name,
                        clipboard_port,
                        token: invite.map(|i| i.token),
                    },
                )
                .await?;
                let hello: Hello = timeout(Duration::from_secs(5), read_frame(&mut tls)).await??;
                valid_hello(&hello)?;
                exchange(TlsStream::Client(tls), address.ip(), hello, shared.clone()).await
            };
            tokio::select! { _ = shared.cancel.cancelled() => {}, result = timeout(LIFETIME,work) => {
                match result { Ok(Ok(())) => {}, Err(_) => shared.phase("expired"), _ => shared.phase("failed") }
            } }
        });
        *session.worker.lock().await = Some(worker);
        Ok(session)
    }
}

async fn exchange(
    mut tls: TlsStream<TcpStream>,
    remote: IpAddr,
    hello: Hello,
    shared: Arc<Shared>,
) -> anyhow::Result<()> {
    let connection = tls.get_ref().1;
    let peer = connection
        .peer_certificates()
        .and_then(|c| c.first())
        .ok_or_else(|| anyhow::anyhow!("Missing pairing certificate"))?;
    let fingerprint = fingerprint_from_cert_der(peer.as_ref());
    let receiver = matches!(&tls, TlsStream::Server(_));
    // RFC 9266 channel binding: a relay using two TLS connections cannot
    // authenticate the code for the original device's connection.
    let binding = match &tls {
        TlsStream::Client(stream) => stream.get_ref().1.export_keying_material(
            [0u8; 32],
            b"EXPORTER-Channel-Binding",
            Some(&[]),
        )?,
        TlsStream::Server(stream) => stream.get_ref().1.export_keying_material(
            [0u8; 32],
            b"EXPORTER-Channel-Binding",
            Some(&[]),
        )?,
    };
    shared.updates.send_modify(|u| {
        u.revision += 1;
        u.phase = if receiver { "request" } else { "requesting" }.into();
        u.code.clear();
        u.fingerprint = fingerprint;
        u.address = SocketAddr::new(remote, hello.clipboard_port).to_string();
        u.name = hello.name;
    });
    if receiver {
        let approved = decision(&shared.approval).await?;
        write_frame(&mut tls, &Decision { approved }).await?;
        anyhow::ensure!(approved, "Pairing declined");
    } else {
        let response: Decision = read_frame(&mut tls).await?;
        anyhow::ensure!(response.approved, "Pairing declined");
    }
    authenticate_code(&mut tls, &shared, &binding, receiver).await?;
    shared.phase("authorized");
    let saved = decision(&shared.saved).await?;
    write_frame(&mut tls, &Decision { approved: saved }).await?;
    let peer: Decision = read_frame(&mut tls).await?;
    anyhow::ensure!(saved && peer.approved, "Pairing persistence failed");
    shared.phase("complete");
    Ok(())
}

/// The receiver's random secret never appears in a network frame. SPAKE2
/// prevents an observed exchange from becoming an offline PIN-guessing oracle.
async fn authenticate_code(
    tls: &mut TlsStream<TcpStream>,
    shared: &Shared,
    binding: &[u8; 32],
    receiver: bool,
) -> anyhow::Result<()> {
    let secret = receiver.then(|| format!("{:08}", rand::random_range(0..100_000_000u32)));
    if let Some(code) = &secret {
        shared.updates.send_modify(|u| {
            u.revision += 1;
            u.phase = "display_code".into();
            u.code = code.clone();
        });
    } else {
        shared.phase("enter_code");
    }
    let id_a = Identity::new(&[b"localsend-pairing/2/requester".as_slice(), binding].concat());
    let id_b = Identity::new(&[b"localsend-pairing/2/receiver".as_slice(), binding].concat());
    for attempt in 0..MAX_CODE_ATTEMPTS {
        let receiver_message = if receiver {
            None
        } else {
            Some(read_frame::<PakeMessage>(tls).await?)
        };
        let password = if let Some(code) = &secret {
            Password::new(code.as_bytes())
        } else {
            let mut codes = shared.code_rx.lock().await;
            let mut unexpected = [0u8; 1];
            let code = tokio::select! {
                code = codes.recv() => code.ok_or_else(|| anyhow::anyhow!("Pairing cancelled"))?,
                // The receiver sends no more bytes until we submit our PAKE
                // message. Detect its cancellation/expiry while waiting for UI.
                _ = tls.read(&mut unexpected) => anyhow::bail!("Pairing connection closed"),
            };
            Password::new(code.as_bytes())
        };
        let (pake, message) = if receiver {
            Spake2::<Ed25519Group>::start_b(&password, &id_a, &id_b)
        } else {
            Spake2::<Ed25519Group>::start_a(&password, &id_a, &id_b)
        };
        write_frame(tls, &PakeMessage { message }).await?;
        let peer: PakeMessage = match receiver_message {
            Some(message) => message,
            None => read_frame(tls).await?,
        };
        let key = pake
            .finish(&peer.message)
            .map_err(|_| anyhow::anyhow!("Invalid pairing exchange"))?;
        let key = ring::hmac::Key::new(ring::hmac::HMAC_SHA256, &key);
        let requester_proof =
            [b"localsend-pairing/2/requester-confirm".as_slice(), binding].concat();
        let receiver_proof = [b"localsend-pairing/2/receiver-confirm".as_slice(), binding].concat();
        let accepted = if receiver {
            let peer: CodeProof = read_frame(tls).await?;
            let accepted = ring::hmac::verify(&key, &requester_proof, &peer.proof).is_ok();
            write_frame(
                tls,
                &CodeResult {
                    accepted,
                    proof: if accepted {
                        ring::hmac::sign(&key, &receiver_proof).as_ref().to_vec()
                    } else {
                        Vec::new()
                    },
                },
            )
            .await?;
            accepted
        } else {
            write_frame(
                tls,
                &CodeProof {
                    proof: ring::hmac::sign(&key, &requester_proof).as_ref().to_vec(),
                },
            )
            .await?;
            let result: CodeResult = read_frame(tls).await?;
            if result.accepted {
                ring::hmac::verify(&key, &receiver_proof, &result.proof)
                    .map_err(|_| anyhow::anyhow!("Pairing verification failed"))?;
                true
            } else {
                false
            }
        };
        if accepted {
            return Ok(());
        }
        if !receiver && attempt + 1 < MAX_CODE_ATTEMPTS {
            shared.phase("code_incorrect");
        }
    }
    anyhow::bail!("Pairing code attempt limit reached")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::cert::{generate_self_signed, SelfSignedCert};

    async fn host(cert: &SelfSignedCert) -> Session {
        Session::host(
            cert.certificate_pem.clone(),
            cert.private_key_pem.clone(),
            "127.0.0.1:0".parse().unwrap(),
            vec!["192.0.2.1".into()],
            "Computer".into(),
            53318,
        )
        .await
        .unwrap()
    }
    async fn connect(
        host: &Session,
        cert: &SelfSignedCert,
        token: Option<String>,
        pin: Option<&str>,
    ) -> anyhow::Result<TlsStream<TcpStream>> {
        let (config, _) =
            secure_channel::pairing_configs(&cert.certificate_pem, &cert.private_key_pem, pin)?;
        let tcp = TcpStream::connect(SocketAddr::from(([127, 0, 0, 1], host.port))).await?;
        let mut tls = TlsConnector::from(config)
            .connect(ServerName::try_from("clipboard.local")?, tcp)
            .await?;
        write_frame(
            &mut tls,
            &Hello {
                version: 2,
                name: "Phone".into(),
                clipboard_port: 53318,
                token,
            },
        )
        .await?;
        let hello: Hello = read_frame(&mut tls).await?;
        valid_hello(&hello)?;
        Ok(TlsStream::Client(tls))
    }
    async fn client(
        host: &Session,
        cert: &SelfSignedCert,
        token: Option<String>,
        pin: Option<&str>,
    ) -> Session {
        let tls = connect(host, cert, token, pin).await.unwrap();
        let session = Session::new();
        let shared = session.shared.clone();
        let worker = tokio::spawn(async move {
            if exchange(
                tls,
                IpAddr::from([127, 0, 0, 1]),
                Hello {
                    version: 2,
                    name: "Computer".into(),
                    clipboard_port: 53318,
                    token: None,
                },
                shared.clone(),
            )
            .await
            .is_err()
            {
                shared.phase("failed");
            }
        });
        *session.worker.lock().await = Some(worker);
        session
    }
    async fn phase(session: &Session, wanted: &str) -> Update {
        timeout(Duration::from_secs(3), async {
            let mut revision = 0;
            loop {
                let u = session.next_update(revision).await.unwrap();
                revision = u.revision;
                if u.phase == wanted {
                    return u;
                }
            }
        })
        .await
        .unwrap()
    }
    #[test]
    fn invitations_are_bounded_expiring_and_strict() {
        let mut invite = Invitation {
            version: 2,
            kind: "localsend-clipboard-pair".into(),
            fingerprint: "A".repeat(64),
            port: 53319,
            addresses: vec!["192.0.2.1".into()],
            token: "B".repeat(64),
            expires: now() + 180,
        };
        assert!(Invitation::parse(&serde_json::to_string(&invite).unwrap()).is_ok());
        invite.expires = now();
        assert!(invite.validate().is_err());
        invite.expires = now() + 180;
        invite.addresses = vec!["127.0.0.1".into()];
        assert!(invite.validate().is_err());
        assert!(Invitation::parse(&"x".repeat(4097)).is_err());
        assert!(!Invitation::parse("private-invitation")
            .err()
            .unwrap()
            .to_string()
            .contains("private-invitation"));
    }
    #[tokio::test]
    async fn oversized_pairing_frames_reject_before_allocation() {
        let bytes = (MAX_FRAME as u32 + 1).to_be_bytes();
        assert!(read_frame::<Decision>(&mut bytes.as_slice()).await.is_err());
    }
    async fn approve_and_enter(host: &Session, client: &Session) {
        let request = phase(host, "request").await;
        assert!(request.code.is_empty());
        assert!(host.persisted(true).is_err());
        host.approve(true).unwrap();
        let display = phase(host, "display_code").await;
        assert_eq!(display.code.len(), 8);
        assert!(display.code.bytes().all(|b| b.is_ascii_digit()));
        assert!(phase(client, "enter_code").await.code.is_empty());
        assert!(client.approve(true).is_err());
        client.submit_code(display.code).unwrap();
        assert!(phase(host, "authorized").await.code.is_empty());
        assert!(phase(client, "authorized").await.code.is_empty());
    }
    #[tokio::test]
    async fn qr_pairing_requires_receiver_approval_secret_code_and_both_storage_acknowledgements() {
        let a = generate_self_signed().unwrap();
        let b = generate_self_signed().unwrap();
        let host = host(&a).await;
        let invite = Invitation::parse(&host.invitation().unwrap()).unwrap();
        let client = client(&host, &b, Some(invite.token), Some(&a.fingerprint)).await;
        assert!(client.submit_code("12345678".into()).is_err());
        approve_and_enter(&host, &client).await;
        assert_eq!(host.shared.updates.borrow().fingerprint, b.fingerprint);
        assert_eq!(client.shared.updates.borrow().fingerprint, a.fingerprint);
        host.persisted(true).unwrap();
        assert!(timeout(Duration::from_millis(50), phase(&host, "complete"))
            .await
            .is_err());
        client.persisted(true).unwrap();
        phase(&host, "complete").await;
        phase(&client, "complete").await;
        let port = host.port;
        host.stop().await;
        client.stop().await;
        assert!(TcpListener::bind(SocketAddr::from(([127, 0, 0, 1], port)))
            .await
            .is_ok());
    }
    #[tokio::test]
    async fn invalid_qr_token_and_wrong_pin_are_rejected_and_decline_never_displays_a_secret() {
        let a = generate_self_signed().unwrap();
        let b = generate_self_signed().unwrap();
        let host = host(&a).await;
        assert!(
            connect(&host, &b, Some("0".repeat(64)), Some(&a.fingerprint))
                .await
                .is_err()
        );
        assert!(connect(&host, &b, None, Some(&"0".repeat(64)))
            .await
            .is_err());
        assert_eq!(host.shared.updates.borrow().phase, "waiting");
        let client = client(&host, &b, None, None).await;
        phase(&host, "request").await;
        host.approve(false).unwrap();
        assert!(phase(&host, "failed").await.code.is_empty());
        assert!(phase(&client, "failed").await.code.is_empty());
        host.stop().await;
        client.stop().await;
    }
    #[tokio::test]
    async fn three_wrong_codes_exhaust_the_session_without_persisting_trust() {
        let a = generate_self_signed().unwrap();
        let b = generate_self_signed().unwrap();
        let host = host(&a).await;
        let client = client(&host, &b, None, None).await;
        phase(&host, "request").await;
        host.approve(true).unwrap();
        let code = phase(&host, "display_code").await.code;
        let wrong = if code == "00000000" {
            "00000001"
        } else {
            "00000000"
        };
        phase(&client, "enter_code").await;
        assert!(client.submit_code("123".into()).is_err());
        assert!(client.submit_code("1234567x".into()).is_err());
        for attempt in 0..MAX_CODE_ATTEMPTS {
            client.submit_code(wrong.into()).unwrap();
            if attempt + 1 < MAX_CODE_ATTEMPTS {
                phase(&client, "code_incorrect").await;
            }
        }
        assert!(phase(&host, "failed").await.code.is_empty());
        phase(&client, "failed").await;
        assert!(client.submit_code(code).is_err());
        assert!(host.persisted(true).is_err());
        host.stop().await;
        client.stop().await;
    }
    #[tokio::test]
    async fn a_correct_retry_authenticates_but_storage_failure_prevents_completion() {
        let a = generate_self_signed().unwrap();
        let b = generate_self_signed().unwrap();
        let host = host(&a).await;
        let client = client(&host, &b, None, None).await;
        phase(&host, "request").await;
        host.approve(true).unwrap();
        let code = phase(&host, "display_code").await.code;
        phase(&client, "enter_code").await;
        client
            .submit_code(
                if code == "00000000" {
                    "00000001"
                } else {
                    "00000000"
                }
                .into(),
            )
            .unwrap();
        phase(&client, "code_incorrect").await;
        client.submit_code(code).unwrap();
        phase(&host, "authorized").await;
        phase(&client, "authorized").await;
        host.persisted(false).unwrap();
        client.persisted(true).unwrap();
        phase(&host, "failed").await;
        phase(&client, "failed").await;
        host.stop().await;
        client.stop().await;
    }
    #[tokio::test]
    async fn cancelling_after_approval_clears_the_secret_and_never_authorizes() {
        let a = generate_self_signed().unwrap();
        let b = generate_self_signed().unwrap();
        let host = host(&a).await;
        let client = client(&host, &b, None, None).await;
        phase(&host, "request").await;
        host.approve(true).unwrap();
        phase(&host, "display_code").await;
        phase(&client, "enter_code").await;
        host.stop().await;
        let cancelled = phase(&host, "cancelled").await;
        assert!(cancelled.code.is_empty());
        assert!(host.persisted(true).is_err());
        phase(&client, "failed").await;
        assert!(client.persisted(true).is_err());
        client.stop().await;
    }
    #[test]
    fn identical_passwords_on_different_connections_cannot_confirm_a_relayed_exchange() {
        let password = Password::new(b"12345678");
        let (a, ma) = Spake2::<Ed25519Group>::start_a(
            &password,
            &Identity::new(b"connection1/a"),
            &Identity::new(b"connection1/b"),
        );
        let (b, mb) = Spake2::<Ed25519Group>::start_b(
            &password,
            &Identity::new(b"connection2/a"),
            &Identity::new(b"connection2/b"),
        );
        let ka = ring::hmac::Key::new(ring::hmac::HMAC_SHA256, &a.finish(&mb).unwrap());
        let kb = ring::hmac::Key::new(ring::hmac::HMAC_SHA256, &b.finish(&ma).unwrap());
        let proof = ring::hmac::sign(&ka, b"requester-confirm");
        assert!(ring::hmac::verify(&kb, b"requester-confirm", proof.as_ref()).is_err());
    }
}
