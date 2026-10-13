# Feasibility evidence

Build evidence: 2026-10-12. Physical Android checks: 2026-10-13.
Baseline: `14f3a87426eedffaa9d87d011132eca5501abeb8`.

## Build and automated checks

| Check | Result |
| --- | --- |
| Initial repository status | Clean before feasibility work |
| Wayland parser/roundtrip tests | 7 tests passed on Windows; mock compositor only |
| Android APK build, unit tests and lint | APK built; 3 unit tests passed; lint 0 errors / 20 warnings; APK v2 signature verified |
| LocalSend Rust full-feature baseline | Compiled; 84 unit tests passed, 1 existing unit test failed; 61 integration tests passed in separate invocation |
| LocalSend Flutter baseline | Pinned Flutter 3.41.9; enforced-lockfile resolution succeeded; 88 app tests passed; analysis found no issues |
| Isolate package tests | 21 passed; 1 skipped after building Rust plugin; initial run was 18 passed / 4 skipped |
| Rust core clippy | Completed successfully with existing warnings |
| Rust Flutter plugin | `cargo build --locked --package rust_lib_localsend_app` succeeded |
| GitHub feasibility workflow | Added; not executed on GitHub |
| Full LocalSend platform builds | Not run; no Android/Linux hardware/session attached |

The existing Android app compiles against SDK 36 but targets 37. This remains a
baseline concern; no production configuration has been changed. The standalone
probe compiles against SDK 37 and targets 37.

Rust command: `cargo test --locked --features full` in `packages/core`.
Existing failure: `model::transfer::tests::formats_nanosecond_timestamp` in
`packages/core/src/model/transfer.rs:261`. On Windows the observed timestamp was
`1970-01-01T00:00:00.1234567Z`; the test expects `.123456789Z`. No core code has
been changed. The failed unit test prevented that invocation's integration tests.
All ten integration-test targets were then invoked explicitly with `--locked
--features full`; 61 tests passed. The Unix-only `accept_resilience` target has
zero runnable tests on Windows and is not validated by that result.

The remaining isolate skip is a pre-existing platform issue:
`cancel_session_repro_test.dart` searches only for a macOS `.dylib`, whereas this
Windows build produces `rust_lib_localsend_app.dll`. The three instance-handover
tests ran successfully after building the plugin. No test was edited to hide or
bypass the remaining skip.

First isolated Android build: AGP 8.12.1 / Gradle 8.13 failed to find `android-37`
although SDK `android-37.0` is installed. Probe switched to documented SDK-37
compatible AGP 9.2.1 / Gradle 9.4.1; production toolchain files remain unchanged.

Android lint warnings include the intentional hidden-API experiment, English-only
developer controls, pinned dependency versions, and the missing launcher icon.
They are not a claim of production readiness. Shizuku's MIT license notice is
included inside the APK. The merged manifest contains no network permission.
Final debug APK SHA-256:
`951300899be9145d120c4ba2ccf361f635f36e52c2d126f14dd06635b24d441e`.

Flutter dependencies were resolved with `--enforce-lockfile`; no dependency
versions were updated. Local FVM 4.3.1 and the repository-pinned SDK were installed
for baseline validation. The system Flutter SDK was older and was not modified.

## Physical-device / compositor validation

No phone was connected during initial inspection. On 2026-10-13, ADB confirmed
an authorized Samsung Galaxy A35 (`SM-A356E`) running Android 16 / API 36,
build `BP4A.251205.006.A356EXXSBDZH1`. Shizuku package version is
`13.6.0.r1086.2650830c`. The final debug APK above installed successfully and its
Activity launched. Listener authorization/start and clipboard behavior are still
pending; installation is not evidence of background capture. The user also has
a KDE Wayland session available.

