# Clipboard synchronization implementation

Status: Windows-Android direct LAN clipboard synchronization is implemented and
has been exercised on physical devices. This is a development build, not a
completed production release. Linux and macOS clipboard adapters are not
implemented; both platforms, including KDE Wayland validation, are outside the
current implementation and release scope. Only Windows and Android releases are
planned for now. See the
[debug build scope and testing](WINDOWS_ANDROID_DEBUG.md) and
[recorded validation results](DEBUG_RESULTS.md).

Baseline: `14f3a87426eedffaa9d87d011132eca5501abeb8`.

## Scope decision

As of 2026-10-13, clipboard synchronization will remain local-network-only.
The optional hosted/self-hosted clipboard relay and its deployment plan are
canceled. Devices must be directly reachable on the local network. No cloud
clipboard storage, internet transport, relay enrollment, transport selector or
hosted fallback will be added.

The static `localsend.currenta.tech` pairing-link site remains separate: it opens
the app from camera scans and supplies Android domain verification. Pairing
credentials stay in the URL fragment; clipboard contents never pass through the
site. GitHub Releases remains the source of app updates, not clipboard delivery.
The inherited upstream `server/` WebRTC signaling component is unrelated to
clipboard synchronization and is not required for it.

## Accepted direction

- One shared Rust synchronization engine with Refena settings/status and Flutter-Rust bridges.
- Native event-driven Windows clipboard access; Linux and macOS work is deferred.
- An ordinary Android service owns runtime/network lifetime. A small shell Shizuku
  UserService owns privileged clipboard access; no keys or networking in the helper.
- Direct local connections between explicitly paired devices; discovery supplies
  pairing candidates but never grants trust.
- Mutually authenticated TLS 1.3 sessions with exact verified clipboard-identity pins.
- Dedicated securely stored clipboard identity; LocalSend favorites are not trust.
- Explicit pairwise directions and sharing disabled by default.
- Optional copied-image and fresh Android screenshot sharing under one image setting.
- Best-effort latest-value delivery; bounded RAM retention, no clipboard history/logging.
- No transitive forwarding or unbounded queues.

## Remaining delivery sequence

| Workstream | Deliverable | Gate |
| --- | --- | --- |
| Local protocol hardening | Review pairing, identity lifecycle, replay/order handling and receipt/retry semantics | Independent security review and adversarial tests |
| Local discovery and reconnect | Safe address refresh, capability discovery and recovery after network changes | DHCP, interface changes, disconnect/reconnect and unauthorized-peer tests |
| Windows and Android reliability | Adapter race handling, Shizuku recovery, service lifecycle, bounded resources and battery behavior | Extended device/version coverage, soak and regression evidence |
| Product readiness | Settings, migrations, localization, documentation and release packaging | Disabled defaults, truthful capabilities and release upgrade validation |

The shared engine and protocol are reusable across platforms. That does not mean
Linux or macOS synchronization is already implemented: the app currently
initializes the clipboard runtime only on Windows and Android, and the required
native adapters and identity-storage integration are missing on the other two.
Their updater paths are separate and do not provide clipboard support.

## Deferred platforms

Linux and macOS implementation and testing are deferred indefinitely as of
2026-10-13. There is no macOS test machine available, and Wayland clipboard
restrictions require further capability investigation. Neither platform is a
release target or a gate for the Windows/Android release. Future support may be
reconsidered, but no delivery commitment is made. Existing upstream platform code
and preparatory updater code remain available for that possibility.

The previous combined local-plus-relay effort estimate is withdrawn. Remaining
Windows/Android local-only work needs a fresh estimate after protocol review and
reliability checks; no hosted-backend phases remain in this roadmap.

## Current feasibility tools

See [instructions](feasibility/README.md) and [evidence record](feasibility/RESULTS.md).
The isolated Android APK has its own package and no network permission. The Python
Wayland probe only reads the registry and never reads or modifies clipboard data.

Production support claims remain gated by recorded results, not documentation or
compilation. Updater support and upstream file-transfer support do not establish
clipboard support on a platform.
