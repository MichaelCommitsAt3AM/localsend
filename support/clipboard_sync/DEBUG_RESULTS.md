# Integrated Windows and Android debug validation

Recorded 2026-10-13. This record covers the direct LAN development slice;
it does not establish production readiness or relay/Linux support.

## Automated checks

- Flutter analysis: no issues found.
- Clipboard provider tests: 6 passed, including disabling while an enable
  operation waits for the native permission response.
- Rust clipboard tests: 24 passed after QR/nearby enrollment was added.
  Includes real TLS loopback delivery, certificate pin rejection, bounded
  framing, replay/TTL/echo handling, restart clock recovery and direction rules.
- Latest full core regression: 108 unit and 61 integration tests passed with
  one pre-existing Windows timestamp precision test skipped
  (`model::transfer::tests::formats_nanosecond_timestamp`).
- Latest full Flutter suite: 100 passed, including strict pairing-link decoding
  tests and two widget regressions for
  pairing-page startup and startup timeout/late-session cleanup.
- `git diff --check`: passed.
- Core `cargo clippy --features full`: completed with existing warnings in
  crypto, HTTP and WebRTC code; no clipboard-module warnings reported.

## Built artifacts

Pinned Flutter 3.41.9; debug builds completed successfully on Windows.

| Artifact | SHA-256 |
| --- | --- |
| `app/build/windows/x64/runner/Debug/localsend_app.exe` | `18FB7A809CEB4D5E996F0683091383B7E0F47C553C7C8DEB7689D51AF1E63345` |
| `app/build/windows/x64/runner/Debug/rust_lib_localsend_app.dll` | `6F9BEB9CD8F562F436396912E4AFFB5003B3BE5604A1374DB514B74B05A51E05` |
| `app/build/windows/x64/runner/Debug/data/flutter_assets/kernel_blob.bin` | `2B580A4CFC7C94250C54FC149F903263009D4D7251078EE15EF01DCBE1F371FE` |
| `app/build/app/outputs/flutter-apk/app-debug.apk` | `1E8AAFEE05D97EC9149D7E9B93EE8C8DFF80A14D8EC5C35A64E8D90B1F1214FA` |

The Windows executable requires its entire Debug directory. Android package:
`org.localsend.localsend_app.debug`.

Both builds were regenerated after adding QR/nearby pairing and correcting its
startup lifecycle issue. Flutter analysis passed again. The Windows EXE hash
covers the native runner only; Dart UI changes reside in its accompanying data.
The updated Windows app was relaunched; Android update installation succeeded
and its Activity was relaunched without clearing app data.

The latest builds also add a named-device confirmation before removing a peer.
Cancel or dismiss retains pairing; confirming removes only the selected identity
from the current peer list, preserving unrelated concurrent peer changes.

## Physical-device validation

- Windows debug executable launched and was responsive, window title LocalSend.
- The user supplied a screenshot of the clipboard page: disabled, no connected
  peers, public pairing code rendered, and no secure-storage error displayed.
- Windows DPAPI encrypted identity persisted across an earlier app restart;
  ciphertext file existed without a plaintext private-key label.
- Samsung Galaxy A35, Android 16 / API 36, connected through authorized wireless
  ADB. Integrated APK installation succeeded and its Activity was launched.
  Its app process was present, and a 2,945-byte private ciphertext identity file
  existed in its no-backup directory. No key or clipboard contents were read.
  User granted notifications and Shizuku access to the integrated debug package;
  both grants were independently confirmed in its package permission metadata.
  Before synchronization was enabled, Android recorded a LOW_MEMORY termination
  of the UI process. The user reopened it and supplied a fresh public pairing
  code with the same fingerprint and LAN address, confirming identity retention.
  This occurred before the clipboard foreground service was enabled and does not
  establish that service's behavior under memory pressure.
- Reciprocal pairing is user-confirmed. Actual Windows/Android clipboard delivery,
  shared-engine survival, reconnect and integrated Stop/revocation remain pending. The separate
  Android feasibility results are in `feasibility/RESULTS.md`; they do not prove
  the integrated two-device path.
