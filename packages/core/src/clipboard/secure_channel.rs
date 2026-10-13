//! Clipboard-specific TLS 1.3 authentication. No discovery/TOFU verification mode.
//! An exact certificate pin and a valid CertificateVerify signature are both required.
use super::engine::{valid_identity, ClipboardEvent, MAX_TEXT_BYTES};
use crate::crypto::cert::{fingerprint_from_cert_der, verify_cert_from_der};
use rustls::{
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    pki_types::{pem::PemObject, CertificateDer, PrivateKeyDer, ServerName, UnixTime},
    server::danger::{ClientCertVerified, ClientCertVerifier},
    ClientConfig, DigitallySignedStruct, DistinguishedName, Error, ServerConfig, SignatureScheme,
};
use std::{collections::BTreeSet, sync::Arc};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub const ALPN: &[u8] = b"localsend-clipboard/2";
// JSON may escape each UTF-8 byte to six ASCII bytes. Bound before allocating.
pub const MAX_FRAME_BYTES: usize = super::engine::MAX_IMAGE_BASE64 + 1_024;

#[derive(Debug)]
struct PinnedCertificates {
    pins: BTreeSet<String>,
    pairing_only: bool,
}

impl PinnedCertificates {
    fn new(pins: BTreeSet<String>) -> anyhow::Result<Self> {
        anyhow::ensure!(
            !pins.is_empty() && pins.len() <= super::engine::MAX_PEERS,
            "Clipboard trust must contain 1..8 explicitly paired identities"
        );
        anyhow::ensure!(
            pins.iter().all(|pin| valid_identity(pin)),
            "Invalid clipboard identity pin"
        );
        Ok(Self {
            pins,
            pairing_only: false,
        })
    }

    fn verify(&self, cert: &CertificateDer<'_>) -> Result<(), Error> {
        let error =
            || Error::InvalidCertificate(rustls::CertificateError::ApplicationVerificationFailure);
        // Bound certificate parsing before inspecting untrusted ASN.1.
        if cert.len() > 16_384 {
            return Err(error());
        }
        if !self.pairing_only
            && !self
                .pins
                .contains(&fingerprint_from_cert_der(cert.as_ref()))
        {
            return Err(error());
        }
        verify_cert_from_der(cert.as_ref(), None).map_err(|_| error())
    }

