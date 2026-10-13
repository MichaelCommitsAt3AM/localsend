# Clipboard synchronization implementation

Status: initial Windows–Android direct LAN development slice implemented; debug
builds and integrated physical testing in progress. This is not the complete
production feature. KDE validation is deferred; hosted relay and Linux integration
remain pending. See [debug build scope and testing](WINDOWS_ANDROID_DEBUG.md).

Baseline: `14f3a87426eedffaa9d87d011132eca5501abeb8`.

## Accepted direction

- One Rust synchronization engine; Refena settings/status and typed isolate bridges.
- Native event-driven Windows and X11 adapters; runtime-probed Wayland support.
- An ordinary Android service owns runtime/network lifetime. A small shell Shizuku
  UserService owns privileged clipboard access; no keys or networking in the helper.
- Local transport reuses discovery and an additive bounded secure channel.
- Optional independently deployed authenticated WSS relay, with no clipboard storage.
- Inner mutually authenticated TLS 1.3 sessions between paired devices on either
  transport. Both endpoints require exact verified clipboard-identity pins.
- Dedicated securely stored clipboard identity; favorites and enrollment are not trust.
- Explicit pairwise directions, disabled default, explicit live transport selection.
- Best-effort latest-value delivery; bounded RAM retention, no clipboard history/logging.
- No silent fallback, transitive forwarding, unbounded queues, or plaintext relay.

## Delivery sequence

| Phase | Deliverable | Gate |
| --- | --- | --- |
| 0 | Baseline builds and architecture decisions | Record pre-existing failures |
| 1 | Android listener/read/write/lifetime and Wayland capability evidence | Real devices/sessions; no inferred success |
| 2 | Shared engine, event ordering, deduplication and fake adapters | Model/property tests |
| Backend A | Session/protocol/enrollment/pairing specification | Security review |
| 3–4 | Desktop adapters and background owners | Native/lifecycle tests |
| 5 | Local transport and persistent trust | Legacy-client and unauthorized-peer tests |
| Backend B–C | Bounded relay and hosted client | Cross-network and hot-switch tests |
| 6 | Settings, statuses, migrations and localization | Disabled defaults and truthful capabilities |
| Backend D / 7 | Security, resources, battery and platform hardening | Review, soak and regression evidence |
| Backend E | Containers and operational guides | Clean-host deployment/upgrade/restore |

Estimated complete effort: 95–144 engineering days, including 35–53 backend days,
excluding external review lead time. This is a planning estimate, not a benchmark.

## Current feasibility tools

See [instructions](feasibility/README.md) and [evidence record](feasibility/RESULTS.md).
The isolated Android APK has its own package and no network permission. The Python
Wayland probe only reads the registry and never reads or modifies clipboard data.

Approval to begin these experiments does not establish their success. Production
support claims remain gated by recorded results, not documentation or compilation.
