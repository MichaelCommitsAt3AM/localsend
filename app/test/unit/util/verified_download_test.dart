import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/update/platform_installer.dart';
import 'package:localsend_app/util/update/verified_download.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('localsend-update-tests-');
  });
  tearDown(() async {
    if (!p.isWithin(Directory.systemTemp.absolute.path, root.absolute.path)) throw StateError('Unsafe test cleanup');
    await root.delete(recursive: true);
  });
  const bytes = [1, 2, 3, 4];
  final digest = 'sha256:${sha256.convert(bytes)}';
  Future<File> write(List<List<int>> chunks, {String? hash, int size = 4, bool Function()? cancelled}) => writeVerifiedUpdate(
    Stream.fromIterable(chunks),
    File('${root.path}/update.exe'),
    size,
    hash ?? digest,
    cancelled: cancelled ?? () => false,
    onProgress: (_) {},
  );
  test('only a complete matching digest produces an installable file', () async {
    final file = await write([
      [1, 2],
      [3, 4],
    ]);
    expect(await file.readAsBytes(), bytes);
    expect(await File('${file.path}.part').exists(), false);
  });
  test('corrupt and truncated downloads leave no installable or partial file', () async {
    await expectLater(
      write([
        [1, 2, 3, 5],
      ]),
      throwsFormatException,
    );
    await expectLater(
      write([
        [1, 2],
      ]),
      throwsFormatException,
    );
    expect(await root.list().toList(), isEmpty);
  });
  test('excess bytes, missing digest and cancellation fail closed', () async {
    await expectLater(
      write([
        [1, 2, 3, 4, 5],
      ]),
      throwsFormatException,
    );
    await expectLater(write([bytes], hash: ''), throwsFormatException);
    await expectLater(write([bytes], cancelled: () => true), throwsA(isA<UpdateCancelled>()));
    expect(await root.list().toList(), isEmpty);
  });
  test('an interrupted stream cleans up the partial artifact', () async {
    await expectLater(
      writeVerifiedUpdate(
        Stream<List<int>>.error(const SocketException('interrupted')),
        File('${root.path}/update.exe'),
        4,
        digest,
        cancelled: () => false,
        onProgress: (_) {},
      ),
      throwsA(isA<SocketException>()),
    );
    expect(await root.list().toList(), isEmpty);
  });
  test('redirects cannot downgrade HTTPS or escape GitHub asset hosts', () {
    expect(isGitHubAssetHost(Uri.parse('https://release-assets.githubusercontent.com/asset')), true);
    expect(isGitHubAssetHost(Uri.parse('http://github.com/file')), false);
    expect(isGitHubAssetHost(Uri.parse('https://github.com.evil.test/file')), false);
    expect(isGitHubAssetHost(Uri.parse('https://github.com:444/file')), false);
  });
  List<int> image(int version) => [127, 69, 76, 70, 0, 0, 0, 0, 65, 73, 2, version];
  test('AppImage replacement keeps the previous version and does not execute it', () async {
    final current = File('${root.path}/LocalSend.AppImage');
    final update = File('${root.path}/verified.AppImage');
    await current.writeAsBytes(image(1));
    await update.writeAsBytes(image(2));
    await PlatformInstaller.replaceAppImage(update, current, makeExecutable: (_) async {});
    expect(await current.readAsBytes(), image(2));
    expect(await File('${current.path}.localsend-previous').readAsBytes(), image(1));
  });
  test('AppImage preparation failure preserves the installed version and cleans staging', () async {
    final current = File('${root.path}/LocalSend.AppImage');
    final update = File('${root.path}/verified.AppImage');
    await current.writeAsBytes(image(1));
    await update.writeAsBytes(image(2));
    await expectLater(
      PlatformInstaller.replaceAppImage(
        update,
        current,
        makeExecutable: (_) async {
          throw const FileSystemException('denied');
        },
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await current.readAsBytes(), image(1));
    expect(await File('${current.path}.localsend-new').exists(), false);
  });
}
