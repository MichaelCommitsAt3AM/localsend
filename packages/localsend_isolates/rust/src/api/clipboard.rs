use base64::Engine as _;
use localsend::clipboard::runtime::{PeerConfig, Runtime};
use std::net::SocketAddr;

pub struct RsClipboardPeer {
    pub fingerprint: String,
    pub address: String,
    pub send: bool,
    pub receive: bool,
}

pub struct RsClipboardUpdate {
    pub revision: u64,
    pub connected: u32,
    pub connected_peers: Vec<String>,
    pub text: Option<String>,
    pub image_png: Option<Vec<u8>>,
    pub origin: Option<String>,
    pub error: Option<String>,
}

#[flutter_rust_bridge::frb(opaque)]
pub struct RsClipboardRuntime {
    inner: Runtime,
}

/// Clipboard traffic is owned by bounded Rust tasks, not the Flutter UI isolate.
pub async fn start_clipboard_runtime(
    certificate: String,
    private_key: String,
    port: u16,
    peers: Vec<RsClipboardPeer>,
    sync_images: bool,
) -> anyhow::Result<RsClipboardRuntime> {
    let peers = peers
        .into_iter()
        .map(|peer| {
            Ok(PeerConfig {
                identity: peer.fingerprint,
                address: peer.address.parse::<SocketAddr>()?,
                send: peer.send,
                receive: peer.receive,
            })
        })
        .collect::<anyhow::Result<Vec<_>>>()?;
    let inner = Runtime::start_with_images(
        certificate,
        private_key,
        SocketAddr::from(([0, 0, 0, 0], port)),
        peers,
        sync_images,
    )
    .await?;
    Ok(RsClipboardRuntime { inner })
}

impl RsClipboardRuntime {
    pub async fn should_apply_image(&self, image_png: Vec<u8>) -> bool {
        if image_png.len() > localsend::clipboard::engine::MAX_IMAGE_BYTES {
            return false;
        }
        self.inner
            .should_apply_image(&base64::engine::general_purpose::STANDARD.encode(image_png))
    }
    pub async fn capture_image(&self, image_png: Vec<u8>) -> anyhow::Result<()> {
        anyhow::ensure!(
            image_png.len() <= localsend::clipboard::engine::MAX_IMAGE_BYTES,
            "Clipboard image exceeds limit"
        );
        self.inner
            .capture_image(base64::engine::general_purpose::STANDARD.encode(image_png))
    }
    pub async fn should_apply(&self, text: String) -> bool {
        self.inner.should_apply(&text)
    }
    pub async fn capture_text(&self, text: Option<String>) -> anyhow::Result<()> {
        self.inner.capture(text)
    }

    pub async fn next_update(&self, after: u64) -> Option<RsClipboardUpdate> {
        self.inner
            .next_update(after)
            .await
            .map(|update| RsClipboardUpdate {
                revision: update.revision,
                connected: update.connected as u32,
                connected_peers: update.connected_peers,
                text: update.text,
                origin: update.origin,
                image_png: update
                    .image_png
                    .and_then(|image| base64::engine::general_purpose::STANDARD.decode(image).ok()),
                error: update.error,
            })
    }

    pub async fn stop(&self) {
        self.inner.stop().await;
    }
}

pub struct RsPairingUpdate {
    pub revision: u64,
    pub phase: String,
    pub code: String,
    pub fingerprint: String,
    pub address: String,
    pub name: String,
    pub expires: u64,
}

#[flutter_rust_bridge::frb(opaque)]
pub struct RsClipboardPairing {
    inner: localsend::clipboard::pairing::Session,
}

pub async fn host_clipboard_pairing(
    certificate: String,
    private_key: String,
    port: u16,
    addresses: Vec<String>,
    name: String,
    clipboard_port: u16,
) -> anyhow::Result<RsClipboardPairing> {
    Ok(RsClipboardPairing {
        inner: localsend::clipboard::pairing::Session::host(
            certificate,
            private_key,
            SocketAddr::from(([0, 0, 0, 0], port)),
            addresses,
            name,
            clipboard_port,
        )
        .await?,
    })
}

pub async fn join_clipboard_pairing(
    certificate: String,
    private_key: String,
    invitation: Option<String>,
    address: Option<String>,
    name: String,
    clipboard_port: u16,
) -> anyhow::Result<RsClipboardPairing> {
    let address = address.map(|a| a.parse::<SocketAddr>()).transpose()?;
    Ok(RsClipboardPairing {
        inner: localsend::clipboard::pairing::Session::join(
            certificate,
            private_key,
            invitation,
            address,
            name,
            clipboard_port,
        )
        .await?,
    })
}

impl RsClipboardPairing {
    pub async fn invitation(&self) -> Option<String> {
        self.inner.invitation()
    }
    pub async fn approve(&self, approved: bool) -> anyhow::Result<()> {
        self.inner.approve(approved)
    }
    pub async fn persisted(&self, saved: bool) -> anyhow::Result<()> {
        self.inner.persisted(saved)
    }
    pub async fn next_update(&self, after: u64) -> Option<RsPairingUpdate> {
        self.inner
            .next_update(after)
            .await
            .map(|u| RsPairingUpdate {
                revision: u.revision,
                phase: u.phase,
                code: u.code,
                fingerprint: u.fingerprint,
                address: u.address,
                name: u.name,
                expires: u.expires,
            })
    }
    pub async fn stop(&self) {
        self.inner.stop().await;
    }
}