- The user initially observed an indefinitely loading Add device screen on
  Windows. Startup accessed an inherited provider during `initState`, outside
  the error handler. Startup now runs after the first frame, gets the local name
  from the parent route, and has a ten-second timeout with late-session cleanup.
  Both startup/timeout widget regressions pass. The user subsequently confirmed
  the QR appeared and paired the real Windows/Android devices through it.
- Paired-device count is now separate from connected-device count; disabled sync
  has zero live connections. The user confirmed one paired device on both; actual
  text delivery still needs physical confirmation. The in-app Android scanner
  uses a private portrait Activity, also user-confirmed.

## HTTPS app-link deployment

- Cloudflare Pages project `localsend-clipboard-pairing` deployed its static
  fallback and association file. User added the subdomain CNAME after it was
  attached through the Pages custom-domain API. Existing CLI credentials were
  used without logging the OAuth token; they lacked DNS write permission.
- `localsend.currenta.tech` resolves publicly. Its HTTPS association response
  returned 200/application-json without a redirect, and matched the installed
  debug package and signing certificate. Google Digital Asset Links returned
  the expected association; Android `pm get-app-links` reported **verified**.
- A cold custom-scheme launch through Android VIEW reached Add device and rejected
  an expired test invitation, confirmed through own-app UI semantics. No new
  trust was created by this test.
- A scripted cold/warm HTTPS launch/back-navigation test was rejected by automatic
  approval review (reason supplied: blocked by policy); it was not rerun.
  The user subsequently confirmed that scanning through the normal Camera app
  opens LocalSend and pairs successfully, both devices display one saved paired
  device, and the in-app scanner opens in portrait. The exact cold/warm process
  state during that user test was not recorded, so both launch states are not
  independently claimed.
- Landing-page bounds/expiry/fallback tests passed. Credentials are in the URL
  fragment, not the request path/query. The site is static and is not a relay.

## Integrated synchronization session

Initial inspection after the user's enable report found no active TCP connection
and no Android clipboard service. The phone's UI showed an authorization-required
status with zero connected devices; stored notification and Shizuku permissions
were granted, but no Shizuku server process was running. The usual documented
external-storage startup script was absent, so the user started Shizuku through
their existing setup and enabled the phone again.

Subsequent inspection confirmed the real LAN TCP connection to the Windows
clipboard listener, the Android ClipboardSyncService record, Shizuku server UID
2000 and the integrated clipboard helper UID 2000. Actual text delivery and
background-lifetime checks were pending at that point.

The user subsequently copied the harmless Android-to-Windows fixture on the
phone in another app and reported that it pasted correctly in Windows Notepad.
An independent Windows clipboard equality check returned true for the expected
fixture, without printing clipboard contents or a hash. The LAN connection was
still established. This confirms one integrated phone-to-Windows delivery.
The user then copied the distinct Windows-to-Android fixture in Notepad and
reported that it pasted correctly in another Android app. Integrated delivery
has therefore passed in both directions in this short session.

The user subsequently reported that both fresh background markers pasted
correctly with Windows LocalSend in the system tray and Android LocalSend
swiped away from Recent apps (without force-stop). This supports integrated
bidirectional background delivery and retained Flutter-engine operation in
this short Windows/Galaxy A35 session. The screen/task states at each precise
copy instant were user-reported rather than independently sampled. Longer
soak, Doze, lock/unlock, reconnection and integrated Stop/revocation checks
remain pending; the result is not a production-readiness claim.

## Android notification device information

The ongoing clipboard notification now shows the saved paired-device count and
live connected-device count in its collapsed summary. Expanding it lists paired
device names, excluding incomplete pairing records. Names are bounded and control
characters removed; the notification receives no clipboard content, keys or
fingerprints. Updates are silent, deduplicated by metadata, and retain the Stop
action. Private notification visibility protects the names on the lock screen
according to Android's notification settings.

