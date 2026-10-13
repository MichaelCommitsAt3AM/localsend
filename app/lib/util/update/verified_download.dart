import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:localsend_app/model/update/app_release.dart';
import 'package:localsend_app/util/update/github_release_client.dart';

class UpdateCancelled implements Exception {}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// Bounded streamed write with a final digest/length gate. Partial files are never
/// installable. Kept independent of HTTP so corruption and cancellation are testable.
Future<File> writeVerifiedUpdate(
  Stream<List<int>> stream,
  File destination,
  int size,
  String digest, {
  required bool Function() cancelled,
  required void Function(int) onProgress,
}) async {
  if (size < 1 || size > maxUpdateBytes || !RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest)) {
    throw const FormatException('Invalid update integrity metadata');
  }
  final partial = File('${destination.path}.part');
  RandomAccessFile? output;
  var success = false;
  try {
    if (cancelled()) throw UpdateCancelled();
    output = await partial.open(mode: FileMode.write);
    final result = _DigestSink();
    final hash = sha256.startChunkedConversion(result);
    var received = 0;
    await for (final chunk in stream.timeout(const Duration(seconds: 30))) {
      if (cancelled()) throw UpdateCancelled();
      received += chunk.length;
      if (received > size) throw const FormatException('Update exceeds declared size');
      hash.add(chunk);
      await output.writeFrom(chunk);
      onProgress(received);
    }
    hash.close();
    if (cancelled()) throw UpdateCancelled();
    if (received != size || result.value.toString() != digest.substring(7).toLowerCase()) {
      throw const FormatException('Update integrity verification failed');
    }
    await output.flush();
    await output.close();
    output = null;
    await partial.rename(destination.path);
    success = true;
    return destination;
  } finally {
    await output?.close();
    if (!success && await partial.exists()) await partial.delete();
  }
}

abstract class UpdateDownloadTask {
  Future<File> get result;
  void cancel();
}

class VerifiedDownload implements UpdateDownloadTask {
  final ReceivePort _events = ReceivePort();
  final Completer<File> _result = Completer<File>();
  SendPort? _control;
  bool _cancelled = false;
  @override
  Future<File> get result => _result.future;
  @override
  void cancel() {
    _cancelled = true;
    _control?.send('cancel');
  }

  VerifiedDownload(AppReleaseAsset asset, File destination, void Function(int) onProgress) {
    _events.listen((dynamic message) {
      if (message is! Map) {
        _events.close();
        if (!_result.isCompleted) _result.completeError(Exception('Update worker stopped unexpectedly'));
        return;
      }
      final event = message;
      switch (event['kind']) {
        case 'control':
          _control = event['port'] as SendPort;
          if (_cancelled) _control!.send('cancel');
        case 'progress':
          if (!_cancelled) onProgress(event['bytes'] as int);
        case 'done':
          _events.close();
          _result.complete(File(destination.path));
        case 'cancelled':
          _events.close();
          _result.completeError(UpdateCancelled());
        case 'error':
          _events.close();
          _result.completeError(Exception(event['message']));
      }
    });
    unawaited(_spawn(asset, destination));
  }
  Future<void> _spawn(AppReleaseAsset asset, File destination) async {
    try {
      await Isolate.spawn(_downloadWorker, [asset, destination.path, _events.sendPort], onError: _events.sendPort, onExit: _events.sendPort);
    } catch (error) {
      _events.close();
      if (!_result.isCompleted) _result.completeError(error);
    }
  }
}

bool isGitHubAssetHost(Uri uri) =>
    uri.scheme == 'https' &&
    uri.userInfo.isEmpty &&
    uri.port == 443 &&
    {
      'github.com',
      'release-assets.githubusercontent.com',
      'objects.githubusercontent.com',
      'github-releases.githubusercontent.com',
    }.contains(uri.host);

Future<void> _downloadWorker(List<dynamic> args) async {
  final asset = args[0] as AppReleaseAsset;
  final destination = File(args[1] as String);
  final events = args[2] as SendPort;
  final controls = ReceivePort();
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..autoUncompress = false;
  var cancelled = false;
  var timedOut = false;
  controls.listen((_) {
    cancelled = true;
    client.close(force: true);
  });
  events.send({'kind': 'control', 'port': controls.sendPort});
  final deadline = Timer(const Duration(minutes: 20), () {
    timedOut = true;
    client.close(force: true);
  });
  try {
    var uri = Uri.parse(asset.downloadUrl);
    HttpClientResponse? response;
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (cancelled) throw UpdateCancelled();
      if (!isGitHubAssetHost(uri)) throw const FormatException('Untrusted update redirect');
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, 'LocalSend-AutoSync');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      response = await request.close().timeout(const Duration(seconds: 30));
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || redirects == 5) throw const FormatException('Invalid update redirect');
        uri = uri.resolve(location);
        continue;
      }
      break;
    }
    if (response == null || response.statusCode != 200 || (response.contentLength >= 0 && response.contentLength != asset.size)) {
      throw const HttpException('Update response size or status is invalid');
    }
    var lastProgress = DateTime.fromMillisecondsSinceEpoch(0);
    await writeVerifiedUpdate(
      response,
      destination,
      asset.size,
      asset.digest!,
      cancelled: () => cancelled || timedOut,
      onProgress: (bytes) {
        final now = DateTime.now();
        if (now.difference(lastProgress).inMilliseconds >= 150 || bytes == asset.size) {
          events.send({'kind': 'progress', 'bytes': bytes});
          lastProgress = now;
        }
      },
    );
    events.send({'kind': 'done'});
  } catch (error) {
    events.send(
      cancelled
          ? {'kind': 'cancelled'}
          : {'kind': 'error', 'message': timedOut ? 'Update download timed out' : 'Update download or verification failed'},
    );
  } finally {
    deadline.cancel();
    controls.close();
    client.close(force: true);
  }
}
