import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/update/app_release.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/version_provider.dart';
import 'package:localsend_app/util/update/github_release_client.dart';
import 'package:localsend_app/util/update/platform_installer.dart';
import 'package:localsend_app/util/update/verified_download.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

enum UpdateStage { idle, checking, available, downloading, ready, installing, installerOpened, replaced, failed }

enum UpdateCheckResult { none, current, noRelease, failed, available }

class AppUpdateState {
  final UpdateStage stage;
  final UpdateCheckResult checkResult;
  final AppRelease? release;
  final AppReleaseAsset? targetAsset;
  final double downloadProgress;
  final int bytesReceived;
  final int totalBytes;
  final String? errorMessage;
  final bool isDismissed;
  final bool autoCheck;
  const AppUpdateState({
    required this.stage,
    this.checkResult = UpdateCheckResult.none,
    this.release,
    this.targetAsset,
    this.downloadProgress = 0,
    this.bytesReceived = 0,
    this.totalBytes = 0,
    this.errorMessage,
    this.isDismissed = false,
    this.autoCheck = true,
  });
  bool get isBannerVisible => !isDismissed && release != null && stage != UpdateStage.idle && stage != UpdateStage.checking;
  AppUpdateState copyWith({
    UpdateStage? stage,
    UpdateCheckResult? checkResult,
    AppRelease? release,
    AppReleaseAsset? targetAsset,
    double? downloadProgress,
    int? bytesReceived,
    int? totalBytes,
    String? errorMessage,
    bool? isDismissed,
    bool? autoCheck,
    bool clearRelease = false,
  }) => AppUpdateState(
    stage: stage ?? this.stage,
    checkResult: checkResult ?? this.checkResult,
    release: clearRelease ? null : release ?? this.release,
    targetAsset: clearRelease ? null : targetAsset ?? this.targetAsset,
    downloadProgress: downloadProgress ?? this.downloadProgress,
    bytesReceived: bytesReceived ?? this.bytesReceived,
    totalBytes: totalBytes ?? this.totalBytes,
    errorMessage: errorMessage,
    isDismissed: isDismissed ?? this.isDismissed,
    autoCheck: autoCheck ?? this.autoCheck,
  );
}

final appUpdateProvider = NotifierProvider<AppUpdateNotifier, AppUpdateState>((ref) => AppUpdateNotifier(), debugLabel: 'AppUpdateProvider');

class AppUpdateNotifier extends Notifier<AppUpdateState> {
  final GitHubReleaseClient client;
  UpdateDownloadTask? _download;
  final Future<Directory> Function() temporaryDirectory;
  final UpdateDownloadTask Function(AppReleaseAsset, File, void Function(int)) createDownload;
  final Future<InstallationOutcome> Function(File) installFile;
  Directory? _staging;
  Directory? _stagingRoot;
  File? _verifiedFile;
  int _generation = 0;
  bool _downloadActive = false;
  AppUpdateNotifier({
    GitHubReleaseClient? client,
    Future<Directory> Function()? temporaryDirectory,
    UpdateDownloadTask Function(AppReleaseAsset, File, void Function(int))? createDownload,
    Future<InstallationOutcome> Function(File)? installFile,
  }) : client = client ?? GitHubReleaseClient(),
       temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       createDownload = createDownload ?? VerifiedDownload.new,
       installFile = installFile ?? PlatformInstaller.install;
  @override
  void dispose() {
    _generation++;
    _download?.cancel();
    super.dispose();
  }

  @override
  AppUpdateState init() => AppUpdateState(stage: UpdateStage.idle, autoCheck: ref.read(persistenceProvider).isAutoCheckUpdates());
  Future<void> setAutoCheck(bool value) async {
    await ref.read(persistenceProvider).setAutoCheckUpdates(value);
    state = state.copyWith(autoCheck: value);
  }

  Future<void> checkForUpdates({bool isManual = false}) async {
    if (_downloadActive || state.stage == UpdateStage.checking || state.stage == UpdateStage.installing) return;
    final persistence = ref.read(persistenceProvider);
    if (!isManual && !persistence.isAutoCheckUpdates()) return;
    state = state.copyWith(stage: UpdateStage.checking, checkResult: UpdateCheckResult.none);
    try {
      final release = await client.fetchLatestRelease();
      if (disposed) return;
      if (release == null) {
        state = state.copyWith(stage: UpdateStage.idle, checkResult: UpdateCheckResult.noRelease, clearRelease: true);
        return;
      }
      final current = await ref.future(versionProvider);
      if (disposed) return;
      final version = current.buildNumber.isEmpty ? current.version : '${current.version.split('+').first}+${current.buildNumber}';
      if (!GitHubReleaseClient.isNewerVersion(release.version, version)) {
        state = state.copyWith(stage: UpdateStage.idle, checkResult: UpdateCheckResult.current, clearRelease: true);
        return;
      }
      await _clearStaging();
      final platform = _platform();
      var asset = GitHubReleaseClient.findTargetAsset(release, platform);
      if (platform == TargetPlatform.linux && !PlatformInstaller.canSelfUpdateLinux) asset = null;
      if (asset != null) {
        try {
          client.validateAsset(release, asset);
        } catch (_) {
          asset = null;
        }
      }
      state = AppUpdateState(
        stage: UpdateStage.available,
        checkResult: UpdateCheckResult.available,
        release: release,
        targetAsset: asset,
        isDismissed: !isManual && persistence.getDismissedUpdateTag() == release.tagName,
        autoCheck: state.autoCheck,
      );
    } catch (_) {
      if (disposed) return;
      state = state.copyWith(stage: UpdateStage.failed, checkResult: UpdateCheckResult.failed, errorMessage: t.appUpdate.checkFailed);
    }
  }

