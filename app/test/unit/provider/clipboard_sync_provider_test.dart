import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/provider/clipboard_sync_provider.dart';
import 'package:localsend_isolates/rust/api/clipboard.dart';
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

  test('mutual pairing completion enables and persists clipboard and image sharing on both endpoints', () async {
    final identities = ['A' * 64, 'B' * 64];
    final secrets = {
      for (final identity in identities)
        identity: jsonEncode({
          'version': 1,
          'certificate': 'certificate-fixture',
          'privateKey': 'secret-private-key',
          'fingerprint': identity,
          'enabled': false,
          'syncImages': false,
          'peers': [],
        }),
    };
    var loading = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'loadSecret') return secrets[identities[loading++]];
      if (call.method == 'stop') return null;
      if (call.method == 'saveSecret') {
        final value = (call.arguments as Map)['value'] as String;
        secrets[(jsonDecode(value) as Map)['fingerprint'] as String] = value;
        return null;
      }
      if (call.method == 'authorize' || call.method == 'status') return {'authorized': false};
      fail('Unexpected native operation: ${call.method}');
    });
    final endpoints = [RefenaContainer(), RefenaContainer()];
    addTearDown(() {
      for (final endpoint in endpoints) {
        endpoint.disposeContainer();
      }
    });
    for (final endpoint in endpoints) {
      await endpoint.notifier(clipboardSyncProvider).initialize();
    }
    final updates = [
      for (var index = 0; index < 2; index++)
        RsPairingUpdate(
          revision: BigInt.one,
          phase: 'authorized',
          code: '',
          fingerprint: identities[1 - index],
          address: '192.0.2.${index + 1}:53318',
          name: 'Other device',
          expires: BigInt.zero,
        ),
    ];
    for (var index = 0; index < 2; index++) {
      await endpoints[index].notifier(clipboardSyncProvider).savePairing(updates[index], pending: true);
      expect(endpoints[index].read(clipboardSyncProvider).enabled, false);
      expect(endpoints[index].read(clipboardSyncProvider).syncImages, false);
    }
    expect(calls, isNot(contains('authorize')));
    for (var index = 0; index < 2; index++) {
      await endpoints[index].notifier(clipboardSyncProvider).savePairing(updates[index], pending: false);
      final state = endpoints[index].read(clipboardSyncProvider);
      expect(state.enabled, true);
      expect(state.syncImages, true);
      expect(state.peers.single.pending, false);
      // Missing OS authorization must never be bypassed by automatic activation.
      expect(state.running, false);
      final persisted = jsonDecode(secrets[identities[index]]!) as Map;
      expect(persisted['enabled'], true);
      expect(persisted['syncImages'], true);
      expect(persisted['hasEnabledBefore'], true);
    }
    expect(calls.where((call) => call == 'authorize'), hasLength(2));
    expect(calls, isNot(contains('start')));
  }, skip: !Platform.isWindows);

  test('a final pairing storage failure cannot enable sharing or discard the pending trust guard', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'loadSecret') return stored;
      if (call.method == 'stop') return null;
      if (call.method == 'saveSecret') {
        final value = (call.arguments as Map)['value'] as String;
        final json = jsonDecode(value) as Map;
        if (json['enabled'] == true) throw PlatformException(code: 'STORE_UNAVAILABLE');
        stored = value;
        return null;
      }
      fail('Unexpected native operation: ${call.method}');
    });
    final controller = container.notifier(clipboardSyncProvider);
    await controller.initialize();
    final update = RsPairingUpdate(
      revision: BigInt.one,
      phase: 'authorized',
      code: '',
      fingerprint: 'B' * 64,
      address: '192.0.2.2:53318',
      name: 'Other device',
      expires: BigInt.zero,
    );
    await controller.savePairing(update, pending: true);
    await expectLater(controller.savePairing(update, pending: false), throwsA(isA<PlatformException>()));
    final state = container.read(clipboardSyncProvider);
    expect(state.enabled, false);
    expect(state.syncImages, false);
    expect(state.peers.single.pending, true);
    expect(calls, isNot(contains('authorize')));
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
