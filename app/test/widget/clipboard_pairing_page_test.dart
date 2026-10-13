import 'dart:async';

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

import '../fakes/pairing_session.dart';
import '../mocks.mocks.dart';

class _Isolates extends Fake implements IsolateController {}

class _Controller extends ClipboardSyncController {
  final Future<RsClipboardPairing> result;
  _Controller(this.result);
  @override
  Future<RsClipboardPairing> hostPairing({required String name}) => result;
  final saves = <bool>[];
  @override
  Future<void> savePairing(RsPairingUpdate update, {required bool pending}) async => saves.add(pending);
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
    final session = PairingSessionFake();
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
    final session = PairingSessionFake();
    starting.complete(session);
    await tester.pump();
    expect(session.stops, 1);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('receiver must accept before a code is displayed and code alone does not save trust', (tester) async {
    final session = PairingSessionFake();
    final controller = _Controller(Future.value(session));
    await mount(tester, controller);
    session.emit('request');
    await tester.pumpAndSettle();
    expect(find.text(t.clipboardSync.pairingRequest(device: 'Other device')), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(session.approvals, isEmpty);
    await tester.tap(find.text(t.clipboardSync.acceptRequest));
    await tester.pump();
    expect(session.approvals, [true]);
    session.emit('display_code', code: '01234567');
    await tester.pumpAndSettle();
    expect(find.text('0123 4567'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(controller.saves, isEmpty);
    await tester.tap(find.text(t.general.cancel));
    await tester.pumpAndSettle();
    expect(controller.saves, isEmpty);
  });

  testWidgets('requester types eight digits, retries an incorrect code, and only saves after authentication', (tester) async {
    final session = PairingSessionFake();
    final controller = _Controller(Future.value(session));
    await mount(tester, controller);
    session.emit('enter_code');
    await tester.pumpAndSettle();
    expect(find.text(t.clipboardSync.displayCodeTitle), findsNothing);
    await tester.enterText(find.byType(TextField), '123');
    await tester.tap(find.text(t.clipboardSync.confirmCode));
    await tester.pump();
    expect(find.text(t.clipboardSync.codeLengthError), findsOneWidget);
    expect(session.codes, isEmpty);
    await tester.enterText(find.byType(TextField), '01234567');
    await tester.tap(find.text(t.clipboardSync.confirmCode));
    await tester.pump();
    expect(session.codes, ['01234567']);
    expect(controller.saves, isEmpty);
    session.emit('code_incorrect');
    await tester.pumpAndSettle();
    expect(find.text(t.clipboardSync.incorrectCode), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    await tester.enterText(find.byType(TextField), '76543210');
    await tester.tap(find.text(t.clipboardSync.confirmCode));
    await tester.pump();
    session.emit('authorized');
    await tester.pump();
    expect(controller.saves, [true]);
    expect(session.persistedValues, [true]);
    session.emit('complete');
    await tester.pumpAndSettle();
    expect(controller.saves, [true, false]);
    expect(find.text(t.clipboardSync.paired), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
