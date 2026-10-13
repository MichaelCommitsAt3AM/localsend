//! Ephemeral, bounded enrollment channel. No clipboard payloads are accepted.
//! QR pins the host certificate and conveys a one-use 256-bit invitation.
//! Nearby enrollment additionally depends on users comparing the TLS-exporter
//! code on both physical screens. This protocol still needs external review.
use super::{engine::valid_identity, secure_channel};
use crate::crypto::cert::fingerprint_from_cert_der;
use rustls::pki_types::{pem::PemObject, CertificateDer, ServerName};
use serde::{Deserialize, Serialize};
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
    sync::watch,
    task::JoinSet,
    time::timeout,
};
use tokio_rustls::{TlsAcceptor, TlsConnector, TlsStream};
use tokio_util::sync::CancellationToken;

pub const ALPN: &[u8] = b"localsend-clipboard-pairing/1";
const LIFETIME: Duration = Duration::from_secs(180);
const MAX_FRAME: usize = 2048;

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
    cancel: CancellationToken,
}
impl Shared {
    fn phase(&self, phase: &str) {
        self.updates.send_modify(|u| {
            u.revision += 1;
            u.phase = phase.into();
        });
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
        self.shared.cancel.cancel();
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
        hello.version == 1
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
            self.shared.updates.borrow().phase == "verify",
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
        self.shared.cancel.cancel();
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
            tokio::select! { _ = self.shared.cancel.cancelled() => return None, changed = receiver.changed() => { if changed.is_err() { return None; } } }
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
            version: 1,
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
                                    write_frame(&mut tls, &Hello { version:1, name, clipboard_port, token:None }).await?;
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
            version: 1,
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
                        version: 1,
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
    // RFC 9266 TLS 1.3 channel binding. Neither certificates nor names alone
    // determine the displayed code. Every handshake yields a fresh comparison.
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
    let number = u64::from_be_bytes(binding[..8].try_into()?) % 100_000_000;
    let code = format!("{:04} {:04}", number / 10000, number % 10000);
    shared.updates.send_modify(|u| {
        u.revision += 1;
        u.phase = "verify".into();
        u.code = code;
        u.fingerprint = fingerprint;
        u.address = SocketAddr::new(remote, hello.clipboard_port).to_string();
        u.name = hello.name;
    });
    let approved = decision(&shared.approval).await?;
    write_frame(&mut tls, &Decision { approved }).await?;
    let peer: Decision = read_frame(&mut tls).await?;
    anyhow::ensure!(approved && peer.approved, "Pairing declined");
    shared.phase("authorized");
    let saved = decision(&shared.saved).await?;
    write_frame(&mut tls, &Decision { approved: saved }).await?;
    let peer: Decision = read_frame(&mut tls).await?;
    anyhow::ensure!(saved && peer.approved, "Pairing persistence failed");
    shared.phase("complete");
    Ok(())
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
                version: 1,
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
                    version: 1,
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
    #[tokio::test]
    async fn qr_pairing_requires_both_approval_and_both_secure_storage_acknowledgements() {
        let a = generate_self_signed().unwrap();
        let b = generate_self_signed().unwrap();
        let host = host(&a).await;
        let invite = Invitation::parse(&host.invitation().unwrap()).unwrap();
        let client = client(&host, &b, Some(invite.token), Some(&a.fingerprint)).await;
        let h = phase(&host, "verify").await;
        let c = phase(&client, "verify").await;
        assert_eq!(h.code, c.code);
        assert_eq!(h.fingerprint, b.fingerprint);
        assert_eq!(c.fingerprint, a.fingerprint);
        assert_eq!(h.code.len(), 9);
        assert!(host.persisted(true).is_err());
        host.approve(true).unwrap();
        assert!(
            timeout(Duration::from_millis(50), phase(&host, "authorized"))
                .await
                .is_err()
        );
        client.approve(true).unwrap();
        phase(&host, "authorized").await;
        phase(&client, "authorized").await;
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
    async fn invalid_qr_token_does_not_claim_invitation_and_wrong_pin_is_rejected() {
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
        let invite = Invitation::parse(&host.invitation().unwrap()).unwrap();
        let client = client(&host, &b, Some(invite.token), Some(&a.fingerprint)).await;
        phase(&host, "verify").await;
        phase(&client, "verify").await;
        host.approve(false).unwrap();
        client.approve(true).unwrap();
        phase(&host, "failed").await;
        phase(&client, "failed").await;
        host.stop().await;
        client.stop().await;
    }
    #[tokio::test]
    async fn nearby_comparison_and_storage_failure_do_not_complete_pairing() {
        let a = generate_self_signed().unwrap();
        let b = generate_self_signed().unwrap();
        let host = host(&a).await;
        let client = client(&host, &b, None, None).await;
        assert_eq!(
            phase(&host, "verify").await.code,
            phase(&client, "verify").await.code
        );
        host.approve(true).unwrap();
        client.approve(true).unwrap();
        phase(&host, "authorized").await;
        phase(&client, "authorized").await;
        host.persisted(false).unwrap();
        client.persisted(true).unwrap();
        phase(&host, "failed").await;
        phase(&client, "failed").await;
        host.stop().await;
        client.stop().await;
    }
}
