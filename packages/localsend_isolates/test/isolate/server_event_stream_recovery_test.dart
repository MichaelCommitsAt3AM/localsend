import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:typed_isolates/typed_isolates.dart';

Future<void> _holdTask(Stream<IsolateTask<void>> tasks, void Function(IsolateTaskStreamResult<int>) send, void _) async {
  await for (final task in tasks) {
    send(IsolateTaskStreamResult.event(id: task.id, data: 1));
    // Simulate a server task which normally listens indefinitely. It never
    // sends a done result; the parent must notice the isolate exiting instead.
  }
}

void main() {
  test('a killed server isolate closes outstanding task streams and a replacement can respond', () async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final connector = await TypedIsolates.startIsolate<IsolateTaskStreamResult<int>, IsolateTask<void>, void>(
        task: _holdTask,
        param: null,
      );
      addTearDown(() => connector.isolate.kill(priority: Isolate.immediate));
      final response = StreamIterator(connector.sendTaskAndListenStream(task: null));
      expect(await response.moveNext().timeout(const Duration(seconds: 3)), true);
      expect(response.current, 1);
      connector.isolate.kill(priority: Isolate.immediate);
      expect(await response.moveNext().timeout(const Duration(seconds: 3)), false);
      await response.cancel();
    }
  });
}
