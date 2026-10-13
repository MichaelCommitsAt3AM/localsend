# GitHub Releases updater

The updater checks published stable releases in
[`MichaelCommitsAt3AM/localsend`](https://github.com/MichaelCommitsAt3AM/localsend).
Settings offers manual checking and an automatic-startup-check preference.
Clipboard synchronization remains local-network-only. GitHub is used for release
metadata and app downloads, never for clipboard delivery.
Drafts and prereleases are excluded. A failed check or an unavailable release is
reported separately from being up to date.

Current release scope is **Windows and Android only**. Linux and macOS
implementation, testing and releases are deferred indefinitely. Existing updater
code for those platforms is retained for possible future work, with no support
commitment.

## Download and installation

Downloads run in a worker isolate, have connection/read/overall timeouts, and are
limited to 1 GiB. The client accepts only the expected repository's release URL
and HTTPS redirects to the permitted GitHub asset hosts. The exact declared size
and GitHub API `sha256:` digest must match before the partial file is promoted.
Cancellation and errors remove partial staging files. A missing digest disables
direct downloading and offers the release page instead.

After downloading, **Open installer** is a separate user action. The stored file
is hashed again before installation. No update is installed silently. The source
of trust is the GitHub repository and HTTPS-authenticated release metadata; this
does not constitute an independently signed update manifest. Protect publisher
access and use immutable published releases.

| Platform | Installation behavior |
| --- | --- |
| Windows | Opens the verified EXE through the Windows shell. The installer handles app closure and replacement. The fork installer uses its own installation ID and directory. |
| Android | Checks APK package name, strictly newer version code and the installed app's signing certificate, then opens the system installer. Installation permission and user approval remain required. |

Android debug and release builds have different package IDs and signing keys.
A production APK cannot update the current debug app. Preserve the same release
key, increase the version code, and keep using universal APKs for this workflow;
switching from split-ABI version-code schemes requires a deliberate migration.
Certificate rotation is not currently supported by the pre-install check.

## Fork version and Android identity

This fork starts at `1.0.0+65` in `app/pubspec.yaml`, independently of upstream's
version sequence. Use `v1.0.0` for its first release tag. Increase the public
semantic version and the numeric build code for each published release; never
reset or reuse the Android version code. For example, `1.0.1+66` is a bug-fix
release and `1.1.0+67` can introduce new features. Keep the CLI and Inno installer
versions synchronized with the public version.

At the owner's request, the release Android application ID remains
`org.localsend.localsend_app`; debug builds use `org.localsend.localsend_app.debug`.
The fork uses its own permanent release signing key. A fork release cannot update
or coexist with official LocalSend on Android because they share a package ID
and have different signers. Uninstall official LocalSend before installing the
fork; uninstalling removes its app data. Existing debug builds are separate and
cannot be upgraded in place by a release APK. Clipboard pairing and permissions
must be configured for the new release installation.

Windows uses the fork's separate installer identity and directory. The updater
checks only this fork's repository; upstream's version numbers do not determine
fork update ordering. Do not publish unchanged upstream artifacts into the fork's
release feed.

## Asset naming contract

Tags are `vMAJOR.MINOR.PATCH` and must match `app/pubspec.yaml`. Bump the semantic
version and build number for each public release. Also update the CLI version
and the upstream Inno version as required by repository CI.

Use these exact names, replacing `1.0.0` with the tag's version:

| Target | Asset name |
| --- | --- |
| Windows x64 | `LocalSend-1.0.0-windows-x86-64.exe` |
| Windows ARM64, when built | `LocalSend-1.0.0-windows-arm-64.exe` |
| Android universal | `LocalSend-1.0.0-android-universal.apk` |

The client also recognizes explicit architecture-specific APK aliases defined
in `GitHubReleaseClient`. It never guesses the first EXE, ZIP, DEB or arbitrary
asset, and CLI builds cannot be selected as GUI updates. A full release archive
is not used as an installer. Previously implemented DMG/AppImage selection and
installation code remains unvalidated and outside the current release scope.

## GitHub Actions setup

Use **Fork release draft**, from
[fork_release.yml](../../.github/workflows/fork_release.yml), rather than the
upstream release workflow. It runs on a matching `v*` tag or manually. It reads
Flutter's pinned version from `.fvmrc`, builds Windows x64 and a signed universal
Android APK, and creates a **draft** release. It refuses to replace assets of an
already published release. Uploaded assets must expose GitHub SHA-256 digests.
Nothing is published automatically.

Configure these repository Actions secrets before running the Android job:

- `FORK_ANDROID_KEYSTORE_BASE64`: base64 of the permanent release JKS.
- `FORK_ANDROID_STORE_PASSWORD`
- `FORK_ANDROID_KEY_PASSWORD`
- `FORK_ANDROID_KEY_ALIAS`

The workflow writes signing material only on the ephemeral runner. Do not commit
keystores or key.properties. Back up the permanent key securely; losing it prevents
in-place Android updates. The Windows fork job currently produces an unsigned
installer, so Windows may show publisher/SmartScreen warnings. Legacy signed
Windows jobs now use `WINDOWS_SIGNING_ACCOUNT`, `WINDOWS_SIGNING_PROFILE` and
`WINDOWS_SIGNING_ENDPOINT` repository variables, together with the existing Azure
login secrets, instead of upstream's signing identity.

The fork release workflow has only Windows and Android build jobs. It has no
Linux/macOS jobs or manual platform toggles, and no macOS signing secrets are
required for the current release scope. Upstream platform workflows remain
inherited tooling and are not the fork release process.

Review the draft assets and test an upgrade from a previously installed,
release-signed version on Windows and Android before publishing. Update Android's
verified-link association with the production signing fingerprint separately for
camera pairing. Linux/macOS native updater validation is deferred and does not
block these releases.

## Local validation

From `app/`:

```shell
fvm flutter analyze
fvm flutter test test/unit/util/github_release_client_test.dart
fvm flutter test test/unit/util/verified_download_test.dart
fvm flutter test test/unit/provider/app_update_provider_test.dart
fvm flutter test test/widget/app_update_banner_test.dart
```

These cover version/architecture selection, source restrictions, checksum and
length failure, interrupted/canceled downloads, staging cleanup, installer
rehashing, separate approval, state transitions, AppImage backup/preparation
failure and narrow layouts. They do not run downloaded installers.

References: [GitHub release assets and digests](https://docs.github.com/en/rest/releases/assets),
[AppImage update behavior](https://docs.appimage.org/packaging-guide/optional/updates.html),
[Android package installation](https://developer.android.com/reference/android/content/pm/PackageInstaller).
