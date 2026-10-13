import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/model/update/app_release.dart';
import 'package:localsend_app/util/update/github_release_client.dart';

void main() {
  group('GitHubReleaseClient version comparisons', () {
    test('detects higher major version', () {
      expect(GitHubReleaseClient.isNewerVersion('2.0.0', '1.18.2'), isTrue);
      expect(GitHubReleaseClient.isNewerVersion('v2.0.0', '1.18.2'), isTrue);
    });

    test('detects higher minor version', () {
      expect(GitHubReleaseClient.isNewerVersion('1.19.0', '1.18.2'), isTrue);
      expect(GitHubReleaseClient.isNewerVersion('v1.19.0', 'v1.18.2'), isTrue);
    });

    test('detects higher patch version', () {
      expect(GitHubReleaseClient.isNewerVersion('1.18.3', '1.18.2'), isTrue);
      expect(GitHubReleaseClient.isNewerVersion('v1.18.3', '1.18.2'), isTrue);
    });

    test('detects higher build number when base matches', () {
      expect(GitHubReleaseClient.isNewerVersion('1.18.2+65', '1.18.2+64'), isTrue);
      expect(GitHubReleaseClient.isNewerVersion('1.18.2+64', '1.18.2+65'), isFalse);
    });

    test('rejects identical versions', () {
      expect(GitHubReleaseClient.isNewerVersion('1.18.2', '1.18.2'), isFalse);
      expect(GitHubReleaseClient.isNewerVersion('v1.18.2', '1.18.2'), isFalse);
    });

    test('rejects older versions', () {
      expect(GitHubReleaseClient.isNewerVersion('1.17.0', '1.18.2'), isFalse);
      expect(GitHubReleaseClient.isNewerVersion('v1.18.1', '1.18.2'), isFalse);
    });
  });

  group('GitHubReleaseClient asset matching', () {
    final release = AppRelease(
      version: '1.19.0',
      tagName: 'v1.19.0',
      name: 'LocalSend v1.19.0',
      body: 'Changelog',
      htmlUrl: 'https://github.com/test/repo/releases/v1.19.0',
      publishedAt: DateTime.now(),
      assets: const [
        AppReleaseAsset(
          name: 'LocalSend-1.19.0-windows-portable.exe',
          downloadUrl: 'https://download/portable.exe',
          size: 30000000,
          contentType: 'application/x-msdownload',
        ),
        AppReleaseAsset(
          name: 'LocalSend-1.19.0-windows-x64-setup.exe',
          downloadUrl: 'https://download/setup.exe',
          size: 32000000,
          contentType: 'application/x-msdownload',
        ),
        AppReleaseAsset(
          name: 'LocalSend-1.19.0-android-arm64-v8a.apk',
          downloadUrl: 'https://download/arm64.apk',
          size: 25000000,
          contentType: 'application/vnd.android.package-archive',
        ),
        AppReleaseAsset(
          name: 'LocalSend-1.19.0-linux-x86_64.AppImage',
          downloadUrl: 'https://download/appimage',
          size: 40000000,
          contentType: 'application/x-executable',
        ),
        AppReleaseAsset(
          name: 'LocalSend-1.19.0-linux-amd64.deb',
          downloadUrl: 'https://download/deb',
          size: 38000000,
          contentType: 'application/vnd.debian.binary-package',
        ),
      ],
    );

    test('selects setup installer for Windows', () {
      final asset = GitHubReleaseClient.findTargetAsset(release, TargetPlatform.windows);
      expect(asset, isNotNull);
      expect(asset!.name, 'LocalSend-1.19.0-windows-x64-setup.exe');
      expect(asset.downloadUrl, 'https://download/setup.exe');
    });

    test('selects arm64 apk for Android', () {
      final asset = GitHubReleaseClient.findTargetAsset(release, TargetPlatform.android, architecture: 'arm64');
      expect(asset, isNotNull);
      expect(asset!.name, 'LocalSend-1.19.0-android-arm64-v8a.apk');
      expect(asset.downloadUrl, 'https://download/arm64.apk');
    });

    test('selects AppImage for Linux', () {
      final asset = GitHubReleaseClient.findTargetAsset(release, TargetPlatform.linux);
      expect(asset, isNotNull);
      expect(asset!.name, 'LocalSend-1.19.0-linux-x86_64.AppImage');
      expect(asset.downloadUrl, 'https://download/appimage');
    });

    test('does not select a distro package for direct self-update', () {
      final debRelease = AppRelease(
        version: '1.19.0',
        tagName: 'v1.19.0',
        name: 'LocalSend v1.19.0',
        body: '',
        htmlUrl: '',
        publishedAt: null,
        assets: const [
          AppReleaseAsset(
            name: 'LocalSend-1.19.0-linux-amd64.deb',
            downloadUrl: 'https://download/deb',
            size: 38000000,
            contentType: 'application/vnd.debian.binary-package',
          ),
        ],
      );
      final asset = GitHubReleaseClient.findTargetAsset(debRelease, TargetPlatform.linux);
      expect(asset, isNull);
    });
  });
  test('stable releases supersede release candidates and prerelease identifiers use SemVer ordering', () {
    expect(GitHubReleaseClient.compareVersions('1.19.0', '1.19.0-rc.1'), greaterThan(0));
    expect(GitHubReleaseClient.compareVersions('1.19.0-rc.10', '1.19.0-rc.2'), greaterThan(0));
    expect(() => GitHubReleaseClient.compareVersions('not-a-version', '1.0.0'), throwsFormatException);
  });
  test('unsupported Windows assets are not guessed', () {
    AppRelease only(String name) => AppRelease(
      version: '1.19.0',
      tagName: 'v1.19.0',
      name: '',
      body: '',
      htmlUrl: '',
      publishedAt: null,
      assets: [AppReleaseAsset(name: name, downloadUrl: '', size: 1, contentType: '')],
    );
    expect(GitHubReleaseClient.findTargetAsset(only('LocalSend-CLI-1.19.0-windows-x86-64.exe'), TargetPlatform.windows, architecture: 'x64'), isNull);
    expect(GitHubReleaseClient.findTargetAsset(only('LocalSend-1.19.0-android-universal.apk'), TargetPlatform.windows, architecture: 'x64'), isNull);
    expect(GitHubReleaseClient.findTargetAsset(only('LocalSend-1.19.0-windows-arm-64.exe'), TargetPlatform.windows, architecture: 'x64'), isNull);
  });
  test('macOS matches a universal disk image and Android matches device architecture', () {
    final release = AppRelease(
      version: '1.19.0',
      tagName: 'v1.19.0',
      name: '',
      body: '',
      htmlUrl: '',
      publishedAt: null,
      assets: [
        'macos-universal.dmg',
        'android-arm64v8.apk',
        'android-x64.apk',
      ].map((s) => AppReleaseAsset(name: 'LocalSend-1.19.0-$s', downloadUrl: '', size: 1, contentType: '')).toList(),
    );
    expect(GitHubReleaseClient.findTargetAsset(release, TargetPlatform.macOS, architecture: 'arm64')!.name, endsWith('macos-universal.dmg'));
    expect(GitHubReleaseClient.findTargetAsset(release, TargetPlatform.android, architecture: 'x64')!.name, endsWith('android-x64.apk'));
  });
  test('Android prefers a matching split APK and falls back to universal for older releases', () {
    final release = AppRelease(
      version: '1.19.0',
      tagName: 'v1.19.0',
      name: '',
      body: '',
      htmlUrl: '',
      publishedAt: null,
      assets: [
        'universal',
        'arm64-v8a',
        'armeabi-v7a',
        'x86_64',
      ].map((abi) => AppReleaseAsset(name: 'LocalSend-1.19.0-android-$abi.apk', downloadUrl: '', size: 1, contentType: '')).toList(),
    );
    for (final entry in {'arm64': 'arm64-v8a', 'arm32v7': 'armeabi-v7a', 'x64': 'x86_64', 'x86': 'universal'}.entries) {
      expect(
        GitHubReleaseClient.findTargetAsset(release, TargetPlatform.android, architecture: entry.key)!.name,
        'LocalSend-1.19.0-android-${entry.value}.apk',
      );
    }
  });
  test('direct updates require a pinned repository URL, bounded size and GitHub SHA-256 digest', () {
    final client = GitHubReleaseClient();
    final release = AppRelease(version: '1.19.0', tagName: 'v1.19.0', name: '', body: '', htmlUrl: '', publishedAt: null, assets: []);
    AppReleaseAsset asset(String url, {String? digest, int size = 3}) =>
        AppReleaseAsset(name: 'LocalSend-1.19.0-windows-x86-64.exe', downloadUrl: url, size: size, contentType: '', digest: digest);
    const url = 'https://github.com/MichaelCommitsAt3AM/localsend/releases/download/v1.19.0/LocalSend-1.19.0-windows-x86-64.exe';
    final digest = 'sha256:${'0' * 64}';
    expect(() => client.validateAsset(release, asset(url, digest: digest)), returnsNormally);
    expect(() => client.validateAsset(release, asset(url)), throwsFormatException);
    expect(() => client.validateAsset(release, asset(url.replaceFirst('https:', 'http:'), digest: digest)), throwsFormatException);
    expect(() => client.validateAsset(release, asset(url.replaceFirst('MichaelCommitsAt3AM', 'other'), digest: digest)), throwsFormatException);
    expect(() => client.validateAsset(release, asset(url, digest: digest, size: maxUpdateBytes + 1)), throwsFormatException);
  });
}
