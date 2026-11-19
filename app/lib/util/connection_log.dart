import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

/// Loggers whose records are kept on disk to diagnose connection failures
/// after the fact. Others are excluded on purpose: the Refena logger dumps
/// whole provider states, which include secrets such as the show token.
const connectionLoggers = {
  'ClipboardSync',
  'ConnectionHealth',
  'Discovery',
  'NetworkInfo',
  'ReceiveController',
  'Send',
  'Server',
};

/// The file name of the current connection log, next to its rotated copy
/// `connection.log.1`.
const connectionLogName = 'connection.log';

/// Appends lines to a size-capped log file, keeping one rotated copy.
/// Writes are serialized so lines never interleave, and a failing disk never
/// throws into the caller: diagnostics must not break networking.
class ConnectionLogFile {
  final File file;
  final int maxBytes;
  Future<void> _queue = Future.value();
  int? _size;

  ConnectionLogFile(this.file, {this.maxBytes = 1024 * 1024});

  File get rotated => File('${file.path}.1');

  Future<void> append(String line) {
    final next = _queue.then((_) async {
      try {
        _size ??= await file.exists() ? await file.length() : 0;
        if (_size! >= maxBytes) {
          if (await rotated.exists()) await rotated.delete();
          await file.rename(rotated.path);
          _size = 0;
        }
        final text = '$line\n';
        await file.writeAsString(text, mode: FileMode.append, flush: true);
        _size = _size! + text.length;
      } catch (_) {
        // Re-read the size on the next write; the file may have been removed.
        _size = null;
      }
    });
    _queue = next;
    return next;
  }
}

/// Drops a message that repeats within [window], so chatty sources such as
/// re-announcing peers or periodic network checks cannot flush the history
/// that explains a failure.
class RepeatFilter {
  final Duration window;
  final int capacity;
  final _lastSeen = <String, DateTime>{};

  RepeatFilter({this.window = const Duration(minutes: 5), this.capacity = 512});

  bool allow(String key, DateTime now) {
    final last = _lastSeen[key];
    if (last != null && now.difference(last) < window) return false;
    if (_lastSeen.length >= capacity) _lastSeen.remove(_lastSeen.keys.first);
    _lastSeen.remove(key);
    _lastSeen[key] = now;
    return true;
  }
}

String formatConnectionRecord(LogRecord record) {
  final buffer = StringBuffer('${record.time.toIso8601String()} ${record.level.name.padRight(7)} [${record.loggerName}] ${record.message}');
  if (record.error != null) buffer.write(' | error: ${record.error}');
  return buffer.toString();
}

/// Where the connection log lives. On Android this is the app-specific
/// external folder (`Android/data/<package>/files/logs`), readable over ADB
/// without root and removed with the app.
Future<Directory> connectionLogDirectory() async {
  final base = Platform.isAndroid
      ? await getExternalStorageDirectory() ?? await getApplicationSupportDirectory()
      : await getApplicationSupportDirectory();
  return Directory('${base.path}${Platform.pathSeparator}logs');
}

StreamSubscription<LogRecord>? _subscription;

/// Starts mirroring connection-related log records of this isolate to disk.
Future<void> startConnectionLog({required String appVersion}) async {
  if (_subscription != null) return;
  try {
    final directory = await connectionLogDirectory();
    await directory.create(recursive: true);
    final log = ConnectionLogFile(File('${directory.path}${Platform.pathSeparator}$connectionLogName'));
    final repeats = RepeatFilter();
    await log.append(
      '${DateTime.now().toIso8601String()} INFO    [ConnectionLog] App started: version $appVersion, ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    );
    _subscription = Logger.root.onRecord.listen((record) {
      if (!connectionLoggers.contains(record.loggerName) || record.level < Level.INFO) return;
      if (!repeats.allow('${record.loggerName}|${record.level.name}|${record.message}', record.time)) return;
      unawaited(log.append(formatConnectionRecord(record)));
    });
  } catch (error) {
    Logger('ConnectionLog').warning('Connection log unavailable', error);
  }
}
