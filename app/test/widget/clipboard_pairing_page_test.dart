import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/settings/clipboard_pairing_page.dart';
import 'package:localsend_app/provider/clipboard_sync_provider.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/rust/api/clipboard.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../mocks.mocks.dart';

class _Isolates extends Fake implements IsolateController {}

class _Session extends Fake implements RsClipboardPairing {
  final updates = Completer<RsPairingUpdate?>();
  int stops = 0;
  @override
  Future<String?> invitation() async => jsonEncode({
    'version': 2,
    'kind': 'localsend-clipboard-pair',
    'fingerprint': 'A' * 64,
    'port': 53319,
    'addresses': ['192.0.2.1'],
    'token': 'B' * 64,
    'expires': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 180,
  });
  @override
  Future<RsPairingUpdate?> nextUpdate({required BigInt after}) => updates.future;
  @override
  Future<void> stop() async {
    stops++;
    if (!updates.isCompleted) updates.complete(null);
  }
}

class _Controller extends ClipboardSyncController {
  final Future<RsClipboardPairing> result;
  _Controller(this.result);
  @override
  Future<RsClipboardPairing> hostPairing({required String name}) => result;
}

void main() {
  Future<void> mount(WidgetTester tester, _Controller controller) async {
    final persistence = MockPersistenceService();
    await tester.pumpWidget(
      RefenaScope(
        overrides: [
          persistenceProvider.overrideWithValue(persistence),
          nearbyDevicesProvider.overrideWithNotifier(
            (_) => NearbyDevicesService(
              isolateController: _Isolates(),
              favoriteService: FavoritesService(persistence),
              discoveryLogs: DiscoveryLogger(),
            ),
          ),
        ],
        child: MaterialApp(
          home: ClipboardPairingPage(controller: controller, deviceName: 'Computer'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('opening Add device reaches the QR screen without an inherited-widget lifecycle exception', (tester) async {
    final session = _Session();
    await mount(tester, _Controller(Future.value(session)));
    expect(tester.takeException(), isNull);
    expect(find.text(t.clipboardSync.qrInstructions), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(session.stops, 1);
  });

  testWidgets('a stalled host startup shows retry and stops a late session', (tester) async {
    final starting = Completer<RsClipboardPairing>();
    await mount(tester, _Controller(starting.future));
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
    expect(find.text(t.clipboardSync.pairingFailed), findsOneWidget);
    expect(find.text(t.clipboardSync.tryAgain), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    final session = _Session();
    starting.complete(session);
    await tester.pump();
    expect(session.stops, 1);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
