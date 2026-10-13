import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:localsend_app/model/update/app_release.dart';
import 'package:localsend_app/util/update/update_version.dart';

const maxUpdateBytes = 1024 * 1024 * 1024;

class GitHubReleaseClient {
  static const defaultRepo = 'MichaelCommitsAt3AM/localsend';
  final String repo;
  GitHubReleaseClient({this.repo = defaultRepo}) {
    if (!RegExp(r'^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$').hasMatch(repo) || repo.split('/').any((p) => p == '.' || p == '..')) {
      throw const FormatException('Invalid update repository');
    }
  }
  static int compareVersions(String a, String b) => UpdateVersion.parse(a).compareTo(UpdateVersion.parse(b));
  static bool isNewerVersion(String latestVersion, String currentVersion) => compareVersions(latestVersion, currentVersion) > 0;
  static String currentArchitecture() => switch (Abi.current()) {
    Abi.androidArm64 || Abi.linuxArm64 || Abi.macosArm64 || Abi.windowsArm64 => 'arm64',
    Abi.androidArm => 'arm32v7',
    Abi.androidIA32 => 'x86',
    Abi.androidX64 || Abi.linuxX64 || Abi.macosX64 || Abi.windowsX64 => 'x64',
    _ => 'unsupported',
  };
  static AppReleaseAsset? findTargetAsset(AppRelease release, TargetPlatform platform, {String? architecture}) {
    final arch = architecture ?? currentArchitecture();
    if (arch == 'unsupported') return null;
    final suffixes = switch (platform) {
      TargetPlatform.windows =>
        arch == 'x64'
            ? ['windows-x86-64.exe', 'windows-x64-setup.exe']
            : arch == 'arm64'
            ? ['windows-arm-64.exe', 'windows-arm64-setup.exe']
            : <String>[],
      TargetPlatform.android => [
        'android-universal.apk',
        'android.apk',
        ...switch (arch) {
          'arm64' => ['android-arm64v8.apk', 'android-arm64-v8a.apk'],
          'arm32v7' => ['android-arm32v7.apk', 'android-armeabi-v7a.apk'],
          'x64' => ['android-x64.apk', 'android-x86_64.apk'],
          'x86' => ['android-x86.apk'],
          _ => <String>[],
        },
      ],
      TargetPlatform.linux =>
        arch == 'x64'
            ? ['linux-x86-64.AppImage', 'linux-x86_64.AppImage']
            : arch == 'arm64'
            ? ['linux-arm-64.AppImage', 'linux-aarch64.AppImage']
            : <String>[],
      TargetPlatform.macOS => ['macos-universal.dmg', 'macos.dmg', if (arch == 'arm64') 'macos-arm64.dmg', if (arch == 'x64') 'macos-x64.dmg'],
      _ => <String>[],
    };
    for (final suffix in suffixes) {
      for (final prefix in ['LocalSend', 'LocalSend-AutoSync']) {
        final match = release.assets.where((a) => a.name == '$prefix-${release.version}-$suffix').firstOrNull;
        if (match != null) return match;
      }
    }
    return null;
  }

  Uri releasePage([String? tag]) => Uri.https('github.com', '/$repo/releases${tag == null ? '/latest' : '/tag/$tag'}');
  void validateAsset(AppRelease release, AppReleaseAsset asset) {
    final expected = Uri.https('github.com', '/$repo/releases/download/${release.tagName}/${asset.name}');
    final actual = Uri.tryParse(asset.downloadUrl);
    if (actual == null ||
        actual.scheme != 'https' ||
        actual.host != 'github.com' ||
        actual.port != 443 ||
        actual.userInfo.isNotEmpty ||
        actual.hasQuery ||
        actual.hasFragment ||
        !const ListEquality<String>().equals(actual.pathSegments, expected.pathSegments) ||
        asset.size < 1 ||
        asset.size > maxUpdateBytes ||
        !RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(asset.digest ?? '') ||
        !RegExp(r'^[A-Za-z0-9+_.-]+$').hasMatch(asset.name)) {
      throw const FormatException('Release asset has an invalid URL, size or SHA-256 digest');
    }
  }

  Future<AppRelease?> fetchLatestRelease() {
    final repository = repo;
    return Isolate.run(() => _fetchLatest(repository));
  }
}

Future<AppRelease?> _fetchLatest(String repo) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final timer = Timer(const Duration(seconds: 45), () => client.close(force: true));
  try {
    final request = await client.getUrl(Uri.https('api.github.com', '/repos/$repo/releases/latest'));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.userAgentHeader, 'LocalSend-AutoSync');
    request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    request.headers.set('X-GitHub-Api-Version', '2022-11-28');
    final response = await request.close();
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) throw HttpException('Release check failed (${response.statusCode})');
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 15))) {
      if (bytes.length + chunk.length > 2 * 1024 * 1024) throw const FormatException('Release response is too large');
      bytes.addAll(chunk);
    }
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    if (json['draft'] != false || json['prerelease'] != false) throw const FormatException('Only published stable releases are supported');
    final release = AppRelease.fromJson(json);
    if (UpdateVersion.parse(release.version).prerelease.isNotEmpty) throw const FormatException('Only stable versions are supported');
    if (release.assets.length > 128) throw const FormatException('Too many release assets');
    return release;
  } finally {
    timer.cancel();
    client.close(force: true);
  }
}
