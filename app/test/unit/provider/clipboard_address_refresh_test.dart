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
  final identity = 'B' * 64;
  final pendingIdentity = 'C' * 64;
  late RefenaContainer container;
  late String stored;
  late List<String> calls;
  late ClipboardSyncController controller;
  late Future<Map<String, String>> Function(Set<String>, List<String>) probe;

  setUp(() {
    calls = [];
    stored = jsonEncode({
      'version': 1,
      'certificate': 'fixture',
      'privateKey': 'fixture',
      'fingerprint': 'A' * 64,
      'enabled': true,
      'syncImages': true,
      'peers': [
        ClipboardPeer(fingerprint: identity, address: '192.168.100.85:53318', name: 'Phone', send: false).toJson(),
        ClipboardPeer(fingerprint: pendingIdentity, address: '192.0.2.1:53318', pending: true).toJson(),
      ],
    });
    probe = (pins, hosts) async {
      expect(pins, {identity});
      expect(hosts, ['172.16.185.127']);
      return {identity: '172.16.185.127:53318'};
    };
    controller = ClipboardSyncController(
      probePeers: (_, _, pins, hosts, port) {
        expect(port, 53318);
        return probe(pins, hosts);
      },
    );
    container = RefenaContainer(overrides: [clipboardSyncProvider.overrideWithNotifier((_) => controller)]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'loadSecret':
          return stored;
        case 'saveSecret':
          stored = (call.arguments as Map)['value'] as String;
          return null;
        case 'status':
          return {'supported': true, 'authorized': false};
        case 'stop':
          return null;
      }
      fail('Unexpected native operation: ${call.method}');
    });
  });
  tearDown(() {
    container.disposeContainer();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  group('clipboard address refresh', () {
    test('network change persists verified address and preserves pairing and sharing preferences', () async {
      await controller.initialize();
      await controller.refreshDiscoveredAddresses(['172.16.185.127', '172.16.185.127', 'invalid', '127.0.0.1', '224.0.0.1']);
      final state = container.read(clipboardSyncProvider);
      expect(state.peers.first.address, '172.16.185.127:53318');
      expect(state.peers.first.fingerprint, identity);
      expect(state.peers.first.name, 'Phone');
      expect(state.peers.first.send, false);
      expect(state.peers.first.receive, true);
      expect(state.peers.last.pending, true);
      expect(state.syncImages, true);
      expect((jsonDecode(stored) as Map)['peers'][0]['address'], '172.16.185.127:53318');
      expect(calls, isNot(contains('start')));
    });

    test('unverified hosts never replace a pairing or write configuration', () async {
      probe = (_, _) async => {};
      await controller.initialize();
      await controller.refreshDiscoveredAddresses(['172.16.185.127']);
      expect(container.read(clipboardSyncProvider).peers.first.address, '192.168.100.85:53318');
      expect(calls, isNot(contains('saveSecret')));
    });

    test('disable while probing prevents a late result from restarting sync', () async {
      final result = Completer<Map<String, String>>();
      probe = (_, _) => result.future;
      await controller.initialize();
      final refreshing = controller.refreshDiscoveredAddresses(['172.16.185.127']);
      await controller.setEnabled(false);
      calls.clear();
      result.complete({identity: '172.16.185.127:53318'});
      await refreshing;
      expect(container.read(clipboardSyncProvider).enabled, false);
      expect(container.read(clipboardSyncProvider).peers.first.address, '192.168.100.85:53318');
      expect(calls, isEmpty);
    });

    test('removing a pairing while probing cannot restore it', () async {
      final result = Completer<Map<String, String>>();
      probe = (_, _) => result.future;
      await controller.initialize();
      final refreshing = controller.refreshDiscoveredAddresses(['172.16.185.127']);
      await controller.setPeers([]);
      result.complete({identity: '172.16.185.127:53318'});
      await refreshing;
      expect(container.read(clipboardSyncProvider).peers, isEmpty);
    });

    test('probe errors preserve existing configuration', () async {
      probe = (_, _) async => throw const SocketException('unreachable');
      await controller.initialize();
      await controller.refreshDiscoveredAddresses(['172.16.185.127']);
      expect(container.read(clipboardSyncProvider).enabled, true);
      expect(calls, isNot(contains('saveSecret')));
    });

    test('disabled sharing does not probe discovered devices', () async {
      await controller.initialize();
      await controller.setEnabled(false);
      var probed = false;
      probe = (_, _) async {
        probed = true;
        return {};
      };
      calls.clear();
      await controller.refreshDiscoveredAddresses(['172.16.185.127']);
      expect(probed, false);
      expect(calls, isEmpty);
    });
  }, skip: !Platform.isWindows);
}
