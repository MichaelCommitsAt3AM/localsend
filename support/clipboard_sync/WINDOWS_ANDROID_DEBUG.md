# Windows–Android direct LAN development build

This is the first integrated development slice, not the complete production
feature described in the roadmap. Linux and the hosted relay are not implemented.

## Implemented path

- Separate clipboard certificate identity protected by per-user Windows DPAPI
  or Android Keystore AES-GCM. Android ciphertext is an atomic file in
  `noBackupFilesDir`. Lost/corrupt secure storage fails closed and is not silently
  replaced. Ordinary LocalSend certificates/settings are not clipboard trust.
- Reciprocal QR or nearby pairing through a temporary TLS 1.3 enrollment
  channel, with an eight-digit TLS-exporter comparison and approval on both
  devices. QR pins the host certificate and carries a one-use random invitation.
  Manual fingerprint exchange remains an advanced fallback. Favorites grant no access.
- TLS 1.3 only, exact client/server certificate pins, handshake signature
  verification, clipboard-specific ALPN, no tickets, resumption or early data.
- Independent direct TCP listener on port 53318 for this development slice.
  It does not change existing HTTP routes or file-transfer sessions. Moving the
  ordered channel onto the planned additive HTTPS upgrade remains follow-up work.
- One shared Rust state machine: 8 peers maximum, 64 KiB text maximum, Lamport
  ordering with fingerprint tie-break, replay frontier, 5-minute RAM retention,
  no startup clipboard snapshot, no transitive forwarding and no clipboard logs.
- Optional copied-image synchronization, disabled by default. Enable Synchronize
  copied images on both devices. Native codecs normalize static images to PNG,
  stripping source metadata, with an 8 MiB encoded / 16-megapixel decoded limit
  and a 16384-pixel limit per dimension. Text/image events share one ordering
  frontier, so delayed image work cannot overwrite a later clipboard value.
  Clipboard TLS ALPN is now `localsend-clipboard/2`; update both apps together.
  The same image option now also watches newly saved Android screenshots in
  DCIM/Screenshots and Pictures/Screenshots, with full photo access. It baselines
  existing MediaStore IDs each start, waits for published/nonempty files,
  filters fresh screenshot names/album metadata, coalesces provider notifications,
  and never writes screenshots into Android's system clipboard. Stop/image opt-out
  unregisters the watcher and cancels pending work. Photo-access loss is reported
  on the page and ongoing notification; authorizing access restarts the baseline.
  Existing paired identities remain valid. Peers exchange an authenticated image
  capability flag; images are not sent to peers with the option disabled.
- Bounded latest-value watch channels, framed input allocation limits, handshake
  and I/O timeouts, connection limits, heartbeats and reconnect backoff/jitter.
- Windows clipboard listener attached to the existing runner window. Changes
  are coalesced; clipboard contention retries are bounded. Receive writes carry
  an ephemeral origin marker and OS-history exclusion; stale native sequences
  reject a queued write after a local copy.
- Android ordinary connected-device foreground service plus isolated shell-only
  Shizuku UserService, API 33–36 adapters. The service retains the existing Flutter
  engine when its Activity is closed. No keys/networking live in the helper.
  New clips marked sensitive are suppressed; received clips carry sensitive and
  ephemeral-origin flags to suppress their native callback echo.

## Build and launch

From `app/`, using the repository-pinned FVM SDK:

```powershell
fvm flutter build windows --debug
fvm flutter build apk --debug --target-platform android-arm64
```

Windows executable: `app/build/windows/x64/runner/Debug/localsend_app.exe`.
Distribute its complete Debug directory, including DLLs and data, not just the EXE.

Android APK: `app/build/app/outputs/flutter-apk/app-debug.apk`.
The existing debug suffix makes its package `org.localsend.localsend_app.debug`.
Its Activity is `org.localsend.localsend_app.MainActivity`.

## Pair and test

1. Put both devices on the same reachable LAN. If Windows prompts, allow this
   debug executable on the intended private network. Direct access requires
   TCP 53318; isolated/guest Wi-Fi may prevent it.
2. Open Settings > Clipboard sync on each device. On Android use the More
   menu > Android permissions; authorize the new LocalSend package and notifications.
   If setup needs attention, the page also offers Set up access.
3. Open Add device on Windows. On Android open Add device, choose Scan QR code,
   allow the camera when prompted, and scan the Windows QR. Compare the eight-digit
   code on both screens and approve on both. Both should show Device paired.
   Alternatively, open Add device on both and select the other nearby device.
   Manual public-code exchange is available under More > Manual pairing.
4. Turn on Share clipboard on both devices. Confirm one connected peer on each.
5. Copy a harmless distinctive marker on Android in another app. Paste on
   Windows; then use a different marker on Windows and paste on Android.
6. Repeat with Windows hidden to tray and Android task dismissed. Copying an
   identical value can be suppressed; change the value for fresh-event checks.
7. Test Stop, revocation, reconnection, lock/unlock, size boundaries and ordinary
   LocalSend transfers. Never use secrets or real credentials as test fixtures.

## Copied image testing

Enable Synchronize copied images on both devices, keeping clipboard sync enabled.
On Windows copy a harmless screenshot using Snipping Tool, then paste in an
Android app supporting image paste. On Android use an app's explicit Copy image
action, then paste in Windows Paint. Taking a screenshot on Android may only
save it to the gallery. With full photo access, the same image option also shares
fresh screenshots automatically from the two standard screenshot albums; an
explicit Copy action is unnecessary. Use More > Android permissions
on Android and grant full access. Selected-photo access cannot read future
screenshots. Older screenshots, imports with old capture times, camera photos,
downloaded files outside the screenshot albums and unfinished saves are skipped.
Custom screenshot storage locations are not yet recognized by this watcher.
Changing the option restarts the sync connection without removing pairing.

