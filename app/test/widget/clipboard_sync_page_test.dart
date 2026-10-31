import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/settings/clipboard_pairing_page.dart';
import 'package:localsend_app/pages/settings/clipboard_sync_page.dart';
import 'package:localsend_app/pages/settings/clipboard_sync_tutorial_page.dart';
import 'package:localsend_app/provider/clipboard_sync_provider.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/rust/api/clipboard.dart';
import 'package:refena_flutter/refena_flutter.dart';

import '../mocks.mocks.dart';

class _Persistence extends MockPersistenceService {
  @override
  bool getAlwaysOnTop() => false;
}

class _Isolates extends Fake implements IsolateController {}

class _PairingSession extends Fake implements RsClipboardPairing {
  final update = Completer<RsPairingUpdate?>();
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
  Future<RsPairingUpdate?> nextUpdate({required BigInt after}) => update.future;
  @override
  Future<void> stop() async {
    if (!update.isCompleted) update.complete(null);
  }
}

class _Controller extends ClipboardSyncController {
  final ClipboardSyncState? initialState;
  int authorizationCalls = 0;
  bool authorized = true;
  String? retriedPeer;
  @override
  Future<void> retryPeer(String fingerprint) async => retriedPeer = fingerprint;
  final pairingSession = _PairingSession();
  final enableCalls = <bool>[];
  @override
  Future<RsClipboardPairing> hostPairing({required String name}) async => pairingSession;
  @override
  Future<void> savePairing(RsPairingUpdate update, {required bool pending}) async {
    state = ClipboardSyncState(
      ready: true,
      enabled: !pending,
      syncImages: !pending,
      hasEnabledBefore: state.hasEnabledBefore,
      peers: [ClipboardPeer(fingerprint: update.fingerprint, address: update.address, pending: pending)],
    );
  }

  @override
  Future<void> setEnabled(bool value) async {
    enableCalls.add(value);
    state = ClipboardSyncState(ready: true, enabled: value, peers: state.peers, hasEnabledBefore: state.hasEnabledBefore);
  }

  @override
  Future<bool> authorize() async {
    authorizationCalls++;
    return authorized;
  }

  _Controller([this.initialState]);
  @override
  ClipboardSyncState init() =>
      initialState ??
      ClipboardSyncState(
        ready: true,
        enabled: true,
        running: true,
        connected: 1,
        connectedPeers: {'A' * 64},
        hasEnabledBefore: true,
        status: 'Connected',
        peers: [ClipboardPeer(fingerprint: 'A' * 64, address: '192.0.2.1', name: 'Phone')],
      );
}

