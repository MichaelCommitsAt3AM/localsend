import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/pages/tabs/receive_tab.dart';
import 'package:localsend_app/provider/clipboard_sync_provider.dart';

void main() {
  testWidgets('Receive note follows active connected peers and disappears after disconnect or Stop', (tester) async {
    const peers = [
      ClipboardPeer(fingerprint: 'online', address: '192.0.2.1', name: 'Desktop'),
      ClipboardPeer(fingerprint: 'offline', address: '192.0.2.2', name: 'Tablet'),
      ClipboardPeer(fingerprint: 'pending', address: '192.0.2.3', name: 'Unconfirmed', pending: true),
      ClipboardPeer(fingerprint: 'paused', address: '192.0.2.4', name: 'Paused', send: false, receive: false),
    ];
    Future<void> show({bool enabled = true, bool running = true, Set<String> connected = const {'online', 'pending', 'paused'}}) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ClipboardSyncStatus(
            state: ClipboardSyncState(
              enabled: enabled,
              running: running,
              connectedPeers: connected,
              peers: peers,
            ),
          ),
        ),
      ),
    );
    await show();
    expect(find.text(t.clipboardSync.activeWithDevices(devices: 'Desktop')), findsOneWidget);
    expect(find.textContaining('Tablet'), findsNothing);
    expect(find.textContaining('Unconfirmed'), findsNothing);
    expect(find.textContaining('Paused'), findsNothing);
    await show(connected: {});
    expect(find.byIcon(Icons.sync_rounded), findsNothing);
    await show(enabled: false);
    expect(find.byIcon(Icons.sync_rounded), findsNothing);
    await show(running: false);
    expect(find.byIcon(Icons.sync_rounded), findsNothing);
  });
}