The updated Android debug APK was built, installed and launched on the Galaxy
A35. The user confirmed the notification works. A read-only inspection confirmed
the notification has summary and expanded text, and the Windows/Android LAN
connection remained established. Flutter analysis reported no issues; all six
existing clipboard provider tests passed; `git diff --check` passed.
APK SHA-256: `B9E8568CBB4619F83C6E675E0BC3B58035BC372044F5E1ECB8E3A697A564413D`.

Follow `WINDOWS_ANDROID_DEBUG.md` for explicit pairing and the test sequence.

## Later one-way synchronization diagnosis

During a later session the user reported that Windows-to-Android worked but
Android-to-Windows did not. Read-only inspection found an established LAN socket
and an Android foreground service, but no running Shizuku server or clipboard
helper. The surviving network connection and ordinary app clipboard writes do
not require the shell capture helper; background Android capture does.
After Shizuku was restarted, inspection confirmed both the Shizuku server and
LocalSend clipboard helper running as shell UID 2000 again. Actual renewed
Android-to-Windows delivery still needs the user's paste check.

The Android service now maintains a capture-availability warning in its ongoing
notification. The Flutter controller retains that warning across network updates
and remote clipboard writes, clearing it when the helper reconnects or a readable
clipboard callback restores access. This preserves automatic helper rebinding
and incoming clipboard delivery while explaining why outgoing Android copies
are paused. No system clipboard toast is modified.

The warning update passed Flutter analysis and the six existing provider tests,
and its Android debug APK was built, installed and launched over wireless ADB.
APK SHA-256: `E4AEFAA714EA1E962DAF842D8FADE970C7C6453320A95349504C365CB0509534`.
The new warning's full helper-loss/recovery cycle still needs device validation.

## Settings-page controller lifetime correction

The user then reported Windows controls greyed out, zero paired devices and a
default Disabled status. The settings page used Refena's ViewModelBuilder with
its default `disposeProvider: true`. Leaving the page disposed the application
clipboard controller, so reopening created an uninitialized controller while
the old asynchronous runtime could remain active. This was a UI/service lifetime
bug; the Windows encrypted configuration file remained present.

The page now uses `disposeProvider: false`. A widget regression test mounts,
removes and remounts the actual page, asserting one controller instance,
unchanged ready/paired/connected state, and an enabled switch. It passed. The
Windows debug build completed and was restarted; its new process again owns
the established clipboard connection, supporting successful saved-config load.
The Android debug build also completed with the same lifecycle correction.
It was installed and launched; the shell clipboard helper was confirmed running
again. APK SHA-256:
`74EA96222D7E95B3B7548B7B317B79221488C06B7D1AAF15A6A8C87D606AC6AB`.

## Optional copied-image synchronization

Added the persisted Synchronize copied images option, defaulting off for existing
and new configurations. Both peers must opt in. Images and text share one Rust
ordering/replay/TTL frontier and direction authorization. TLS ALPN `/2` introduces
an authenticated capability exchange; old debug apps require updating together,
but saved pairing identities remain valid. Wire PNG payloads are limited to
8 MiB, fully decoded under allocation/dimension limits, static 8-bit RGB/RGBA,
16 megapixels and 16384 pixels per dimension. Native encoders strip metadata.
Image byte/base64 conversion runs in Rust rather than the Flutter UI isolate.

Windows captures PNG/DIB/DIBV5 and writes PNG plus DIBV5, with WIC codecs on one
worker, native-sequence checks, own-origin and OS-history exclusions. Android
captures image content URIs using the shell helper's temporary URI access and
passes file descriptors through Binder. A bounded ordinary-app worker decodes
PNG/JPEG/WebP. Received images use a private FileProvider cache, one current
immutable PNG with five-minute expiry and Stop cleanup. Sensitive/own-origin
markers prevent capture echo. Source-provider access failures are nonfatal;
unsupported or oversized images are skipped. Asynchronous native captures are
invalidated by newer local copies or remote writes. Android Stop waits for actual
service destruction before reconfiguring the image preference.