  /// Downloads only. Installation requires the separate explicit UI action.
  Future<void> downloadAndInstall() async {
    if (_downloadActive || state.stage == UpdateStage.installing || state.stage == UpdateStage.ready || state.stage == UpdateStage.replaced) return;
    final release = state.release;
    final asset = state.targetAsset;
    if (release == null) return;
    if (asset == null) {
      await openReleaseInBrowser();
      return;
    }
    _downloadActive = true;
    final generation = ++_generation;
    state = state.copyWith(stage: UpdateStage.downloading, downloadProgress: 0, bytesReceived: 0, totalBytes: asset.size, isDismissed: false);
    try {
      client.validateAsset(release, asset);
      await _clearStaging();
      final root = Directory('${(await temporaryDirectory()).path}/localsend-updates');
      await root.create(recursive: true);
      if (await FileSystemEntity.type(root.path, followLinks: false) != FileSystemEntityType.directory) {
        throw const FileSystemException('Invalid update cache directory');
      }
      _stagingRoot = root;
      _staging = await root.createTemp('verified-');
      if (generation != _generation) throw UpdateCancelled();
      final file = File('${_staging!.path}/${asset.name}');
      final download = createDownload(asset, file, (bytes) {
        if (generation == _generation) state = state.copyWith(bytesReceived: bytes, totalBytes: asset.size, downloadProgress: bytes / asset.size);
      });
      _download = download;
      final verified = await download.result;
      if (generation != _generation) throw UpdateCancelled();
      _verifiedFile = verified;
      state = state.copyWith(stage: UpdateStage.ready, downloadProgress: 1);
    } catch (error) {
      await _clearStaging();
      if (!disposed && generation == _generation && error is! UpdateCancelled) {
        state = state.copyWith(stage: UpdateStage.failed, errorMessage: t.appUpdate.verificationFailed);
      }
    } finally {
      _download = null;
      _downloadActive = false;
    }
  }

  Future<void> installDownloaded() async {
    final file = _verifiedFile;
    final asset = state.targetAsset;
    if (file == null || asset == null || state.stage == UpdateStage.installing || _downloadActive) return;
    state = state.copyWith(stage: UpdateStage.installing);
    try {
      final path = file.path;
      final expectedSize = asset.size;
      final expectedHash = asset.digest!.substring(7).toLowerCase();
      final valid = await Isolate.run(() async {
        final artifact = File(path);
        return await artifact.length() == expectedSize && (await sha256.bind(artifact.openRead()).first).toString() == expectedHash;
      });
      if (!valid) throw const FormatException('Verified update changed');
      if (disposed) return;
      final outcome = await installFile(file);
      if (disposed) return;
      state = state.copyWith(stage: outcome == InstallationOutcome.replaced ? UpdateStage.replaced : UpdateStage.installerOpened);
    } catch (error) {
      if (disposed) return;
      final detail = error is PlatformException
          ? error.message
          : error is FileSystemException
          ? error.message
          : null;
      state = state.copyWith(stage: UpdateStage.failed, errorMessage: detail ?? t.appUpdate.installFailed);
    }
  }

  void cancelDownload() {
    if (!_downloadActive) return;
    _generation++;
    _download?.cancel();
    state = state.copyWith(stage: UpdateStage.available, downloadProgress: 0, bytesReceived: 0);
  }

  Future<void> _clearStaging() async {
    _verifiedFile = null;
    final staging = _staging;
    _staging = null;
    if (staging != null && await staging.exists()) {
      final root = _stagingRoot;
      if (root == null || await FileSystemEntity.type(staging.path, followLinks: false) != FileSystemEntityType.directory) return;
      final resolvedRoot = await root.resolveSymbolicLinks();
      final resolvedStaging = await staging.resolveSymbolicLinks();
      if (!p.isWithin(resolvedRoot, resolvedStaging) || p.dirname(resolvedStaging) != resolvedRoot) return;
      await Directory(resolvedStaging).delete(recursive: true);
    }
  }

  Future<void> dismissBanner() async {
    final tag = state.release?.tagName;
    if (tag != null) await ref.read(persistenceProvider).setDismissedUpdateTag(tag);
    state = state.copyWith(isDismissed: true);
  }

  Future<void> openReleaseInBrowser() async {
    try {
      if (await launchUrl(client.releasePage(state.release?.tagName), mode: LaunchMode.externalApplication)) return;
    } catch (_) {
      // Present the same actionable error for launch failures and missing browsers.
    }
    if (!disposed) state = state.copyWith(stage: UpdateStage.failed, errorMessage: t.appUpdate.openFailed);
  }

  void triggerDebugUpdateBanner({String version = '9.9.9'}) {
    if (!kDebugMode || _downloadActive) return;
    state = AppUpdateState(
      stage: UpdateStage.available,
      autoCheck: state.autoCheck,
      release: AppRelease(
        version: version,
        tagName: 'v$version',
        name: 'Debug preview',
        body: '',
        htmlUrl: client.releasePage().toString(),
        publishedAt: null,
        assets: const [],
      ),
    );
  }

  static TargetPlatform _platform() => Platform.isWindows
      ? TargetPlatform.windows
      : Platform.isAndroid
      ? TargetPlatform.android
      : Platform.isLinux
      ? TargetPlatform.linux
      : Platform.isMacOS
      ? TargetPlatform.macOS
      : defaultTargetPlatform;
}