void main() {
  setUpAll(() async {
    final fontDirectory = Platform.environment['CLIPBOARD_UI_FONT_DIR'];
    if (Platform.environment['CLIPBOARD_UI_PREVIEW'] == '1' && fontDirectory != null) {
      for (final entry in {'Roboto': 'roboto-regular.ttf', 'MaterialIcons': 'materialicons-regular.otf'}.entries) {
        final loader = FontLoader(entry.key)
          ..addFont(File('$fontDirectory/${entry.value}').readAsBytes().then((bytes) => ByteData.sublistView(bytes)));
        await loader.load();
      }
    }
  });
  testWidgets('leaving and reopening clipboard settings preserves the application controller and pairing state', (tester) async {
    var created = 0;
    final container = RefenaContainer(
      overrides: [
        clipboardSyncProvider.overrideWithNotifier((_) {
          created++;
          return _Controller();
        }),
      ],
    );
    final controller = container.notifier(clipboardSyncProvider);
    final state = container.read(clipboardSyncProvider);
    final visible = ValueNotifier(true);
    await tester.pumpWidget(
      RefenaScope.withContainer(
        container: container,
        child: MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (_, show, _) => show ? const ClipboardSyncPage() : const SizedBox(),
          ),
        ),
      ),
    );
    expect(find.text('${t.clipboardSync.pairedDevices}: 1'), findsOneWidget);
    visible.value = false;
    await tester.pump();
    expect(container.notifier(clipboardSyncProvider), same(controller));
    visible.value = true;
    await tester.pump();
    expect(created, 1);
    expect(container.read(clipboardSyncProvider), same(state));
    expect(find.text('${t.clipboardSync.pairedDevices}: 1'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile).first).onChanged, isNotNull);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile).last).onChanged, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    visible.dispose();
    container.disposeContainer();
  });

  for (final width in [360.0, 1280.0]) {
    testWidgets('clipboard settings fits width $width and keeps technical details out of the main view', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = RefenaContainer(overrides: [clipboardSyncProvider.overrideWithNotifier((_) => _Controller())]);
      final previewKey = GlobalKey();
      await tester.pumpWidget(
        RefenaScope.withContainer(
          container: container,
          child: MaterialApp(
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark),
            ),
            home: RepaintBoundary(key: previewKey, child: const ClipboardSyncPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('192.0.2.1'), findsNothing);
      expect(find.text('A' * 64), findsNothing);
      expect(find.text(t.clipboardSync.copyCode), findsNothing);
      expect(tester.takeException(), isNull);
      if (Platform.environment['CLIPBOARD_UI_PREVIEW'] == '1') {
        await tester.runAsync(() async {
          final boundary = previewKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('build/ui-preview/clipboard-${width.toInt()}.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.text('Phone'));
      await tester.pumpAndSettle();
      expect(find.text(t.clipboardSync.send), findsOneWidget);
      expect(find.text(t.clipboardSync.receive), findsOneWidget);
      await tester.tap(find.text(t.clipboardSync.revoke));
      await tester.pumpAndSettle();
      expect(find.text(t.clipboardSync.removeTitle), findsOneWidget);
      await tester.tap(find.text(t.general.cancel));
      await tester.pumpAndSettle();
      expect(container.read(clipboardSyncProvider).peers, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      container.disposeContainer();
    });
  }

  testWidgets('offline paired device offers a targeted retry', (tester) async {
    final fingerprint = 'A' * 64;
    final controller = _Controller(
      ClipboardSyncState(
        ready: true,
        enabled: true,
        running: true,
        status: 'Waiting for paired devices',
        peers: [ClipboardPeer(fingerprint: fingerprint, address: '192.0.2.1:53318', name: 'Phone')],
      ),
    );
    final container = RefenaContainer(overrides: [clipboardSyncProvider.overrideWithNotifier((_) => controller)]);
    await tester.pumpWidget(
      RefenaScope.withContainer(
        container: container,
        child: const MaterialApp(home: ClipboardSyncPage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Phone'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(t.clipboardSync.retryConnection));
    await tester.tap(find.text(t.clipboardSync.retryConnection));
    await tester.pump();
    expect(controller.retriedPeer, fingerprint);
    await tester.pumpWidget(const SizedBox());
    container.disposeContainer();
  });

  testWidgets('clipboard settings and device controls remain usable with large text on a narrow phone', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = RefenaContainer(overrides: [clipboardSyncProvider.overrideWithNotifier((_) => _Controller())]);
    await tester.pumpWidget(
      RefenaScope.withContainer(
        container: container,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1.8)),
            child: child!,
          ),
          home: const ClipboardSyncPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Phone'));
    await tester.tap(find.text('Phone'));
    await tester.pumpAndSettle();
    expect(find.text(t.clipboardSync.send), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    container.disposeContainer();
  });

  testWidgets('first device switch prompts for a device and cancelling leaves sharing off', (tester) async {
    final container = RefenaContainer(
      overrides: [clipboardSyncProvider.overrideWithNotifier((_) => _Controller(const ClipboardSyncState(ready: true)))],
    );
    await tester.pumpWidget(
      RefenaScope.withContainer(
        container: container,
        child: const MaterialApp(home: ClipboardSyncPage()),
      ),
    );
    expect(find.text(t.clipboardSync.noDevicesHint), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile).first).onChanged, isNotNull);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile).last).onChanged, isNull);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, t.clipboardSync.addDevice)).onPressed, isNotNull);
    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(container.read(clipboardSyncProvider).enabled, false);
    await tester.tap(find.text(t.general.cancel));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(container.read(clipboardSyncProvider).enabled, false);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    container.disposeContainer();
  });

  for (final result in ['cancelled', 'pending', 'complete']) {
    testWidgets('enable flow keeps sharing off until pairing is complete: $result', (tester) async {
      final controller = _Controller(const ClipboardSyncState(ready: true, hasEnabledBefore: true));
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
            theme: ThemeData(platform: TargetPlatform.windows),
            home: const ClipboardSyncPage(),
          ),
        ),
      );
      await tester.tap(find.byType(SwitchListTile).first);
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(BottomSheet), matching: find.text(t.clipboardSync.addDevice)));
      await tester.pumpAndSettle();
      expect(find.byType(ClipboardPairingPage), findsOneWidget);
      expect(controller.enableCalls, isEmpty);
      final update = RsPairingUpdate(
        revision: BigInt.one,
        phase: 'complete',
        code: '',
        fingerprint: 'C' * 64,
        address: '192.0.2.2:53318',
        name: 'Phone',
        expires: BigInt.zero,
      );
      if (result == 'complete') {
        controller.pairingSession.update.complete(update);
        await tester.pumpAndSettle();
        expect(find.byType(ClipboardPairingPage), findsNothing);
        expect(find.text(t.clipboardSync.consent), findsNothing);
        expect(controller.enableCalls, isEmpty);
        expect(container.read(clipboardSyncProvider).enabled, true);
        expect(container.read(clipboardSyncProvider).syncImages, true);
      } else {
        if (result == 'pending') await controller.savePairing(update, pending: true);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(controller.enableCalls, isEmpty);
        expect(container.read(clipboardSyncProvider).enabled, false);
        expect(find.text(t.clipboardSync.consent), findsNothing);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      container.disposeContainer();
    });
  }

  testWidgets('Android listener startup does not show a sharing failure for a connected peer', (tester) async {
    final container = RefenaContainer(
      overrides: [
        clipboardSyncProvider.overrideWithNotifier(
          (_) => _Controller(
            ClipboardSyncState(
              ready: true,
              enabled: true,
              running: true,
              connected: 1,
              connectedPeers: {'A' * 64},
              status: 'Starting Android clipboard listener',
              peers: [ClipboardPeer(fingerprint: 'A' * 64, address: '192.0.2.1', name: 'PC')],
            ),
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      RefenaScope.withContainer(
        container: container,
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: const ClipboardSyncPage(),
        ),
      ),
    );
    expect(find.text(t.clipboardSync.needsAttention), findsNothing);
    expect(find.text(t.clipboardSync.connectionHelp), findsNothing);
    expect(find.byTooltip(t.clipboardSync.onlineDevice), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    container.disposeContainer();
  });

  testWidgets('sustained connection outage explains possible public Wi-Fi isolation', (tester) async {
    final container = RefenaContainer(
      overrides: [
        clipboardSyncProvider.overrideWithNotifier(
          (_) => _Controller(
            const ClipboardSyncState(
              ready: true,
              enabled: true,
              running: true,
              connectionWarning: true,
              status: 'Waiting for paired devices',
            ),
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      RefenaScope.withContainer(
        container: container,
        child: const MaterialApp(home: ClipboardSyncPage()),
      ),
    );
    expect(find.text(t.clipboardSync.networkWarning), findsOneWidget);
    expect(find.text(t.clipboardSync.needsAttention), findsNothing);
    await tester.pumpWidget(const SizedBox());
    container.disposeContainer();
  });

  testWidgets('configuration failure shows understandable guidance instead of appearing as an unexplained disabled page', (tester) async {
    final container = RefenaContainer(
      overrides: [
        clipboardSyncProvider.overrideWithNotifier(
          (_) => _Controller(const ClipboardSyncState(status: 'Secure clipboard configuration unavailable. Restore secure storage before pairing.')),
        ),
      ],
    );
    await tester.pumpWidget(
      RefenaScope.withContainer(
        container: container,
        child: const MaterialApp(home: ClipboardSyncPage()),
      ),
    );
    expect(find.text(t.clipboardSync.needsAttention), findsOneWidget);
    expect(find.text(t.clipboardSync.settingsHelp), findsOneWidget);
    expect(find.text(t.clipboardSync.viewDetails), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    container.disposeContainer();
  });

  testWidgets('only the identified connected device has a dot and the separate connection section is absent', (tester) async {
    final container = RefenaContainer(
      overrides: [
        clipboardSyncProvider.overrideWithNotifier(
          (_) => _Controller(
            ClipboardSyncState(
              ready: true,
              enabled: true,
              hasEnabledBefore: true,
              status: 'Connected',
              connected: 1,
              connectedPeers: {'A' * 64},
              peers: [
                ClipboardPeer(fingerprint: 'A' * 64, address: '192.0.2.1', name: 'Connected phone'),
                ClipboardPeer(fingerprint: 'B' * 64, address: '192.0.2.2', name: 'Offline tablet'),
              ],
            ),
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      RefenaScope.withContainer(
        container: container,
        child: const MaterialApp(home: ClipboardSyncPage()),
      ),
    );
    final connectedCard = tester.element(find.widgetWithText(ListTile, 'Connected phone')).findAncestorWidgetOfExactType<Card>();
    final offlineCard = tester.element(find.widgetWithText(ListTile, 'Offline tablet')).findAncestorWidgetOfExactType<Card>();
    expect(connectedCard, isNotNull);
    expect(offlineCard, isNot(same(connectedCard)));
    expect(find.byTooltip(t.clipboardSync.onlineDevice), findsOneWidget);
    expect(
      find.descendant(of: find.widgetWithText(ListTile, 'Connected phone'), matching: find.byTooltip(t.clipboardSync.onlineDevice)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.widgetWithText(ListTile, 'Offline tablet'), matching: find.byTooltip(t.clipboardSync.onlineDevice)),
      findsNothing,
    );
    expect(find.text(t.clipboardSync.readyToShare), findsNothing);
    expect(find.text('${t.clipboardSync.connected}: 1'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    container.disposeContainer();
  });

  testWidgets('first Android enable offers the tutorial and denied access does not enable sharing', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _Controller(
      ClipboardSyncState(
        ready: true,
        peers: [ClipboardPeer(fingerprint: 'A' * 64, address: '192.0.2.1')],
      ),
    )..authorized = false;
    final container = RefenaContainer(overrides: [clipboardSyncProvider.overrideWithNotifier((_) => controller)]);
    await tester.pumpWidget(
      RefenaScope.withContainer(
        container: container,
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: const ClipboardSyncPage(),
        ),
      ),
    );
    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();
    expect(find.text(t.clipboardSync.setupTitle), findsOneWidget);
    await tester.tap(find.text(t.clipboardSync.tutorial));
    await tester.pumpAndSettle();
    expect(find.byType(ClipboardSyncTutorialPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.clipboardSync.continueSetup));
    await tester.pumpAndSettle();
    expect(controller.authorizationCalls, 1);
    expect(container.read(clipboardSyncProvider).enabled, false);
    expect(find.text(t.clipboardSync.consent), findsNothing);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.clipboardSync.tutorial));
    await tester.pumpAndSettle();
    expect(find.byType(ClipboardSyncTutorialPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    container.disposeContainer();
  });

  testWidgets('returning Android users skip onboarding but retain the sharing consent', (tester) async {
    final controller = _Controller(
      ClipboardSyncState(
        ready: true,
        hasEnabledBefore: true,
        peers: [ClipboardPeer(fingerprint: 'A' * 64, address: '192.0.2.1')],
      ),
    );
    final container = RefenaContainer(overrides: [clipboardSyncProvider.overrideWithNotifier((_) => controller)]);
    await tester.pumpWidget(
      RefenaScope.withContainer(
        container: container,
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: const ClipboardSyncPage(),
        ),
      ),
    );
    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();
    expect(find.text(t.clipboardSync.setupTitle), findsNothing);
    expect(find.text(t.clipboardSync.consent), findsOneWidget);
    expect(controller.authorizationCalls, 0);
    await tester.tap(find.text(t.general.cancel));
    await tester.pumpAndSettle();
    expect(container.read(clipboardSyncProvider).enabled, false);
    await tester.pumpWidget(const SizedBox());
    container.disposeContainer();
  });
}