Validation: all 102 Flutter tests, 112 core unit tests and 61 core integration
tests passed (the previously known Windows nanosecond timestamp unit test remains
explicitly skipped). The 28 clipboard tests include image ordering/TTL/echo,
opt-in/malformed/bounds and TLS delivery/capability opt-out while text continues.
The standalone Windows WIC test preserves pixels/alpha and rejects malformed,
oversized-byte and oversized-dimension inputs without touching the OS clipboard.
Flutter analysis reported no issues; Clippy reported only the same 31 existing
crypto/HTTP/WebRTC warnings; `git diff --check` passed. Both debug builds completed.
Physical Android/Windows image paste, source URI access and cache lifecycle
validation remain pending; automated codec/transport checks do not establish
those device results or production readiness.

Android APK SHA-256:
`31B7634C70D33A38BF447FB36738F395DABB070CBD103EB39A85397D259DF53C`.
Windows kernel SHA-256:
`F436C7B3917D0ACAD35A8E9532116C7BC6266C0D156570B0FA2BDFC19D6496DC`.
The Windows app was launched and the Android APK successfully installed/launched
over wireless ADB. Subsequent inspection found no Shizuku server/helper and only
the Windows listener, so the user was asked to restart Shizuku before physical
image testing. The cause of the later Shizuku stop was not established.

## Android image capture correction on Galaxy A35

The user confirmed Windows screenshots paste successfully on Android. Android
screenshots initially did not reach Windows. Metadata-only inspection immediately
after a fresh screenshot found the earlier received LocalSend image still in the
system primary clipboard (sensitive and own-origin marked). The screenshot was
visible in keyboard history but had not replaced the system clipboard value.

An explicit Gallery Copy to clipboard produced a single non-sensitive image
content URI in the system clipboard, but opening it failed. The initial helper
used ActivityThread's system context and createPackageContext for a normal app
ContentResolver. On this shell process, AppOps/attribution did not become the
shell package, causing a package/UID mismatch. Even correcting attribution did
not make the helper an AMS-managed app process, so app-style provider acquisition
was still inappropriate.

ClipboardImageReader now uses an external provider lease and IContentProvider
read-only openFile with the actual UID 2000/com.android.shell AttributionSource,
then releases the lease in finally. Existing temporary clipboard URI grants are
still enforced; cross-profile URIs are rejected. The helper version is bumped to
3 to replace cached helper code. An ADB metadata probe invoking this exact
production reader opened the Gallery descriptor and confirmed the encoded size
within limit without reading/printing image bytes, text, URI paths or hashes.
The corrected Android APK built successfully. Integrated delivery after installing
this correction remains pending the user's fresh-copy test.
The APK was successfully installed/launched over wireless ADB. SHA-256:
`7EC26D0281B28BD8FA329D0AA298C8B026DE432F3CDF5C74AC84372EE5D40BFE`.
The user subsequently confirmed that manually copying a photo on Android now
syncs it successfully to Windows. Together with the earlier Windows screenshot
paste on Android, this establishes user-verified image delivery in both directions
in this Galaxy A35/Windows session. Taking a screenshot alone still does not
trigger delivery; the earlier immediate metadata inspection showed that action
had not replaced the primary system clipboard. Keyboard screenshot history and
system clipboard copies are distinct on this device. Automatic screenshot-file
sharing is a separate, unimplemented behavior, not part of copied-image sync.

## Automatic Android screenshots under the existing image option

At the user's explicit request, Synchronize copied images now also controls a
MediaStore screenshot watcher in the ordinary Android foreground service. No
second setting was added. Full photo access is requested through the existing
authorization button or when enabling the image option; selected-photo access
cannot cover future screenshots. Permission denial/revocation is reported on
the sync page and ongoing notification without changing copied-image access.

Each watcher start records the existing highest image ID on each external volume.
Provider notifications are coalesced on one worker, with canceled tasks removed,
32-row scan bounds, 256 seen IDs, fresh capture/save timestamps and explicit
finished/nonempty/size/MIME checks. Only recognized screenshot filename prefixes
in DCIM/Screenshots or Pictures/Screenshots are eligible. Old screenshots,
reimports with old capture timestamps, camera photos and unrelated downloads
are skipped. The latest candidate uses the existing bounded image worker and
Rust ordering channel. New local clipboard changes/remote writes invalidate a
delayed screenshot decode. The screenshot is not written to Android's clipboard.
Stop/image opt-out unregisters observers, cancels queries and clears ownership.
Custom storage locations and other filename conventions are not yet recognized.