Windows captures registered PNG or 24/32-bit CF_DIB/CF_DIBV5 formats and receives
both registered PNG and CF_DIBV5 for paste compatibility. Decoding/encoding uses
WIC on one background worker. Native sequence checks reject stale work.
Android captures single-item image content URIs through the shell adapter and
passes only a file descriptor through Binder (not a large byte array). The
ordinary app decodes PNG/JPEG/WebP under bounds on a bounded background queue.
Source-provider restrictions can prevent capture; access errors skip the image
and do not transfer its URI as text. Received images use a private, narrowly
scoped FileProvider cache and Android's temporary clipboard URI grants. Only the
current received image is retained, for up to five minutes; Stop removes it.
They are marked sensitive and with an ephemeral origin to prevent echo.

Verify both directions, alpha transparency, image opt-out with text still working,
switching between text and images, rapid copies during decode, Stop cleanup,
and foreground/background paste. Images exceeding either limit are skipped;
there is no automatic quality reduction, file sync, or clipboard history.

## Failure behavior and remaining work

- Pairing uses saved IPs; DHCP changes require re-pairing in this slice. There is
  no clipboard-capability discovery extension or certificate rotation UI yet.
  Nearby pairing uses existing LocalSend discovery as a candidate list; it does
  not grant trust, prove clipboard support, or automatically refresh saved addresses.
- Enrollment listens on TCP 53319 only while Add device is open, for three
  minutes. Up to four initial handshakes and 24 attempts are allowed per session;
  one valid request claims it. Approval and protected-storage acknowledgements
  are required from both endpoints. Pending trust is never passed to the text
  runtime. Interrupted pairing must be removed/retried, rather than auto-approved.
  Names are display hints; compare the code even if the name looks familiar.
- QR decoding uses bundled offline Apache-licensed ZXing, without Google Play
  Services. Camera access is only requested when scanning and released by the
  private portrait scanner Activity when it closes. Windows displays QR codes;
  it has no camera scanner.
- QR codes now contain an HTTPS link on `localsend.currenta.tech`, with credentials
  in the URL fragment. Android's verified App Link opens the pairing route on
  cold/warm VIEW intents; the fallback website offers a custom-scheme Open app
  button. Both devices still approve before trust is committed. The association
  file currently covers the installed debug signer, not a production release.
  See `app_link_site/README.md` for deployment and release-signing requirements.
- The page shows saved devices as individual cards, with a green dot for each
  live connection. Pairing alone does not turn on clipboard sharing, so no dots
  while synchronization is disabled is expected.
- The enrollment protocol uses the RFC 9266 TLS-exporter channel binding, with
  its result reduced to an eight-digit comparison. This use is covered by local
  tests but has not received independent protocol review. QR invitations are
  temporary bearer credentials; do not publish screenshots of an active invitation.
- Clearing, multiple items, rich text, unsupported images and sensitive-marked
  clips are skipped, and clear retained content. Supported images require opt-in.
  A clipboard is not automatically cleared
  on the peer in this version. Unmarked text can still contain secrets.
- Delivery is best effort/latest value, not exactly once. Writes superseded before
  applying are dropped. Native clipboard writes are not globally atomic with
  competing apps; simultaneous-copy/lifecycle races still need physical testing.
- A failed OS write is visible in status; application-level receipt/retry and
  acknowledgement semantics need further hardening before a production release.
- Android connected-device service is for explicit local paired-device exchange.
  This does not establish hosted-mode service eligibility or store policy approval.
  No boot-start promise, wake lock, battery exemption or Doze bypass is included.
- Shizuku loss is surfaced; the active ordinary service waits for a new Shizuku
  Binder and rebinds the helper. Unsupported signatures fail closed. Revocation
  may stop the whole app; restoring access and reopening it remains explicit.
- Public UI labels are localized through Slang's English fallback; operational
  error messages still need translation. Extended device/version coverage,
  shared-engine lifetime, soak/battery/security review and adapter race tests
  remain gates. Debug builds are not production-readiness evidence.
- The upstream Cargokit Windows symlink helper now uses PowerShell `-NoProfile`
  so a profile warning cannot corrupt its resolved build path.

## References

- [Android connected-device foreground service](https://developer.android.com/develop/background-work/services/fgs/service-types#connected-device)
- [Android Keystore](https://developer.android.com/privacy-and-security/keystore)
- [Windows DPAPI](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata)
- [Windows clipboard history formats](https://learn.microsoft.com/en-us/windows/win32/dataxchg/clipboard-formats)
- [TLS 1.3 channel bindings, RFC 9266](https://www.rfc-editor.org/rfc/rfc9266.html)
- [ZXing Android Embedded](https://github.com/journeyapps/zxing-android-embedded)

Shizuku's MIT notice is included as an APK asset. The helper is derived from our
separately tested feasibility source, not copied from a third-party sync app.

## Clipboard settings layout

The main page shows the sharing and image switches, a separate simple card for
each paired device and Add device. A green dot beside a device name means it is
connected. Select a device to change its send or receive permission, view its technical identity/address or remove it with
confirmation. The More menu contains manual pairing, connection counters,
Android permissions and Setup tutorial. On the first Android enable, a bottom
sheet explains the Shizuku prerequisite and links to the same tutorial. The
tutorial covers official installation/startup, permissions, QR pairing and
sharing. Successful enable is remembered in protected clipboard settings;
existing enabled installations skip onboarding. How it works explains setup,
privacy and current limits; development details are collapsed. Dots use
authenticated per-device runtime sessions and disappear on disconnect or stop. The ongoing Android notification lists only connected device names
and their count; disconnected paired devices are omitted.
