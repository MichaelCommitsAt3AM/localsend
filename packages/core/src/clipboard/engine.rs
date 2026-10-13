use serde::{Deserialize, Serialize};
use std::{collections::BTreeMap, fmt, time::Instant};

pub const MAX_TEXT_BYTES: usize = 65_536;
pub const MAX_IMAGE_BYTES: usize = 8 * 1024 * 1024;
pub const MAX_IMAGE_BASE64: usize = MAX_IMAGE_BYTES.div_ceil(3) * 4;
pub const MAX_IMAGE_PIXELS: u64 = 16_000_000;

/// Decode under explicit pixel/allocation limits. Native encoders strip metadata.
pub fn validate_png(encoded: &str) -> Result<(), EngineError> {
    use base64::Engine as _;
    if encoded.len() > MAX_IMAGE_BASE64 {
        return Err(EngineError::Oversize);
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .map_err(|_| EngineError::InvalidEvent)?;
    if bytes.is_empty() || bytes.len() > MAX_IMAGE_BYTES {
        return Err(EngineError::Oversize);
    }
    let decoder = png::Decoder::new_with_limits(
        std::io::Cursor::new(bytes),
        png::Limits {
            bytes: 80 * 1024 * 1024,
        },
    );
    let mut reader = decoder.read_info().map_err(|_| EngineError::InvalidEvent)?;
    let info = reader.info();
    if info.width == 0
        || info.height == 0
        || u64::from(info.width) * u64::from(info.height) > MAX_IMAGE_PIXELS
        || info.width > 16384
        || info.height > 16384
        || info.bit_depth != png::BitDepth::Eight
        || !matches!(info.color_type, png::ColorType::Rgb | png::ColorType::Rgba)
        || info.animation_control.is_some()
    {
        return Err(EngineError::InvalidEvent);
    }
    let size = reader
        .output_buffer_size()
        .filter(|n| *n <= 64_000_000)
        .ok_or(EngineError::Oversize)?;
    reader
        .next_frame(&mut vec![0; size])
        .map_err(|_| EngineError::InvalidEvent)?;
    reader.finish().map_err(|_| EngineError::InvalidEvent)?;
    Ok(())
}

#[cfg(test)]
pub(crate) fn image_fixture(value: u8) -> String {
    use base64::Engine as _;
    let mut bytes = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut bytes, 2, 2);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder.write_header().unwrap();
        writer.write_image_data(&[value; 16]).unwrap();
    }
    base64::engine::general_purpose::STANDARD.encode(bytes)
}
pub const MAX_PEERS: usize = 8;
pub const RETENTION_MS: u64 = 300_000;
pub const CLOCK_SKEW_MS: u64 = 30_000;

/// The fingerprint of a separate clipboard certificate, never a display name.
pub fn valid_identity(identity: &str) -> bool {
    identity.len() == 64
        && identity
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'A'..=b'F').contains(&b))
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ClipboardEvent {
    pub version: u8,
    pub origin: String,
    pub clock: u64,
    pub created_ms: u64,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_png: Option<String>,
}

// Neither plaintext nor content fingerprints belong in diagnostics.
impl fmt::Debug for ClipboardEvent {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ClipboardEvent")
            .field("version", &self.version)
            .field("clock", &self.clock)
            .finish_non_exhaustive()
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Directions {
    pub send: bool,
    pub receive: bool,
}

#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum EngineError {
    #[error("Clipboard synchronization is disabled")]
    Disabled,
    #[error("Invalid clipboard identity")]
    Identity,
    #[error("Clipboard peer limit reached")]
    PeerLimit,
    #[error("Peer is not authorized for this direction")]
    Unauthorized,
    #[error("Unsupported or invalid clipboard event")]
    InvalidEvent,
    #[error("Clipboard content exceeds its size limit")]
    Oversize,
    #[error("Clipboard event has expired or its clock is too far ahead")]
    Expired,
    #[error("Clipboard sequence counter exhausted")]
    ClockExhausted,
}

struct Peer {
    directions: Directions,
    last_clock: u64,
}

/// Called serially by a single owner. Apply returned writes before processing
/// the next capture: OS writes and capture events must share the adapter queue.
/// Native write callbacks containing identical text are suppressed here.
pub struct Engine {
    identity: String,
    enabled: bool,
    clock: u64,
    peers: BTreeMap<String, Peer>,
    frontier: (u64, String),
    latest: Option<(ClipboardEvent, Instant)>,
    images: bool,
}