Validation: 12 standalone screenshot-policy checks and eight Flutter provider/
settings lifecycle tests passed; Flutter analysis reported no issues; both debug
builds completed; `git diff --check` passed. A metadata-only MediaStore query
confirmed this phone uses a recognized screenshot album and filename prefix.
Both apps were updated/launched and the LAN connection and shell helper were
confirmed active. The user was asked to grant full photo access and test a fresh
screenshot directly into Windows Paint; automatic device delivery remains pending.

Android APK SHA-256:
`1F06DA3F23C1ECDE3CD6B649A2112351D6DFA19A1CC42AB88DF177CDB036CAF5`.
Windows kernel SHA-256:
`E3E51EFC31EBE5197F2DBD1619503989CC405C6F97ADC188A790D77B3359EF4A`.
The user subsequently confirmed automatic Android screenshot delivery works.
This is a user-verified result for the Galaxy A35/Windows session; other screenshot
locations/devices and long-duration lifecycle behavior still require validation.

## Image arrival notifications

Added destination notifications for remote image writes only. The Rust update
includes the TLS-authenticated peer identity alongside the pending payload;
status-only updates retain the sender, and consuming/superseding/expiring writes
clears that metadata. Flutter resolves it to the saved paired-device name and
passes localized title/body metadata only for writeImage. Notification creation
occurs natively after a successful clipboard write, so rejected, stale or failed
writes do not announce arrival. Text writes never create an arrival notification.

Windows reuses tray_manager's existing root-window tray icon (ID 1), requesting
a Shell notification without a second icon, extra app identity or notification
dependency. It respects Windows quiet-time settings and has no image preview.
Android uses a separate high-importance Clipboard image arrivals channel with
one replaceable, private, auto-dismiss notification and an app-open action. The
foreground service notification remains separate. Subsequent remote text writes
and Stop clear the Android arrival item silently. Notification failures do not
change successful clipboard delivery. No clipboard image/text, URI or fingerprint
is included in notification bodies.

Validation: Flutter analysis, 28 core clipboard tests (including authenticated
image sender identity), 14 Flutter clipboard/pairing tests and both debug builds
passed; `git diff --check` passed. Physical notification display in both
directions and the text-silent check remain pending after deployment.
The Windows build was launched and the Android APK installed/launched successfully.
Android APK SHA-256:
`2658F8F6468946C3AD1F941406A4F974ACBC027290DB2CC26EFD145D4C16468A`.
Windows kernel SHA-256:
`4EF5C393D38DB7AE0489599BB284F24D852400E8DC018D00A6AEA4CD517D7079`.
Post-install inspection confirmed the active LAN connection and shell clipboard
helper. The user subsequently reported that the notification works as expected.
Individual direction/text-silence observations were not separately supplied;
the code gates arrival notifications exclusively on successful remote image writes.


## Simplified clipboard settings UI

Replaced the technical main page with a responsive, centered layout containing
Share clipboard, Synchronize copied images, a compact aggregate connection
status, named devices and Add device. Device controls open in a scrollable sheet;
send/receive permissions and removal confirmation remain available. Manual
pairing, raw counters and Android permissions moved to the More menu. Help keeps
privacy, image retention/access requirements and current development limits
available without putting those details on the main screen. Errors offer plain
language guidance, and empty setup explains why sharing is disabled.

All ViewModelBuilder instances retain the application-wide clipboard controller
when a page, dialog or device sheet is closed. No synchronization protocol,
permission storage or paired identity changes were made for this UI update.

Validation: Flutter analysis passed; 15 clipboard widget/provider/i18n tests
passed, including controller lifetime, responsive widths 360/1280, 1.8x text,
removal cancellation, empty setup and configuration-error guidance. Rendered
phone/desktop previews with real fonts were visually inspected. Windows and
Android debug builds passed. New English UI strings are localized through Slang
with English fallback for untranslated locales.

