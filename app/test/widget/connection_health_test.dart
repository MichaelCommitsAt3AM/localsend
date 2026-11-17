import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/widget/watcher/life_cycle_watcher.dart';

void main() {
  testWidgets('checks while open, pauses in background, checks on resume and stops on disposal', (tester) async {
    var checks = 0;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      LifeCycleWatcher(
        onChangedState: (_) {},
        checkConnections: () async {
          checks++;
        },
        child: const SizedBox(),
      ),
    );
    await tester.pump(const Duration(seconds: 15));
    expect(checks, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(minutes: 2));
    expect(checks, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(checks, 2);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 2));
    expect(checks, 2);
  });
  testWidgets('checks do not overlap and recover after errors', (tester) async {
    var checks = 0;
    final pending = Completer<void>();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      LifeCycleWatcher(
        onChangedState: (_) {},
        checkConnections: () {
          checks++;
          return checks == 1 ? pending.future : Future.value();
        },
        child: const SizedBox(),
      ),
    );
    await tester.pump(const Duration(seconds: 15));
    await tester.pump(const Duration(seconds: 45));
    expect(checks, 1);
    pending.completeError(StateError('temporary network failure'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 15));
    expect(checks, 2);
    await tester.pumpWidget(const SizedBox());
  });
}
