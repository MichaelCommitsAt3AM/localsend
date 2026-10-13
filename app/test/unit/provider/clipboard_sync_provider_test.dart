import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/clipboard_sync_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('org.localsend.localsend_app/clipboard');
  late RefenaContainer container;
  late List<String> calls;
  late String stored;
  setUp(() {
    container = RefenaContainer();
    calls = [];
    stored = jsonEncode({
      'version': 1,
      'certificate': 'certificate-fixture',
      'privateKey': 'secret-private-key',
      'fingerprint': 'A' * 64,
      'enabled': false,
      'peers': [],
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'loadSecret') return stored;
      if (call.method == 'status') return {'supported': true, 'authorized': false, 'sequence': 0};
      fail('Unexpected native clipboard operation: ${call.method}');
    });
  });
  tearDown(() {
    container.disposeContainer();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('disabled startup loads identity without reading or monitoring the clipboard', () async {
    await container.notifier(clipboardSyncProvider).initialize();
    final state = container.read(clipboardSyncProvider);
    expect(state.ready, true);
    expect(state.enabled, false);
    expect(state.running, false);
    expect(state.syncImages, false);
    expect(state.hasEnabledBefore, false);
    expect(state.connectedPeers, isEmpty);
    expect(calls, ['loadSecret']);
    expect(state.pairingCode, isNot(contains('secret-private-key')));
    expect(state.pairingCode, isNot(contains('certificate-fixture')));
  }, skip: !Platform.isWindows);

  test('corrupt identity fails closed without generating replacement keys', () async {
    stored = 'invalid-existing-config';
    await container.notifier(clipboardSyncProvider).initialize();
    expect(container.read(clipboardSyncProvider).ready, false);
    expect(calls, ['loadSecret']);
  }, skip: !Platform.isWindows);

  test('image opt-in is persisted and restored without starting clipboard capture while sync is disabled', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'loadSecret') return stored;
      if (call.method == 'stop') return null;
      if (call.method == 'saveSecret') {
        stored = (call.arguments as Map)['value'] as String;
        return null;
      }
      fail('Unexpected native clipboard operation: ${call.method}');
    });
    final controller = container.notifier(clipboardSyncProvider);
    await controller.initialize();
    await controller.setSyncImages(true);
    expect(container.read(clipboardSyncProvider).syncImages, true);
    expect((jsonDecode(stored) as Map)['syncImages'], true);
    container.disposeContainer();
    container = RefenaContainer();
    await container.notifier(clipboardSyncProvider).initialize();
    expect(container.read(clipboardSyncProvider).syncImages, true);
    expect(container.read(clipboardSyncProvider).running, false);
    expect(calls, isNot(contains('read')));
    expect(calls, isNot(contains('start')));
    await container.notifier(clipboardSyncProvider).setSyncImages(false);
    expect((jsonDecode(stored) as Map)['syncImages'], false);
  }, skip: !Platform.isWindows);

  test('oversized stored trust set fails before clipboard activation', () async {
    final json = jsonDecode(stored) as Map<String, dynamic>;
    json['peers'] = List.generate(
      9,
      (i) => {'fingerprint': (i + 1).toRadixString(16).toUpperCase().padLeft(64, '0'), 'address': '192.0.2.1:53318', 'send': true, 'receive': true},
    );
    stored = jsonEncode(json);
    await container.notifier(clipboardSyncProvider).initialize();
    expect(container.read(clipboardSyncProvider).ready, false);
    expect(calls, ['loadSecret']);
  }, skip: !Platform.isWindows);

  test('incomplete persisted pairing cannot enable clipboard access', () async {
    final json = jsonDecode(stored) as Map<String, dynamic>;
    json['peers'] = [
      {'fingerprint': 'B' * 64, 'address': '192.0.2.1:53318', 'send': true, 'receive': true, 'pending': true, 'name': 'Phone'},
    ];
    stored = jsonEncode(json);
    await container.notifier(clipboardSyncProvider).initialize();
    await container.notifier(clipboardSyncProvider).setEnabled(true);
    expect(container.read(clipboardSyncProvider).enabled, false);
    expect(container.read(clipboardSyncProvider).running, false);
    expect(container.read(clipboardSyncProvider).peers.single.pending, true);
    expect(calls, ['loadSecret']);
  }, skip: !Platform.isWindows);

  test('missing native authorization does not start capture or transport', () async {
    final json = jsonDecode(stored) as Map<String, dynamic>;
    json['enabled'] = true;
    stored = jsonEncode(json);
    await container.notifier(clipboardSyncProvider).initialize();
    expect(container.read(clipboardSyncProvider).running, false);
    expect(calls, ['loadSecret', 'status']);
  }, skip: !Platform.isWindows);

  test('disable preempts an in-flight enable operation', () async {
    final json = jsonDecode(stored) as Map<String, dynamic>;
    json['peers'] = [
      {'fingerprint': 'B' * 64, 'address': '192.0.2.1:53318', 'send': true, 'receive': true},
    ];
    stored = jsonEncode(json);
    final status = Completer<Map<String, dynamic>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'loadSecret') return stored;
      if (call.method == 'status') return status.future;
      if (call.method == 'stop' || call.method == 'saveSecret') return null;
      fail('Unexpected native clipboard operation: ${call.method}');
    });
    final controller = container.notifier(clipboardSyncProvider);
    await controller.initialize();
    final enabling = controller.setEnabled(true);
    await Future<void>.delayed(Duration.zero);
    await controller.setEnabled(false);
    expect(container.read(clipboardSyncProvider).enabled, false);
    expect(calls, contains('stop'));
    status.complete({'supported': true, 'authorized': true, 'sequence': 0});
    await enabling;
    expect(calls, isNot(contains('start')));
  }, skip: !Platform.isWindows);

  test('first-enable history survives preference saves and loading older active installs skips onboarding', () async {
    final json = jsonDecode(stored) as Map<String, dynamic>;
    json['hasEnabledBefore'] = true;
    stored = jsonEncode(json);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'loadSecret') return stored;
      if (call.method == 'stop') return null;
      if (call.method == 'saveSecret') {
        stored = (call.arguments as Map)['value'] as String;
        return null;
      }
      fail('Unexpected native operation: ${call.method}');
    });
    final controller = container.notifier(clipboardSyncProvider);
    await controller.initialize();
    expect(container.read(clipboardSyncProvider).hasEnabledBefore, true);
    await controller.setSyncImages(true);
    expect((jsonDecode(stored) as Map)['hasEnabledBefore'], true);
    container.disposeContainer();
    container = RefenaContainer();
    final legacy = jsonDecode(stored) as Map<String, dynamic>;
    legacy.remove('hasEnabledBefore');
    legacy['enabled'] = true;
    stored = jsonEncode(legacy);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'loadSecret') return stored;
      if (call.method == 'status') return {'supported': true, 'authorized': false};
      fail('Unexpected native operation: ${call.method}');
    });
    await container.notifier(clipboardSyncProvider).initialize();
    expect(container.read(clipboardSyncProvider).hasEnabledBefore, true);
  }, skip: !Platform.isWindows);
}