    fn signature13(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            signature,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }
    fn signature12(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            signature,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }
    fn schemes(&self) -> Vec<SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

impl ServerCertVerifier for PinnedCertificates {
    fn verify_server_cert(
        &self,
        cert: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: &ServerName<'_>,
        _: &[u8],
        _: UnixTime,
    ) -> Result<ServerCertVerified, Error> {
        self.verify(cert)?;
        Ok(ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        self.signature12(message, cert, signature)
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        self.signature13(message, cert, signature)
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.schemes()
    }
}

impl ClientCertVerifier for PinnedCertificates {
    fn client_auth_mandatory(&self) -> bool {
        true
    }
    fn root_hint_subjects(&self) -> &[DistinguishedName] {
        &[]
    }
    fn verify_client_cert(
        &self,
        cert: &CertificateDer<'_>,
        _: &[CertificateDer<'_>],
        _: UnixTime,
    ) -> Result<ClientCertVerified, Error> {
        self.verify(cert)?;
        Ok(ClientCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        self.signature12(message, cert, signature)
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        self.signature13(message, cert, signature)
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.schemes()
    }
}

pub fn client_config(
    certificate_pem: &str,
    private_key_pem: &str,
    expected_peer: &str,
) -> anyhow::Result<Arc<ClientConfig>> {
    let verifier = PinnedCertificates::new(BTreeSet::from([expected_peer.to_owned()]))?;
    let mut config =
        ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_protocol_versions(&[&rustls::version::TLS13])?
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(verifier))
            .with_client_auth_cert(
                vec![CertificateDer::from_pem_slice(certificate_pem.as_bytes())?],
                PrivateKeyDer::from_pem_slice(private_key_pem.as_bytes())?,
            )?;
    config.alpn_protocols = vec![ALPN.to_vec()];
    config.resumption = rustls::client::Resumption::disabled();
    config.enable_early_data = false;
    Ok(Arc::new(config))
}

pub fn server_config(
    certificate_pem: &str,
    private_key_pem: &str,
    trusted_peers: BTreeSet<String>,
) -> anyhow::Result<Arc<ServerConfig>> {
    let verifier = PinnedCertificates::new(trusted_peers)?;
    let mut config =
        ServerConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
            .with_protocol_versions(&[&rustls::version::TLS13])?
            .with_client_cert_verifier(Arc::new(verifier))
            .with_single_cert(
                vec![CertificateDer::from_pem_slice(certificate_pem.as_bytes())?],
                PrivateKeyDer::from_pem_slice(private_key_pem.as_bytes())?,
            )?;
    config.alpn_protocols = vec![ALPN.to_vec()];
    config.send_tls13_tickets = 0;
    config.session_storage = Arc::new(rustls::server::NoServerSessionStorage {});
    config.max_early_data_size = 0;
    Ok(Arc::new(config))
}

/// Temporary identity enrollment only. These configurations never serve text.
/// Unknown identities require explicit comparison of the TLS channel binding
/// and approval on both devices before being persisted as clipboard trust.
pub(super) fn pairing_configs(
    certificate: &str,
    key: &str,
    expected_server: Option<&str>,
) -> anyhow::Result<(Arc<ClientConfig>, Arc<ServerConfig>)> {
    let pending = || PinnedCertificates {
        pins: BTreeSet::new(),
        pairing_only: true,
    };
    let server_verifier = pending();
    let client_verifier = match expected_server {
        Some(pin) => PinnedCertificates::new(BTreeSet::from([pin.to_owned()]))?,
        None => pending(),
    };
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let cert = CertificateDer::from_pem_slice(certificate.as_bytes())?;
    let mut client = ClientConfig::builder_with_provider(provider.clone())
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(client_verifier))
        .with_client_auth_cert(
            vec![cert.clone()],
            PrivateKeyDer::from_pem_slice(key.as_bytes())?,
        )?;
    client.alpn_protocols = vec![super::pairing::ALPN.to_vec()];
    client.resumption = rustls::client::Resumption::disabled();
    client.enable_early_data = false;
    let mut server = ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .with_client_cert_verifier(Arc::new(server_verifier))
        .with_single_cert(vec![cert], PrivateKeyDer::from_pem_slice(key.as_bytes())?)?;
    server.alpn_protocols = vec![super::pairing::ALPN.to_vec()];
    server.send_tls13_tickets = 0;
    server.session_storage = Arc::new(rustls::server::NoServerSessionStorage {});
    server.max_early_data_size = 0;
    Ok((Arc::new(client), Arc::new(server)))
}

pub async fn read_event(reader: &mut (impl AsyncRead + Unpin)) -> anyhow::Result<ClipboardEvent> {
    read_message(reader)
        .await?
        .ok_or_else(|| anyhow::anyhow!("Expected clipboard text event"))
}

/// A zero-length frame is a heartbeat, with no payload allocation.
pub async fn read_message(
    reader: &mut (impl AsyncRead + Unpin),
) -> anyhow::Result<Option<ClipboardEvent>> {
    let size = reader.read_u32().await? as usize;
    if size == 0 {
        return Ok(None);
    }
    anyhow::ensure!(
        size > 0 && size <= MAX_FRAME_BYTES,
        "Invalid clipboard frame size"
    );
    let mut payload = vec![0; size];
    reader.read_exact(&mut payload).await?;
    // Do not propagate serde errors: their messages can quote clipboard values.
    let event = serde_json::from_slice::<ClipboardEvent>(&payload)
        .map_err(|_| anyhow::anyhow!("Invalid clipboard event encoding"))?;
    anyhow::ensure!(
        event.text.len() <= MAX_TEXT_BYTES,
        "Clipboard text exceeds 64 KiB"
    );
    anyhow::ensure!(
        event
            .image_png
            .as_ref()
            .is_none_or(|p| p.len() <= super::engine::MAX_IMAGE_BASE64),
        "Clipboard image exceeds limit"
    );
    Ok(Some(event))
}

pub async fn write_event(
    writer: &mut (impl AsyncWrite + Unpin),
    event: &ClipboardEvent,
) -> anyhow::Result<()> {
    anyhow::ensure!(
        event
            .image_png
            .as_ref()
            .is_none_or(|p| p.len() <= super::engine::MAX_IMAGE_BASE64),
        "Clipboard image exceeds limit"
    );
    anyhow::ensure!(
        event.text.len() <= MAX_TEXT_BYTES,
        "Clipboard text exceeds 64 KiB"
    );
    let payload = serde_json::to_vec(event)?;
    anyhow::ensure!(
        payload.len() <= MAX_FRAME_BYTES,
        "Clipboard frame too large"
    );
    writer.write_u32(payload.len() as u32).await?;
    writer.write_all(&payload).await?;
    writer.flush().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn frame_round_trip_and_bounded_allocation() {
        let event = ClipboardEvent {
            version: 1,
            origin: "A".repeat(64),
            clock: 1,
            created_ms: 1_000,
            text: "\0".repeat(MAX_TEXT_BYTES),
            image_png: None,
        };
        let mut bytes = Vec::new();
        write_event(&mut bytes, &event).await.unwrap();
        assert!(bytes.len() <= MAX_FRAME_BYTES + 4);
        let received = read_event(&mut bytes.as_slice()).await.unwrap();
        assert_eq!(received.text, event.text);
        let oversized = (MAX_FRAME_BYTES as u32 + 1).to_be_bytes();
        let error = read_event(&mut oversized.as_slice()).await.unwrap_err();
        assert_eq!(error.to_string(), "Invalid clipboard frame size");
    }
    #[tokio::test]
    async fn malformed_encoding_does_not_echo_private_text() {
        let text = b"{\"version\":\"private-value\"}";
        let mut bytes = Vec::new();
        bytes.write_u32(text.len() as u32).await.unwrap();
        bytes.extend_from_slice(text);
        let error = read_event(&mut bytes.as_slice()).await.unwrap_err();
        assert!(!error.to_string().contains("private-value"));
    }
    #[test]
    fn empty_and_malformed_pin_sets_are_rejected() {
        assert!(PinnedCertificates::new(BTreeSet::new()).is_err());
        assert!(PinnedCertificates::new(BTreeSet::from(["not-a-pin".into()])).is_err());
    }
    #[tokio::test]
    async fn mutual_pin_handshake_and_unknown_client_rejection() {
        use crate::crypto::cert::generate_self_signed;
        use tokio::{
            net::{TcpListener, TcpStream},
            time::{timeout, Duration},
        };
        use tokio_rustls::{TlsAcceptor, TlsConnector};
        let a = generate_self_signed().unwrap();
        let b = generate_self_signed().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let acceptor = TlsAcceptor::from(
            server_config(
                &a.certificate_pem,
                &a.private_key_pem,
                BTreeSet::from([b.fingerprint.clone()]),
            )
            .unwrap(),
        );
        let client = TlsConnector::from(
            client_config(&b.certificate_pem, &b.private_key_pem, &a.fingerprint).unwrap(),
        );
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let tls = acceptor.accept(stream).await.unwrap();
            assert_eq!(tls.get_ref().1.alpn_protocol(), Some(ALPN));
            assert_eq!(
                tls.get_ref().1.protocol_version(),
                Some(rustls::ProtocolVersion::TLSv1_3)
            );
        });
        let tls = timeout(
            Duration::from_secs(5),
            client.connect(
                ServerName::try_from("clipboard.local").unwrap(),
                TcpStream::connect(address).await.unwrap(),
            ),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(tls.get_ref().1.alpn_protocol(), Some(ALPN));
        server.await.unwrap();

        // The same peer must not authenticate when its cert pin was revoked.
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let acceptor = TlsAcceptor::from(
            server_config(
                &a.certificate_pem,
                &a.private_key_pem,
                BTreeSet::from(["0".repeat(64)]),
            )
            .unwrap(),
        );
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            assert!(acceptor.accept(stream).await.is_err());
        });
        // TLS 1.3 client's connect can finish before the server's rejection alert.
        if let Ok(mut tls) = client
            .connect(
                ServerName::try_from("clipboard.local").unwrap(),
                TcpStream::connect(address).await.unwrap(),
            )
            .await
        {
            let mut byte = [0];
            assert!(tls.read(&mut byte).await.is_err());
        }
        server.await.unwrap();
    }
}