| Scenario | Environment | Result | Evidence |
| --- | --- | --- | --- |
| Android listener while another app is foregrounded | Samsung SM-A356E, Android 16 / API 36; WhatsApp foreground | Passed on this device | Initial external copies increased cached callbacks 4 → 8 → 10 → 12 but did not match fixture. After generated-marker write and user-reported external paste/copy, count was 16, text-readable, 38 UTF-8 bytes, exact marker match true. The 12 → 16 interval includes both service write and external copy; their individual callback counts were not sampled. Shell helper UID 2000, listener registered; cached service dumps used, not manual snapshots; resumed Activity confirmed WhatsApp |
| Android service writes while another app is foregrounded | Same device; delayed ordinary ClipboardManager service write, WhatsApp foreground reported by user | Passed on this device, user-verified paste | User reported exact generated marker pasted into unsent draft and copied back; subsequent cached sample matched fixture. Foreground state at the precise write instant was not independently sampled |
| Activity/task closed, service retained | Same device; user swiped test task away; WhatsApp foreground | Service retention and fresh capture passed on this device | Same service PID and running flag retained, test Activity absent from activity listing. Identical-marker copy left count at 16; after user-reported changed copies, count increased to 18 and text-readable. Final sample 44 UTF-8 bytes, not exact fixture. No manual snapshot or Activity relaunch used |
| Locked/unlocked | Same device; user-reported 20-second lock/unlock, then WhatsApp copy | Post-unlock capture passed; locked reads unverified | Same service PID retained; callbacks 18 → 20, text-readable after unlock with Activity still dismissed. No observation of clipboard read while locked; short lock is not a Doze or long-runtime test |
| Shizuku permission revocation and explicit recovery | Same device; user reported restarting listener then revoking this package in Shizuku | Cleanup and explicit recovery observed | No matching service or app/helper process remained; package user 0 reported stopped=true and granted API permission entry was absent. Listener restart before revocation was user-reported, not independently sampled. After user restored access and started listener, new service PID 22003, shell helper UID 2000, listener registered, 2 callbacks and text-readable with WhatsApp foreground. This does not test stopping Shizuku itself |
| Explicit Stop cleanup | Same device; user tapped Stop and remove helper | Passed on this device | Service dump found no matching service; shell helper PID 15539 / UID 2000 disappeared from process list. Ordinary UI process remained; Shizuku itself was left running |
| App process death / force-stop cleanup | Same device; ADB force-stopped only user-0 test package after recovery | Cleanup passed on this device | Subsequent service dump had no matching service; app and shell helper were absent from process list. Probe left stopped. No automatic restart is claimed or expected after force-stop |
| Doze / OEM optimization | Not yet recorded | Unverified | Measure delayed callbacks/runtime lifetime |
| KDE Wayland registry | User's KDE session; available later per user on 2026-10-13 | Deferred, unverified | Run probe in target session when available |
| KDE actual monitoring/writing | User's KDE session; available later | Deferred, unverified | Registry advertisement is insufficient; actual adapter read/write test required |

For Android record model, Android version, build, Shizuku version/start mode,
helper UID, target SDK, foreground app/state, callback count before/after, read
status, marker match, write/paste outcome and recovery. Do not put clipboard
contents, hashes, credentials or private identifiers into this record.

## Production gates

The short physical-device session supports unlocked event-driven capture,
ordinary-service background writing, task-dismissal survival, post-unlock
capture, explicit Stop cleanup, permission-revocation cleanup/recovery, and
force-stop cleanup on this specific device. It does not close Phase 1: Shizuku
server loss, locked read behavior, prolonged Doze/OEM restrictions, other Android
versions, shared Flutter-engine lifetime, and actual Wayland read/write remain
unverified. The test app is installed but stopped; no production app was modified.

- No blanket Android 13–16 claim based on one device.
- No listener claim based only on registration or manual reads.
- No KDE/GNOME clipboard support claim based only on advertised globals.
- No locked-screen capture promise for the inspected AOSP shell-read path.
- No production FGS/store eligibility inferred from the developer probe.
- Shared Flutter-engine lifetime, secure key storage and network recovery still
  require later isolated validation before production integration.
