import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/connection_log.dart';
import 'package:logging/logging.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('connection_log_test');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('appends lines and rotates into one older copy at the size cap', () async {
    // Each line is 20 bytes with its newline; the cap is reached after two.
    final log = ConnectionLogFile(File('${directory.path}/connection.log'), maxBytes: 40);
    await log.append('line 1 ............');
    await log.append('line 2 ............');
    expect(log.rotated.existsSync(), false);

    await log.append('line 3 ............');
    expect(await log.rotated.readAsLines(), ['line 1 ............', 'line 2 ............']);
    expect(await log.file.readAsLines(), ['line 3 ............']);

    await log.append('line 4 ............');
    await log.append('line 5 ............');
    // Only one older copy is kept; line 1 and 2 are gone.
    expect(await log.rotated.readAsLines(), ['line 3 ............', 'line 4 ............']);
    expect(await log.file.readAsLines(), ['line 5 ............']);
    expect(directory.listSync().length, 2);
  });

  test('concurrent appends never interleave', () async {
    final log = ConnectionLogFile(File('${directory.path}/connection.log'));
    await Future.wait([for (var i = 0; i < 50; i++) log.append('line $i')]);

    final lines = await log.file.readAsLines();
    expect(lines, [for (var i = 0; i < 50; i++) 'line $i']);
  });

  test('a write failure is swallowed and later writes still succeed', () async {
    final file = File('${directory.path}/missing/connection.log');
    final log = ConnectionLogFile(file);
    await log.append('lost');
    await file.parent.create();
    await log.append('kept');

    expect(await file.readAsString(), 'kept\n');
  });

  test('repeat filter drops identical messages within the window only', () {
    final filter = RepeatFilter(window: const Duration(minutes: 5), capacity: 2);
    final start = DateTime(2026, 11, 19, 10);

    expect(filter.allow('a', start), true);
    expect(filter.allow('a', start.add(const Duration(minutes: 1))), false);
    expect(filter.allow('b', start), true);
    expect(filter.allow('a', start.add(const Duration(minutes: 6))), true);
    // Capacity evicts the oldest key, which may then repeat immediately.
    expect(filter.allow('c', start), true);
    expect(filter.allow('b', start.add(const Duration(seconds: 1))), true);
  });

  test('records keep logger, level, message and error on one line', () {
    final record = LogRecord(Level.WARNING, 'Probe failed', 'ClipboardSync', const SocketException('unreachable'));
    final line = formatConnectionRecord(record);

    expect(line, contains('WARNING [ClipboardSync] Probe failed | error: SocketException: unreachable'));
    expect(line.contains('\n'), false);
  });

  test('only connection loggers are persisted, never provider state dumps', () {
    expect(connectionLoggers, contains('ClipboardSync'));
    expect(connectionLoggers, isNot(contains('Refena')));
  });
}
