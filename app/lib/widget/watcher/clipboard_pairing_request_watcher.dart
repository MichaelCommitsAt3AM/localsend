import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localsend_app/pages/settings/clipboard_pairing_page.dart';
import 'package:localsend_app/provider/clipboard_sync_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_isolates/rust/api/clipboard.dart';
import 'package:refena_flutter/addons.dart';
import 'package:refena_flutter/refena_flutter.dart';

class ClipboardPairingRequestWatcher extends StatefulWidget {
  final Widget child;
  const ClipboardPairingRequestWatcher({super.key, required this.child});

  @override
  State<ClipboardPairingRequestWatcher> createState() => _ClipboardPairingRequestWatcherState();
}

class _ClipboardPairingRequestWatcherState extends State<ClipboardPairingRequestWatcher> {
  StreamSubscription<RsClipboardPairing>? _subscription;
  bool _routeOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = context.ref.notifier(clipboardSyncProvider);
      if (!context.ref.read(clipboardSyncProvider).ready) return;
      _subscription = controller.pairingRequests.listen((session) async {
        final navigator = mounted ? context.ref.read(navigationProvider).key.currentState : null;
        if (navigator == null || _routeOpen) {
          await controller.closePairing(session);
          return;
        }
        _routeOpen = true;
        try {
          await navigator.push<void>(
            MaterialPageRoute(
              builder: (_) => ClipboardPairingPage(
                controller: controller,
                deviceName: context.ref.read(settingsProvider).alias,
                initialSession: session,
              ),
            ),
          );
        } finally {
          _routeOpen = false;
        }
      });
      unawaited(controller.startPairingRequests(name: context.ref.read(settingsProvider).alias));
    });
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
