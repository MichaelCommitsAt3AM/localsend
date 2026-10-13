# Clipboard feasibility checks

These tools are separate from LocalSend's production app. They do not implement
synchronization, transport, pairing, or a relay.

## Android listener and service test

The standalone Java Android app uses Shizuku API/provider 13.1.5. Java avoids adding
another language/plugin to this isolated test project. The eventual application
integration follows LocalSend's Kotlin conventions.

Requirements: JDK 17+ compatible with Gradle 9.4.1 (this build uses JDK 21), Android SDK 37,
build tools, Gradle wrapper downloads, and a real Android 13–16 device running
ADB/shell Shizuku. The target SDK is 37 to expose the fork's target behavior; helper
adapters intentionally reject devices outside API 33–36 until their signatures are
reviewed. Root-mode Shizuku is rejected instead of silently changing process UID.

Build from `android/`:

```powershell
# JAVA_HOME must identify a JDK supported by the pinned Gradle version.
# ANDROID_HOME must identify your SDK (or set sdk.dir in local.properties).
.\gradlew.bat :app:assembleDebug :app:testDebugUnitTest :app:lintDebug --no-daemon
```

On Linux/macOS use `sh ./gradlew` with the same tasks. Gradle's distribution SHA-256
is pinned in the wrapper properties. This is a separate dependency graph and does
not modify LocalSend's lockfiles.

APK: `android/app/build/outputs/apk/debug/app-debug.apk`.
Package: `org.localsend.clipboardfeasibility`.

```text
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n org.localsend.clipboardfeasibility/.ProbeActivity
```

1. Open **Clipboard feasibility**. Authorize this separate package in Shizuku.
2. Grant notification permission, then press **Start listener**.
3. Switch to another app and copy exactly:
   `LocalSend clipboard feasibility marker`
4. Return and press **Refresh metadata**. This only displays cached metadata: it
   does not read the clipboard or create a callback.
5. Record helper UID 2000, listener registered, increasing callback count,
   `text-readable`, and known marker match. Registration alone is insufficient.
6. Copy different text, then the marker again; test rapid copies and task dismissal.
7. Use **Manual snapshot** separately to distinguish read permission from callback
   delivery. Never use its result to claim the listener worked.
8. Press **Write marker in 5 seconds**, switch to another app, then paste. This uses
   ordinary application `ClipboardManager` from the foreground service, not Shizuku.
   A successful API return is insufficient: verify the pasted marker.
9. Test lock/unlock, Shizuku stop/restart, permission revocation, service Stop,
   process death, and reboot separately. Stop/start is an explicit recovery action
   in this experiment; automatic recovery belongs to a later phase.
10. Press **Stop and remove helper** when done. Uninstall the test package if desired.

For observation while another app stays foregrounded, read cached metadata:

```text
adb shell dumpsys activity service org.localsend.clipboardfeasibility/.ProbeService
```

This performs no clipboard read and does not foreground the test app. Compare
callback count before and after the external copy, not just marker equality.

The helper registers a Binder listener; it does not poll, scrape logs, create an
overlay, mutate OEM settings, or transmit text. It only returns metadata including
byte count and equality with the public marker. Clipboard values/hashes are not
logged or persisted. Sensitive-marked clips are suppressed; unmarked clips are not
assumed safe. Multi-item clips and non-text content are unsupported.

`empty-or-unavailable` deliberately does not distinguish empty, locked and denied
reads without evidence. Record the observed device state separately.

The service uses an explicitly described `specialUse` type for this user-initiated
developer experiment. This is **not** validation of a production service type or
Play distribution eligibility. No network permissions, boot receiver, wake lock,
sticky restart, or automatic reconnection are included.

The isolated project uses AGP 9.2.1 / Gradle 9.4.1 because AGP 8.12.1 could not
resolve this machine's SDK `android-37.0` package. Production Gradle files are
unchanged. This difference must be accounted for when integrating the adapter.

## Wayland registry probe

Run inside the actual target desktop session, as the logged-in desktop user:

```sh
python3 wayland/probe.py
```

No third-party Python packages are required. A successful probe prints JSON and
returns 0; missing session variables, socket failures, malformed messages and
timeouts return 2. A missing protocol is a successful observation, not a crash.

`advertised` means the compositor advertises `ext_data_control_manager_v1` or
`zwlr_data_control_manager_v1`. It does **not** establish clipboard read/write
authorization. `monitoringValidated` and `writingValidated` remain false until an
actual authorized adapter is exercised. WSL without the target desktop session
does not substitute for KDE/GNOME validation.

Protocol/parser tests:

```text
python -m unittest discover -s support/clipboard_sync/feasibility/wayland -v
```

## Source references and licensing

Hidden clipboard signatures were inspected in AOSP Android 13/14/15/16 release-tag
`core/java/android/content/IClipboard.aidl`. The Android 13 adapter uses package and
user arguments; Android 14–16 uses attribution, user, and default physical device.
Current user is resolved and checked; an inactive user's clipboard is not accessed.

- https://github.com/RikkaApps/Shizuku-API (MIT; artifacts' Maven POM confirms license)
- https://github.com/aosp-mirror/platform_frameworks_base/blob/android-13.0.0_r1/core/java/android/content/IClipboard.aidl
- https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/core/java/android/content/IClipboard.aidl
- https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/core/java/android/content/IOnPrimaryClipChangedListener.aidl
- https://gitlab.freedesktop.org/wayland/wayland-protocols

The Binder callback implements the documented descriptor/one-way dispatch contract;
no reference-project implementation code was copied. Shizuku dependencies remain
isolated from production. Distribution requires its MIT notice and the generated
Gradle wrapper's license notice.
