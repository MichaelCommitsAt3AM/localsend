import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/settings/clipboard_pairing_page.dart';
import 'package:localsend_app/provider/clipboard_sync_provider.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_app/widget/watcher/clipboard_pairing_request_watcher.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:refena_flutter/addons.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../fakes/pairing_session.dart';
import '../mocks.mocks.dart';

class _Controller extends ClipboardSyncController {
  _Controller({super.createPairingReceiver});

  @override
  ClipboardSyncState init() => const ClipboardSyncState(ready: true);
}

class _Persistence extends MockPersistenceService {
  @override
  bool getAlwaysOnTop() => false;
}

class _Isolates extends Fake implements IsolateController {}

void main() {
  testWidgets('a nearby request reaches the receiving app without Add device being open and declining saves no trust', (tester) async {
    final session = PairingSessionFake();
    var listenersStarted = 0;
    final controller = _Controller(
      createPairingReceiver: (_) async {
        listenersStarted++;
        return session;
      },
    );
    final persistence = _Persistence();
    final container = RefenaContainer(
      overrides: [
        clipboardSyncProvider.overrideWithNotifier((_) => controller),
        persistenceProvider.overrideWithValue(persistence),
        nearbyDevicesProvider.overrideWithNotifier(
          (_) => NearbyDevicesService(
            isolateController: _Isolates(),
            favoriteService: FavoritesService(persistence),
            discoveryLogs: DiscoveryLogger(),
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      RefenaScope.withContainer(
        container: container,
        child: MaterialApp(
          navigatorKey: container.read(navigationProvider).key,
          builder: (_, child) => ClipboardPairingRequestWatcher(child: child!),
          home: const Scaffold(body: Text('Home page')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(listenersStarted, 1);
    expect(find.byType(ClipboardPairingPage), findsNothing);
    session.emit('request');
    await tester.pumpAndSettle();
    expect(find.byType(ClipboardPairingPage), findsOneWidget);
    expect(find.text(t.clipboardSync.pairingRequest(device: 'Other device')), findsOneWidget);
    expect(session.approvals, isEmpty);
    await tester.tap(find.text(t.clipboardSync.declineRequest));
    await tester.pumpAndSettle();
    expect(find.text('Home page'), findsOneWidget);
    expect(session.stops, greaterThan(0));
    expect(container.read(clipboardSyncProvider).peers, isEmpty);
    expect(container.read(clipboardSyncProvider).enabled, false);
    // Listener rotation cannot turn a flood into repeated approval prompts.
    await tester.pump(const Duration(seconds: 29));
    expect(listenersStarted, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    container.disposeContainer();
    await tester.pump();
  });
}