impl Engine {
    pub fn new(identity: String) -> Result<Self, EngineError> {
        if !valid_identity(&identity) {
            return Err(EngineError::Identity);
        }
        Ok(Self {
            identity,
            enabled: false,
            clock: 0,
            peers: BTreeMap::new(),
            frontier: (0, String::new()),
            latest: None,
            images: false,
        })
    }

    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
        // No startup snapshot, queued value or data from a previous enabled period.
        self.latest = None;
    }
    pub fn set_images(&mut self, enabled: bool) {
        self.images = enabled;
        self.discard_content();
    }
    pub fn images_enabled(&self) -> bool {
        self.images
    }

    pub fn trust(&mut self, identity: String, directions: Directions) -> Result<(), EngineError> {
        if !valid_identity(&identity) || identity == self.identity {
            return Err(EngineError::Identity);
        }
        if !self.peers.contains_key(&identity) && self.peers.len() == MAX_PEERS {
            return Err(EngineError::PeerLimit);
        }
        self.peers
            .entry(identity)
            .and_modify(|peer| peer.directions = directions)
            .or_insert(Peer {
                directions,
                last_clock: 0,
            });
        Ok(())
    }

    pub fn revoke(&mut self, identity: &str) {
        self.peers.remove(identity);
        if self
            .latest
            .as_ref()
            .is_some_and(|(event, _)| event.origin == identity)
        {
            self.latest = None;
        }
    }

    pub fn discard_content(&mut self) {
        self.latest = None;
    }

    /// Reconnection exchanges only ordering metadata over authenticated TLS.
    /// A restarted peer learns the surviving owner's clock before sending text.
    pub fn observe_clock(&mut self, peer_clock: u64, now: Instant) -> Result<(), EngineError> {
        if peer_clock == u64::MAX {
            return Err(EngineError::ClockExhausted);
        }
        self.clock = self.clock.max(peer_clock);
        self.expire(now);
        if let Some((event, _)) = &mut self.latest {
            if event.origin == self.identity && event.clock <= peer_clock {
                self.clock = self
                    .clock
                    .checked_add(1)
                    .ok_or(EngineError::ClockExhausted)?;
                event.clock = self.clock;
                self.frontier = (event.clock, event.origin.clone());
            }
        }
        Ok(())
    }

    pub fn clock(&self) -> u64 {
        self.clock
    }

    /// Returns true only for a new supported, non-sensitive local capture.
    /// Unsupported, empty or sensitive captures call discard_content instead.
    pub fn capture(
        &mut self,
        text: String,
        wall_ms: u64,
        now: Instant,
    ) -> Result<bool, EngineError> {
        self.capture_content(text, None, wall_ms, now)
    }
    pub fn capture_image(
        &mut self,
        image: String,
        wall_ms: u64,
        now: Instant,
    ) -> Result<bool, EngineError> {
        if !self.images {
            self.discard_content();
            return Err(EngineError::Unauthorized);
        }
        if let Err(error) = validate_png(&image) {
            self.discard_content();
            return Err(error);
        }
        self.capture_content(String::new(), Some(image), wall_ms, now)
    }
    fn capture_content(
        &mut self,
        text: String,
        image_png: Option<String>,
        wall_ms: u64,
        now: Instant,
    ) -> Result<bool, EngineError> {
        if !self.enabled {
            return Err(EngineError::Disabled);
        }
        if text.len() > MAX_TEXT_BYTES {
            self.discard_content();
            return Err(EngineError::Oversize);
        }
        if text.is_empty() && image_png.is_none() {
            self.discard_content();
            return Ok(false);
        }
        self.expire(now);
        if self
            .latest
            .as_ref()
            .is_some_and(|(event, _)| event.text == text && event.image_png == image_png)
        {
            return Ok(false);
        }
        self.clock = self
            .clock
            .checked_add(1)
            .ok_or(EngineError::ClockExhausted)?;
        let event = ClipboardEvent {
            version: if image_png.is_some() { 2 } else { 1 },
            origin: self.identity.clone(),
            clock: self.clock,
            created_ms: wall_ms,
            text,
            image_png,
        };
        self.frontier = (event.clock, event.origin.clone());
        self.latest = Some((event, now + std::time::Duration::from_millis(RETENTION_MS)));
        Ok(true)
    }

    /// Caller must supply the identity proven by the current TLS handshake.
    /// Claimed origin is checked independently, preventing transitive forwarding.
    pub fn receive(
        &mut self,
        authenticated_peer: &str,
        event: ClipboardEvent,
        wall_ms: u64,
        now: Instant,
    ) -> Result<bool, EngineError> {
        if !self.enabled {
            return Err(EngineError::Disabled);
        }
        let peer = self
            .peers
            .get_mut(authenticated_peer)
            .ok_or(EngineError::Unauthorized)?;
        if !peer.directions.receive || event.origin != authenticated_peer {
            return Err(EngineError::Unauthorized);
        }
        if !matches!(
            (
                event.version,
                event.image_png.is_some(),
                event.text.is_empty()
            ),
            (1, false, false) | (2, true, true)
        ) || event.clock == 0
            || event.clock == u64::MAX
        {
            return Err(EngineError::InvalidEvent);
        }
        if event.text.len() > MAX_TEXT_BYTES {
            return Err(EngineError::Oversize);
        }
        if let Some(image) = &event.image_png {
            if !self.images {
                return Err(EngineError::Unauthorized);
            }
            validate_png(image)?;
        }
        if event.created_ms > wall_ms.saturating_add(CLOCK_SKEW_MS)
            || wall_ms.saturating_sub(event.created_ms) > RETENTION_MS
        {
            return Err(EngineError::Expired);
        }
        if event.clock <= peer.last_clock {
            return Ok(false);
        }
        peer.last_clock = event.clock;
        self.clock = self.clock.max(event.clock);
        let revision = (event.clock, event.origin.clone());
        if revision <= self.frontier {
            return Ok(false);
        }
        self.frontier = revision;
        let remaining = RETENTION_MS.saturating_sub(wall_ms.saturating_sub(event.created_ms));
        // Instant expiry preserves the original remaining lifetime across reconnects.
        let expires = now + std::time::Duration::from_millis(remaining);
        self.latest = Some((event, expires));
        Ok(true)
    }

    /// Only a locally originated value may be sent. Remote values never fan out.
    pub fn outbound(&mut self, peer: &str, now: Instant) -> Option<ClipboardEvent> {
        if !self.enabled || !self.peers.get(peer)?.directions.send {
            return None;
        }
        self.expire(now);
        let (event, _) = self.latest.as_ref()?;
        (event.origin == self.identity).then(|| event.clone())
    }

    pub fn latest_text(&mut self, now: Instant) -> Option<&str> {
        self.expire(now);
        self.latest
            .as_ref()
            .filter(|(event, _)| event.image_png.is_none())
            .map(|(event, _)| event.text.as_str())
    }
    pub fn latest_image(&mut self, now: Instant) -> Option<&str> {
        self.expire(now);
        self.latest
            .as_ref()
            .and_then(|(event, _)| event.image_png.as_deref())
    }
    pub fn has_content(&mut self, now: Instant) -> bool {
        self.expire(now);
        self.latest.is_some()
    }

    pub fn expire(&mut self, now: Instant) {
        if self
            .latest
            .as_ref()
            .is_some_and(|(_, expires)| now >= *expires)
        {
            self.latest = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    #[test]
    fn images_require_opt_in_and_preserve_text_image_order_echo_and_ttl() {
        let now = Instant::now();
        let mut a = engine(1, &[2]);
        let mut b = engine(2, &[1]);
        let image = image_fixture(127);
        assert_eq!(
            a.capture_image(image.clone(), 1000, now),
            Err(EngineError::Unauthorized)
        );
        a.set_images(true);
        b.set_images(true);
        assert!(a.capture_image(image.clone(), 1000, now).unwrap());
        let event = a.outbound(&id(2), now).unwrap();
        assert!(!format!("{event:?}").contains(&image));
        assert!(b.receive(&id(1), event.clone(), 1000, now).unwrap());
        assert_eq!(b.latest_image(now), Some(image.as_str()));
        assert_eq!(b.latest_text(now), None);
        assert!(!b.capture_image(image.clone(), 1000, now).unwrap());
        assert!(b.outbound(&id(1), now).is_none());
        assert!(b.capture("new text".into(), 1001, now).unwrap());
        assert!(!b.receive(&id(1), event, 1001, now).unwrap());
        assert_eq!(b.latest_image(now), None);
        assert!(a
            .latest_image(now + Duration::from_millis(RETENTION_MS))
            .is_none());
    }
    #[test]
    fn malformed_mixed_oversized_and_disabled_images_are_rejected() {
        let now = Instant::now();
        let mut a = engine(1, &[2]);
        a.set_images(true);
        assert!(a.capture_image("bad png".into(), 1000, now).is_err());
        assert_eq!(
            a.capture_image("A".repeat(MAX_IMAGE_BASE64 + 1), 1000, now),
            Err(EngineError::Oversize)
        );
        let mut bad = event(2, 1, "text");
        bad.version = 2;
        bad.image_png = Some(image_fixture(0));
        assert_eq!(
            a.receive(&id(2), bad, 1000, now),
            Err(EngineError::InvalidEvent)
        );
        let mut incoming = event(2, 2, "");
        incoming.version = 2;
        incoming.image_png = Some(image_fixture(0));
        a.set_images(false);
        assert_eq!(
            a.receive(&id(2), incoming, 1000, now),
            Err(EngineError::Unauthorized)
        );
    }
    fn id(n: u8) -> String {
        format!("{n:064X}")
    }
    fn engine(n: u8, peers: &[u8]) -> Engine {
        let mut e = Engine::new(id(n)).unwrap();
        for peer in peers {
            e.trust(
                id(*peer),
                Directions {
                    send: true,
                    receive: true,
                },
            )
            .unwrap();
        }
        e.set_enabled(true);
        e
    }
    fn event(n: u8, clock: u64, text: &str) -> ClipboardEvent {
        ClipboardEvent {
            version: 1,
            origin: id(n),
            clock,
            created_ms: 1_000,
            text: text.into(),
            image_png: None,
        }
    }
    #[test]
    fn disabled_and_no_startup_broadcast() {
        let mut e = Engine::new(id(1)).unwrap();
        let now = Instant::now();
        assert_eq!(
            e.capture("private".into(), 1_000, now),
            Err(EngineError::Disabled)
        );
        e.trust(
            id(2),
            Directions {
                send: true,
                receive: true,
            },
        )
        .unwrap();
        e.set_enabled(true);
        assert!(e.outbound(&id(2), now).is_none());
    }
    #[test]
    fn remote_write_echo_does_not_fan_out() {
        let now = Instant::now();
        let mut b = engine(2, &[1, 3]);
        assert!(b
            .receive(&id(1), event(1, 1, "marker"), 1_000, now)
            .unwrap());
        assert!(!b.capture("marker".into(), 1_001, now).unwrap());
        assert!(b.outbound(&id(3), now).is_none());
        assert!(b.capture("new local value".into(), 1_002, now).unwrap());
        assert_eq!(b.outbound(&id(3), now).unwrap().clock, 2);
    }
    #[test]
    fn replay_and_stale_events_do_not_overwrite() {
        let now = Instant::now();
        let mut b = engine(2, &[1]);
        assert!(b.receive(&id(1), event(1, 3, "new"), 1_000, now).unwrap());
        assert!(!b
            .receive(&id(1), event(1, 3, "replay"), 1_000, now)
            .unwrap());
        assert!(!b.receive(&id(1), event(1, 2, "old"), 1_000, now).unwrap());
        assert_eq!(b.latest_text(now), Some("new"));
    }
    #[test]
    fn forged_origin_and_untrusted_peer_are_rejected() {
        let now = Instant::now();
        let mut b = engine(2, &[1]);
        assert_eq!(
            b.receive(&id(1), event(3, 1, "forged"), 1_000, now),
            Err(EngineError::Unauthorized)
        );
        assert_eq!(
            b.receive(&id(3), event(3, 1, "untrusted"), 1_000, now),
            Err(EngineError::Unauthorized)
        );
        assert!(b.latest_text(now).is_none());
    }
    #[test]
    fn tie_break_converges_regardless_of_arrival_order() {
        let now = Instant::now();
        let mut a = engine(1, &[2, 3]);
        let mut b = engine(4, &[2, 3]);
        a.receive(&id(2), event(2, 5, "two"), 1_000, now).unwrap();
        a.receive(&id(3), event(3, 5, "three"), 1_000, now).unwrap();
        b.receive(&id(3), event(3, 5, "three"), 1_000, now).unwrap();
        assert!(!b.receive(&id(2), event(2, 5, "two"), 1_000, now).unwrap());
        assert_eq!(a.latest_text(now), b.latest_text(now));
    }
    #[test]
    fn permissions_apply_in_both_directions() {
        let now = Instant::now();
        let mut e = engine(1, &[2]);
        e.trust(
            id(2),
            Directions {
                send: false,
                receive: false,
            },
        )
        .unwrap();
        e.capture("local".into(), 1_000, now).unwrap();
        assert!(e.outbound(&id(2), now).is_none());
        assert_eq!(
            e.receive(&id(2), event(2, 2, "remote"), 1_000, now),
            Err(EngineError::Unauthorized)
        );
    }
    #[test]
    fn expiry_removes_payload_but_preserves_replay_frontier() {
        let now = Instant::now();
        let mut e = engine(2, &[1]);
        e.receive(&id(1), event(1, 1, "remote"), 1_000, now)
            .unwrap();
        let later = now + Duration::from_millis(RETENTION_MS);
        assert!(e.latest_text(later).is_none());
        assert!(!e
            .receive(&id(1), event(1, 1, "replay"), 1_000, later)
            .unwrap());
    }
    #[test]
    fn buffered_remote_event_does_not_get_a_new_full_lifetime() {
        let now = Instant::now();
        let mut e = engine(2, &[1]);
        e.receive(
            &id(1),
            event(1, 1, "remote"),
            1_000 + RETENTION_MS - 10,
            now,
        )
        .unwrap();
        assert!(e.latest_text(now + Duration::from_millis(10)).is_none());
    }
    #[test]
    fn future_expired_and_overflow_events_are_rejected() {
        let now = Instant::now();
        let mut e = engine(2, &[1]);
        assert_eq!(
            e.receive(&id(1), event(1, 1, "expired"), RETENTION_MS + 1_001, now),
            Err(EngineError::Expired)
        );
        let mut future = event(1, 1, "future");
        future.created_ms = CLOCK_SKEW_MS + 1;
        assert_eq!(e.receive(&id(1), future, 0, now), Err(EngineError::Expired));
        assert_eq!(
            e.receive(&id(1), event(1, u64::MAX, "overflow"), 1_000, now),
            Err(EngineError::InvalidEvent)
        );
    }
    #[test]
    fn utf8_limit_and_sensitive_capture_clear_old_outbound_value() {
        let now = Instant::now();
        let mut e = engine(1, &[2]);
        e.capture("a".repeat(MAX_TEXT_BYTES), 1_000, now).unwrap();
        assert!(e.outbound(&id(2), now).is_some());
        assert_eq!(
            e.capture("é".repeat(MAX_TEXT_BYTES / 2 + 1), 1_001, now),
            Err(EngineError::Oversize)
        );
        assert!(e.outbound(&id(2), now).is_none());
        e.capture("other".into(), 1_002, now).unwrap();
        e.discard_content();
        assert!(e.outbound(&id(2), now).is_none());
    }
    #[test]
    fn revoke_disable_and_reenable_discard_content() {
        let now = Instant::now();
        let mut e = engine(2, &[1]);
        e.receive(&id(1), event(1, 1, "remote"), 1_000, now)
            .unwrap();
        e.revoke(&id(1));
        assert!(e.latest_text(now).is_none());
        e.capture("local".into(), 1_000, now).unwrap();
        e.set_enabled(false);
        e.set_enabled(true);
        assert!(e.latest_text(now).is_none());
    }
    #[test]
    fn trust_is_bounded_and_self_trust_is_rejected() {
        let mut e = engine(1, &[]);
        let d = Directions {
            send: true,
            receive: true,
        };
        assert_eq!(e.trust(id(1), d), Err(EngineError::Identity));
        for n in 2..=9 {
            e.trust(id(n), d).unwrap();
        }
        assert_eq!(e.trust(id(10), d), Err(EngineError::PeerLimit));
        e.trust(id(2), d).unwrap();
        e.revoke(&id(2));
        e.trust(id(10), d).unwrap();
    }
    #[test]
    fn serialized_event_rejects_unknown_fields_and_debug_redacts_text() {
        let value = event(1, 1, "do-not-log-this");
        assert!(!format!("{value:?}").contains("do-not-log-this"));
        let mut json = serde_json::to_value(value).unwrap();
        json["extra"] = true.into();
        assert!(serde_json::from_value::<ClipboardEvent>(json).is_err());
    }
}