Android APK SHA-256:
`6122D3316DCBEFC47174E408BD795054CB3C34F731E2AE289D4EFBA7B8CD0971`.
Windows kernel SHA-256:
`6FDECACB68D610379C417C7B3F3D77D9532B986378D77657772A63D432DE84D7`.

The Windows app was restarted (PID 31380); the updated Android APK installed and
launched successfully. Post-install checks confirmed the Android app and shell
clipboard helper running with Shizuku, and the Windows LAN connection established.
Physical review of the redesigned page by the user remains pending.


## Android onboarding, tutorial and per-device connection indicators

Added a first-enable Android bottom sheet explaining the Shizuku requirement,
with a tutorial link and a permission setup action. The More menu routes to the
same five-step tutorial. Official Shizuku download/setup links are provided;
the guide covers wireless debugging, access permissions, LocalSend QR pairing,
sharing and restarting Shizuku after a reboot. Permission denial leaves sharing
off. A successful enable persists hasEnabledBefore in protected clipboard
settings; legacy enabled installs skip the first-use introduction. The existing
sharing consent remains required.

Removed the Ready to share / Connected devices block from the main page.
Connected devices instead have an accessible green dot beside their name.
Rust updates now include the set of active authenticated, initialized peer
identities; session reservations waiting for the clipboard capability/clock
exchange do not appear connected. Disconnect and Stop clear individual/all
identities. FRB and the Flutter controller propagate this metadata without
changing the clipboard wire protocol or paired identities.

The ongoing Android notification now shows only connected counts and connected
device names. Paired-but-offline names and paired-device counts are omitted.
Capture/photo access warnings remain visible when attention is needed.

Validation: 30 core clipboard tests passed, including three-device identity
tracking, individual disconnect, stop cleanup and an incomplete session not
being reported connected. 23 Flutter widget/provider/pairing-link/i18n tests
passed, covering first-use tutorial navigation, permission denial, returning
users, flag persistence/migration, per-device dots, responsive layout and the
existing lifecycle/removal checks. Real-font phone/desktop previews were rendered
and the updated main layout inspected. Flutter analysis passed.

Each device now has its own simple card, separated by spacing, retaining its
name, sharing direction, per-device green dot and management action. The widget
test checks that connected and offline rows have distinct card ancestors.
A separate permanent Windows installation/shortcuts were canceled at the user's
request; Windows continues to run from the project Debug bundle.

Final card-layout Windows and Android debug builds passed. Artifact hashes:
Android APK SHA-256:
`CD5EC196084F044712B0A8476B37069BA93F04CBE0E3AFE736433A778D489C79`.
Windows kernel SHA-256:
`2F2BD3E83A0E2F992737015CB86114CD0CCF36AD2D7A5737FA377781ADBC5CA7`.

Final Android installation/launch succeeded; Windows is running the final
project debug bundle. Post-install checks confirmed the Android app, Shizuku
shell helper and LAN connection active. The first-use flow was validated with
widget fixtures, preserving the user's existing pairing/setup. User review of
the redesigned tutorial/cards/notification remains pending.


## Consistent default app colors

Changed shared color initialization and missing/invalid-color fallback to
ColorMode.localsend on every platform, independent of dynamic-color support or
build mode. Valid saved color choices remain supported. No storage migration
or color-option removal was introduced. The current Android test profile's
previous System default is switched to LocalSend so the installed app uses teal.
Flutter analysis passed; both debug packages are rebuilt for deployment.

Windows and Android debug builds passed. Color-default artifact hashes:
Android APK SHA-256:
`9D5023FD06A11B47F48A40E1107166D0619FF616F6ED0FAFEDD8812D929D628B`.
Windows kernel SHA-256:
`A1E53CD2424FB7AC168C1994E37FD70B80933267520D9F8A0C93BD266C433E6E`.

The rebuilt Android APK installed and launched successfully. The test profile's
ls_color value was changed from system to localsend while the app was stopped,
without clearing its preferences or clipboard pairing. Post-launch inspection
confirmed localsend remained saved. Windows is running the rebuilt Debug bundle.
