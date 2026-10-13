# LocalSend Clipboard Sync

A development fork of [LocalSend](https://github.com/localsend/localsend) with automatic clipboard sharing between explicitly paired Windows and Android devices. Regular LocalSend file and message transfers remain available.

**Current scope:** Windows-Android direct LAN clipboard sync. This is a development build, not a completed production release. Linux clipboard integration, other platform adapters and an optional self-hosted relay are still pending.

The badges and project links below refer to upstream LocalSend.

[![CI status][ci-badge]][ci-workflow]
[![Translations][translate-badge]][translate-link]
[![Packaging status][packaging-badge]][packaging-link]

[ci-badge]: https://github.com/localsend/localsend/actions/workflows/ci.yml/badge.svg
[ci-workflow]: https://github.com/localsend/localsend/actions/workflows/ci.yml
[translate-badge]: https://hosted.weblate.org/widget/localsend/app/svg-badge.svg
[translate-link]: https://hosted.weblate.org/engage/localsend/
[packaging-badge]: https://repology.org/badge/tiny-repos/localsend.svg
[packaging-link]: https://repology.org/project/localsend/versions

[Homepage][homepage] • [Discord][discord] • [GitHub][github] • [Codeberg][codeberg]

[English (Default)](README.md) • [中文](/support/readme/README_ZH.md)

[homepage]: https://localsend.org
[discord]: https://discord.gg/GSRWmQNP87
[github]: https://github.com/localsend/localsend
[codeberg]: https://codeberg.org/localsend/localsend

LocalSend is a free, open-source app that allows you to securely share files and messages with nearby devices over your local network without needing an internet connection.

- [About](#about)
- [Fork Changes](#fork-changes)
  - [Clipboard Setup](#clipboard-setup)
  - [Privacy and Current Limits](#privacy-and-current-limits)
  - [Fork Builds and Updates](#fork-builds-and-updates)
- [Sponsors](#sponsors)
- [Screenshots](#screenshots)
- [Download](#download)
- [How It Works](#how-it-works)
- [Dependency Hierarchy](#dependency-hierarchy)
- [Getting Started](#getting-started)
- [Command Line Interface](#command-line-interface)
- [Contributing](#contributing)
  - [Translation](#translation)
  - [Bug Fixes and Improvements](#bug-fixes-and-improvements)
- [Troubleshooting](#troubleshooting)
- [Building](#building)
  - [Android](#android)
  - [iOS](#ios)
  - [macOS](#macos)
  - [Windows](#windows)
  - [Linux](#linux)

## About

LocalSend is a cross-platform app that enables secure communication between devices using a REST API and HTTPS encryption. Unlike other messaging apps that rely on external servers, LocalSend doesn't require an internet connection or third-party servers, making it a fast and reliable solution for local communication.

## Fork Changes

| Feature | Behavior in this fork |
| --- | --- |
| Automatic clipboard sharing | New plain-text copies sync both ways between authorized devices. Sharing starts disabled. |
| Optional image sharing | **Synchronize copied images** includes copied photos and screenshots; enable it on both devices. |
| Android screenshots | Newly saved screenshots in the standard screenshot albums sync automatically under the same image option, with full photo access. |
| Background operation | Windows can stay in the tray; Android uses an ongoing service and Shizuku while its screen is closed. Sleep and lock restrictions still apply. |
| Easy pairing | Add devices with a QR code or the nearby-device list, compare the code and approve on both devices. Manual pairing is an advanced fallback. |
| Simple device controls | Each device has its own card and a green dot when connected. Tap a card to manage send/receive access or remove it with confirmation. |
| Android onboarding | First-time enabling explains Shizuku in a bottom sheet. **More > Setup tutorial** opens the same installation, permission and pairing guide. |
| Image arrival notifications | Windows and Android announce successfully received clipboard images so users know when they are ready to paste. Text arrivals are silent. |
| Android ongoing notification | Shows only connected device counts and names; paired devices that are offline are omitted. |
| Consistent default colors | New installs use LocalSend teal on every platform and in all build types. Other color choices remain available in Settings. |

Clipboard support is separate from upstream LocalSend's platform support:

| Platform | Clipboard status |
| --- | --- |
| Windows | Implemented; tested with the custom debug build. |
| Android 13-16 | Implemented through Shizuku's wireless-debugging/computer startup mode; physical testing performed on a Galaxy A35 running Android 16. |
| Linux, macOS, iOS and other platforms | Clipboard adapters are not implemented in this fork yet. KDE Wayland testing is deferred. |

### Clipboard Setup

1. Install this fork on both devices and keep them on the same reachable local network. Official LocalSend builds do not include this clipboard feature.
2. On Android, [install Shizuku](https://shizuku.rikka.app/download/) and start it using [wireless debugging or a computer](https://shizuku.rikka.app/guide/setup/). In LocalSend, **Settings > Clipboard sync > More > Setup tutorial** walks through installation, starting Shizuku, permissions and pairing. Use **Android permissions** to authorize LocalSend and allow notifications. Start Shizuku again after a phone reboot.
3. On Windows, open **Settings > Clipboard sync > Add device**. Scan the QR code with LocalSend on your phone, or with its normal camera on the configured Android debug build. Compare the displayed codes and confirm on both devices. You can also select a nearby device. Pairing alone does not enable sharing.
4. Turn on **Share clipboard** on both devices and accept the sharing confirmation. A green dot beside a device means its clipboard connection is active. Copy new text on one device and paste on the other.
5. To include images, turn on **Synchronize copied images** on both devices. Allow **full photo access** on Android for automatic screenshot sharing; selected-photo access cannot include future screenshots. Paste images into an app that supports image paste, such as Paint on Windows.

Keep Windows LocalSend running in the tray and Android's clipboard service running for background sharing. Force-stopping Android LocalSend stops the service.

The fork adds these TCP ports to LocalSend's usual file-transfer/discovery port:

| Purpose | Port | When used |
| --- | --- | --- |
| Clipboard sharing | 53318 | While clipboard sharing is enabled. |
| Device pairing | 53319 | Temporarily while Add device is open. |

Allow these connections on the intended local network. Guest Wi-Fi or access-point isolation can prevent devices from connecting. Normal file transfer still uses LocalSend's configured port, 53317 by default.

### Privacy and Current Limits

Clipboard sharing uses its own securely stored device identity, pinned mutual TLS 1.3 connections and explicit peer permissions. Windows protects the identity with DPAPI; Android uses its Keystore. LocalSend favorites do not authorize clipboard sharing. There is no clipboard history or clipboard-content logging, no forwarding between peers and no startup broadcast of existing clipboard contents.

- Only new copies are shared. Clipboard items marked sensitive are skipped; unmarked text or screenshots can still contain private information. Pair only devices you control and trust.
- Text is limited to 64 KiB. Images are normalized to PNG with limits of 8 MiB, 16 megapixels and 16384 pixels per dimension. Received Android image data is retained for up to five minutes. Unsupported or oversized content is skipped.
- Automatic Android screenshots are recognized in `DCIM/Screenshots` and `Pictures/Screenshots` with supported screenshot names. Old screenshots are not sent when sharing starts. Custom screenshot locations are not supported yet. Ordinary saved camera photos are not automatically shared; explicitly copy them.
- Rich text, multiple clipboard items and remote clipboard clearing are not implemented. Some Android image providers restrict access to copied images.
- Delivery is best effort and keeps the latest value. Locked-screen capture, uninterrupted operation during sleep and long-duration reliability are not guaranteed.
- Pairing currently saves device IP addresses; re-pair if an address changes. Internet/relay clipboard sharing and independent security review remain pending.
- Camera-app links use `localsend.currenta.tech`. Verified Android links currently cover the debug signing certificate; production signing requires the association setup described in the [pairing-link deployment guide](support/clipboard_sync/app_link_site/README.md).

See the [development build guide](support/clipboard_sync/WINDOWS_ANDROID_DEBUG.md) for detailed behavior and testing, the [recorded results](support/clipboard_sync/DEBUG_RESULTS.md) for validation evidence, and the [implementation roadmap](support/clipboard_sync/README.md) for the remaining production, Linux and relay work.

### Fork Builds and Updates

Use the Flutter version pinned in [.fvmrc](.fvmrc) through FVM, plus the Rust and native platform build tools. From `app/`:

```shell
fvm flutter pub get
fvm flutter build windows --debug
fvm flutter build apk --debug --target-platform android-arm64
```

- Windows: `app/build/windows/x64/runner/Debug/localsend_app.exe`. Keep the complete Debug directory together, including its DLLs and `data` directory.
- Android: `app/build/app/outputs/flutter-apk/app-debug.apk`. The debug package is `org.localsend.localsend_app.debug`, with separate app settings from official LocalSend.

This fork has no internal updater. Update manually with a new APK or the complete Windows bundle. The store/package-manager links below install upstream LocalSend, not this fork. Debug builds do not carry upstream release-signing guarantees.

## Sponsors

This section describes upstream LocalSend sponsorship.

This project is tested with BrowserStack

Supported by TestMu AI

<a href="https://www.testmuai.com/?utm_medium=sponsor&utm_source=localsend" target="_blank">
    <img src="https://localsend.org/img/sponsors/tesmu.svg" style="vertical-align: middle;" width="250" height="45" />
</a>

## Screenshots

These are upstream LocalSend screenshots; they do not show this fork's clipboard UI.

<img src="https://localsend.org/img/screenshot-iphone.webp" alt="iPhone screenshot" height="300"/> <img src="https://localsend.org/img/screenshot-pc.webp" alt="PC screenshot" height="300"/>

## Download

**Upstream LocalSend downloads.** For this fork, use [Fork Builds and Updates](#fork-builds-and-updates).

[![Packaging status](https://repology.org/badge/tiny-repos/localsend.svg)](https://repology.org/project/localsend/versions)

It is recommended to download the app either from an app store or from a package manager because the app does not have an auto-update.

| Windows                 | macOS                   | Linux              | Android        | iOS           | Fire OS    |
|-------------------------|-------------------------|--------------------|----------------|---------------|------------|
| [Winget][]              | [App Store][]           | [Flathub][]        | [Play Store][] | [App Store][] | [Amazon][] |
| [Scoop][]               | [Homebrew][]            | [Nixpkgs][]        | [F-Droid][]    |               |            |
| [Chocolatey][]          | [DMG Installer][latest] | [Snap][]           | [APK][latest]  |               |            |
| [EXE Installer][latest] |                         | [AUR][]            |                |               |            |
| [Portable ZIP][latest]  |                         | [TAR][latest]      |                |               |            |
|                         |                         | [DEB][latest]      |                |               |            |
|                         |                         | [AppImage][latest] |                |               |            |

Read more about [distribution channels][].

Upstream Windows release binaries are signed. Read more about the [Code signing policy][].

> [!CAUTION]
> **Unofficial MSIX preview:** you can try builds from the latest commits at [localsend.ob-buff.dev](https://localsend.ob-buff.dev/). Stability is not guaranteed and all custom code tweaks are listed on that site.

[windows store]: https://www.microsoft.com/store/apps/9NCB4Z0TZ6RR
[app store]: https://apps.apple.com/us/app/localsend/id1661733229
[play store]: https://play.google.com/store/apps/details?id=org.localsend.localsend_app
[f-droid]: https://f-droid.org/packages/org.localsend.localsend_app
[amazon]: https://www.amazon.com/dp/B0BW6MP732
[winget]: https://github.com/microsoft/winget-pkgs/tree/master/manifests/l/LocalSend/LocalSend
[scoop]: https://scoop.sh/#/apps?s=0&d=1&o=true&q=localsend&id=fb88113be361ca32c0dcac423cb4afdeda0b0c66
[chocolatey]: https://community.chocolatey.org/packages/localsend
[homebrew]: https://formulae.brew.sh/cask/localsend
[flathub]: https://flathub.org/apps/details/org.localsend.localsend_app
[nixpkgs]: https://search.nixos.org/packages?show=localsend
[snap]: https://snapcraft.io/localsend
[aur]: https://aur.archlinux.org/packages/localsend-bin
[latest]: https://github.com/localsend/localsend/releases/latest
[distribution channels]: https://github.com/localsend/localsend/blob/main/CONTRIBUTING.md#distribution
[code signing policy]: https://github.com/localsend/localsend/blob/main/CODE_SIGNING.md

**Compatibility**

This is upstream file-transfer compatibility. Clipboard support has the narrower platform requirements listed under [Fork Changes](#fork-changes).

| Platform | Minimum Version | Note                                                                                                                        |
|----------|-----------------|-----------------------------------------------------------------------------------------------------------------------------|
| Android  | 7.0             | The last version to support Android 5 and 6 is v1.17.0.                                                                     |
| iOS      | 13.0            | The last version to support iOS 12 is v1.17.0. Sharing from other apps requires iOS 14 or later.                               |
| macOS    | 11 Big Sur      | Use OpenCore Legacy Patcher 2.0.2 (See [#1005](https://github.com/localsend/localsend/issues/1005#issuecomment-2449899384)) |
| Windows  | 10              | The last version to support Windows 7 is v1.15.4.   |
| Linux    | N.A.            | Deps: Gnome: `xdg-desktop-portal` and `xdg-desktop-portal-gtk`, KDE: `xdg-desktop-portal` and `xdg-desktop-portal-kde`      |

## Setup

In most cases, LocalSend should work out of the box. However, if you are having trouble sending or receiving files, you may need to configure your firewall to allow LocalSend to communicate over your local network.

| Traffic Type | Protocol | Port  | Action |
|--------------|----------|-------|--------|
| Incoming     | TCP, UDP | 53317 | Allow  |
| Outgoing     | TCP, UDP | Any   | Allow  |

On Linux, for example with `ufw`: `sudo ufw allow 53317`. With `firewalld`: `sudo firewall-cmd --permanent --add-port=53317/tcp`, `sudo firewall-cmd --permanent --add-port=53317/udp`, then `sudo firewall-cmd --reload`.

Also make sure to disable AP isolation on your router. It should be usually disabled by default but some routers may have it enabled (especially guest networks).
See [troubleshooting](#troubleshooting) for more information.

**Portable Mode**

(Introduced in v1.13.0)

Create a file named `settings.json` located in the same directory as the executable.
This file can be empty.
The app will use this file to store settings instead of the default location.

**Start hidden**

(Updated in v1.15.0)

To start the app hidden (only in tray), use the `--hidden` flag (example: `localsend_app.exe --hidden`).

On v1.14.0 and earlier, the app starts hidden if `autostart` flag is set, and the hidden setting is enabled.

## How It Works

LocalSend uses a secure communication protocol that allows devices to communicate with each other using a REST API. File and message data is sent securely over HTTPS, and the TLS/SSL certificate is generated on the fly on each device.

This fork's clipboard traffic uses a separate mutually authenticated TLS channel on TCP 53318, described above.

For more information on the LocalSend Protocol, see the [documentation](https://github.com/localsend/protocol).

## Dependency Hierarchy

![Dependency hierarchy](support/docs/dependency-hierarchy.svg)

## Getting Started

To compile LocalSend from the source code, follow these steps:

1. Install Flutter [directly](https://flutter.dev) or using [fvm](https://fvm.app) (see [version required](.fvmrc))
2. Install [Rust](https://www.rust-lang.org/tools/install)
3. Clone this fork for the clipboard feature, or the upstream repository for standard LocalSend
4. Run `cd app` to enter the app directory
5. Run `fvm flutter pub get` to download dependencies
6. Run `fvm flutter run` to start the app

> [!NOTE]
> LocalSend requires the pinned Flutter version specified in [.fvmrc](.fvmrc)
> and thus build issues may be caused by a mismatch between the required and the (system-wide) installed Flutter version.  
> To make development more consistent, LocalSend uses [fvm](https://fvm.app) to manage the project Flutter version.
> After installing `fvm`, run `fvm flutter` instead of `flutter`.

## Command Line Interface

The LocalSend CLI is a terminal client built on LocalSend Protocol v2.
Run `localsend-cli --help` to see every available option and hotkey.

Use the `send` command with one or more files, directories, or a mixture of both:

```shell
localsend-cli send report.pdf photo.jpg ./project-backup
```

The command opens the discovered-device list; select the destination interactively
and press Enter to start the transfer.

To select the destination without an interactive device list, pass its exact alias
or IP address:

```shell
localsend-cli send --to "Cute Tomato" report.pdf
localsend-cli send --to 192.168.27.26 report.pdf
```

An alias must uniquely identify a discovered device. An IP address is probed directly
over HTTPS on LocalSend's default port (`53317`).

To send a text message instead of files, use `--text` together with `--to`.
Pass `-` to read the text from stdin:

```shell
localsend-cli send --to "Cute Tomato" --text "https://localsend.org"
echo "Hello" | localsend-cli send --to "Cute Tomato" --text -
```

A single trailing line break is dropped from stdin. Text longer than 64 KB is sent as
a `.txt` file instead. Stdin must be UTF-8 and at most 16 MB; send other data as a file.

Directories are collected recursively. Their selected root names and nested paths
are preserved on the receiver. Empty directories are not sent because LocalSend
transfers file entries rather than directory entries.

## Contributing

We welcome contributions from anyone interested in helping improve LocalSend. If you'd like to contribute, there are a few ways to get involved:

### Translation

You can help translate LocalSend into other languages. We use the [Weblate](https://hosted.weblate.org/projects/localsend/app) platform to manage translations.

Alternatively, you can also contribute by forking this repository and adding translations manually.

The translations are located in the [app/assets/i18n](https://github.com/localsend/localsend/tree/main/app/assets/i18n) directory. Edit the `_missing_translations_<locale>.json` or `strings_<locale>.i18n.json` file to add or update translations.

<a href="https://hosted.weblate.org/engage/localsend/">
<img src="https://hosted.weblate.org/widget/localsend/app/multi-auto.svg" alt="Translation status" />
</a>

**_Take note:_ Fields decorated with `@` are not meant to be translated; they are not used in the app in any way, being merely informative text about the file or to give context to the translator.**

### Bug Fixes and Improvements

- **Bug Fixes:** If you find a bug, please create a pull request with a clear description of the issue and how to fix it.
- **Improvements:** Have an idea for how to improve LocalSend? Please create an issue first to discuss why the improvement is needed.

For more information, see the [contributing guide](https://github.com/localsend/localsend/blob/main/CONTRIBUTING.md).

## Troubleshooting

| Issue              | Platform (Sending) | Platform (Receiving) | Solution                                                                                                                                |
|--------------------|--------------------|----------------------|-----------------------------------------------------------------------------------------------------------------------------------------|
| Device not visible | Any                | Any                  | Make sure to disable AP-Isolation on your router. If it is enabled, connections between devices are forbidden.                          |
| Device not visible | Any                | Windows              | Make sure to configure your network as a "private" network. Windows might be more restrictive when the network is configured as public. |
| Device not visible | macOS, iOS         | Any                  | You can try to toggle the "Local Network" permission under "Privacy" in the OS settings.                                                |
| Device not visible | Any                | Any                  | If a VPN is active, allow local/LAN traffic or temporarily disable the VPN. Some VPNs block local network connections by default.       |
| Device not visible | Any                | Any                  | Use manual sending to enter the receiver's IP address directly. If that works, add the device to favorites so it is probed directly.    |
| Speed too slow     | Any                | Any                  | Use 5 Ghz; Disable encryption on both devices                                                                                           |
| Speed too slow     | Any                | Android              | Known issue. https://github.com/flutter-cavalry/saf_stream/issues/4                                                                     |

## Building

These commands are intended for maintainers only. Make sure to run them from the `app` directory.

### Android

Traditional APK

```bash
fvm flutter build apk
```

AppBundle for Google Play

```bash
fvm flutter build appbundle
```

### iOS

```bash
fvm flutter build ipa
```

### macOS

```bash
fvm flutter build macos
```

### Windows

**Traditional**

```bash
fvm flutter build windows
```

**Local MSIX App**

```bash
fvm flutter pub run msix:create
```

**Store ready**

```bash
fvm flutter pub run msix:create --store
```

### Linux

**Traditional**

```bash
fvm flutter build linux
```

**AppImage**

```bash
appimage-builder --recipe AppImageBuilder.yml
```

**Snap**

Instructions in [localsend/snap/README.md](https://github.com/localsend/snap/blob/main/README.md)

## Contributors

<a href="https://github.com/localsend/localsend/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=localsend/localsend"  alt="Localsend Contributors"/>
</a>
