import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/update/app_release.dart';
import 'package:localsend_app/provider/app_update_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/provider/version_provider.dart';
import 'package:localsend_app/util/update/github_release_client.dart';
import 'package:localsend_app/util/update/platform_installer.dart';
import 'package:localsend_app/util/update/verified_download.dart';
import 'package:path/path.dart' as p;
import 'package:refena_flutter/refena_flutter.dart';

class _Persistence extends Fake implements PersistenceService {
  bool autoCheck = false;
  @override
  bool isAutoCheckUpdates() => autoCheck;
  @override
  String? getDismissedUpdateTag() => null;
}

class _Client extends GitHubReleaseClient {
  final Future<AppRelease?> response;
  _Client(this.response);
  @override
  Future<AppRelease?> fetchLatestRelease() => response;
}

class _Download implements UpdateDownloadTask {
  final done = Completer<File>();
  bool cancelled = false;
  @override
  Future<File> get result => done.future;
  @override
  void cancel() {
    cancelled = true;
  }
}

void main() {
  late RefenaContainer container;
  AppUpdateNotifier mount(Future<AppRelease?> response) {
    container = RefenaContainer(
      overrides: [
        persistenceProvider.overrideWithValue(_Persistence()),
        versionProvider.overrideWithFuture((_) async => VersionData(version: '1.18.2', buildNumber: '64')),
        appUpdateProvider.overrideWithNotifier((_) => AppUpdateNotifier(client: _Client(response))),
      ],
    );
    return container.notifier(appUpdateProvider);
  }

  tearDown(() => container.disposeContainer());
  test('a failed check is distinguishable from up to date', () async {
    final ready = Completer<AppRelease?>();
    final controller = mount(ready.future);
    final checking = controller.checkForUpdates(isManual: true);
    ready.completeError(Exception('403'));
    await checking;
    expect(container.read(appUpdateProvider).checkResult, UpdateCheckResult.failed);
    expect(container.read(appUpdateProvider).stage, UpdateStage.failed);
  });
  test('no published release is not reported as up to date', () async {
    await mount(Future.value(null)).checkForUpdates(isManual: true);
    expect(container.read(appUpdateProvider).checkResult, UpdateCheckResult.noRelease);
  });
  test('manual discovery preserves a disabled automatic check preference', () async {
    final release = AppRelease(version: '1.19.0', tagName: 'v1.19.0', name: '', body: '', htmlUrl: '', publishedAt: null, assets: []);
    await mount(Future.value(release)).checkForUpdates(isManual: true);
    expect(container.read(appUpdateProvider).stage, UpdateStage.available);
    expect(container.read(appUpdateProvider).autoCheck, false);
    expect(container.read(appUpdateProvider).targetAsset, isNull);
  });
  test('automatic checking respects the saved opt-out', () async {
    final ready = Completer<AppRelease?>();
    await mount(ready.future).checkForUpdates();
    expect(container.read(appUpdateProvider).stage, UpdateStage.idle);
  });
  test('cancelled download cannot overwrite available state with an error and duplicate jobs are rejected', () async {
    final root = await Directory.systemTemp.createTemp('localsend-provider-tests-');
    final download = _Download();
    var started = 0;
    final jobStarted = Completer<void>();
    final asset = AppReleaseAsset(
      name: 'LocalSend-1.19.0-windows-x86-64.exe',
      downloadUrl: 'https://github.com/MichaelCommitsAt3AM/localsend/releases/download/v1.19.0/LocalSend-1.19.0-windows-x86-64.exe',
      size: 3,
      contentType: '',
      digest: 'sha256:${'0' * 64}',
    );
    final release = AppRelease(version: '1.19.0', tagName: 'v1.19.0', name: '', body: '', htmlUrl: '', publishedAt: null, assets: [asset]);
    container = RefenaContainer(
      overrides: [
        persistenceProvider.overrideWithValue(_Persistence()),
        versionProvider.overrideWithFuture((_) async => VersionData(version: '1.18.2', buildNumber: '64')),
        appUpdateProvider.overrideWithNotifier(
          (_) => AppUpdateNotifier(
            client: _Client(Future.value(release)),
            temporaryDirectory: () async => root,
            createDownload: (_, _, _) {
              started++;
              jobStarted.complete();
              return download;
            },
          ),
        ),
      ],
    );
    final controller = container.notifier(appUpdateProvider);
    try {
      await controller.checkForUpdates(isManual: true);
      final first = controller.downloadAndInstall();
      await jobStarted.future;
      await controller.downloadAndInstall();
      expect(started, 1);
      controller.cancelDownload();
      download.done.completeError(Exception('connection closed after cancellation'));
      await first;
      expect(download.cancelled, true);
      expect(container.read(appUpdateProvider).stage, UpdateStage.available);
      expect(container.read(appUpdateProvider).errorMessage, isNull);
      expect(await Directory('${root.path}/localsend-updates').list().toList(), isEmpty);
    } finally {
      if (!p.isWithin(Directory.systemTemp.absolute.path, root.absolute.path)) throw StateError('Unsafe test cleanup');
      await root.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);
  test('verified downloads require a separate install action, and tampering prevents installer launch', () async {
    final root = await Directory.systemTemp.createTemp('localsend-install-tests-');
    final download = _Download();
    final jobStarted = Completer<File>();
    var opened = 0;
    final bytes = [77, 90, 0];
    final asset = AppReleaseAsset(
      name: 'LocalSend-1.19.0-windows-x86-64.exe',
      downloadUrl: 'https://github.com/MichaelCommitsAt3AM/localsend/releases/download/v1.19.0/LocalSend-1.19.0-windows-x86-64.exe',
      size: 3,
      contentType: '',
      digest: 'sha256:${sha256.convert(bytes)}',
    );
    final release = AppRelease(version: '1.19.0', tagName: 'v1.19.0', name: '', body: '', htmlUrl: '', publishedAt: null, assets: [asset]);
    container = RefenaContainer(
      overrides: [
        persistenceProvider.overrideWithValue(_Persistence()),
        versionProvider.overrideWithFuture((_) async => VersionData(version: '1.18.2', buildNumber: '64')),
        appUpdateProvider.overrideWithNotifier(
          (_) => AppUpdateNotifier(
            client: _Client(Future.value(release)),
            temporaryDirectory: () async => root,
            createDownload: (_, file, _) {
              jobStarted.complete(file);
              return download;
            },
            installFile: (_) async {
              opened++;
              return InstallationOutcome.opened;
            },
          ),
        ),
      ],
    );
    try {
      final controller = container.notifier(appUpdateProvider);
      await controller.checkForUpdates(isManual: true);
      final pending = controller.downloadAndInstall();
      final file = await jobStarted.future;
      await file.writeAsBytes(bytes);
      download.done.complete(file);
      await pending;
      expect(container.read(appUpdateProvider).stage, UpdateStage.ready);
      expect(opened, 0);
      await controller.installDownloaded();
      expect(container.read(appUpdateProvider).stage, UpdateStage.installerOpened);
      expect(opened, 1);
      await file.writeAsBytes([77, 90, 1]);
      await controller.installDownloaded();
      expect(container.read(appUpdateProvider).stage, UpdateStage.failed);
      expect(opened, 1);
    } finally {
      if (!p.isWithin(Directory.systemTemp.absolute.path, root.absolute.path)) throw StateError('Unsafe test cleanup');
      await root.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);
}
