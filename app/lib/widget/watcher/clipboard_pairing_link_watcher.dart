import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/pages/settings/clipboard_pairing_page.dart';
import 'package:localsend_app/provider/clipboard_sync_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/clipboard_pairing_link.dart';
import 'package:refena_flutter/addons.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Handles cold/warm Android VIEW intents after bootstrap and navigation mount.
class ClipboardPairingLinkWatcher extends StatefulWidget {
  final Widget child;
  const ClipboardPairingLinkWatcher({super.key, required this.child});
  @override
  State<ClipboardPairingLinkWatcher> createState() => _ClipboardPairingLinkWatcherState();
}

class _ClipboardPairingLinkWatcherState extends State<ClipboardPairingLinkWatcher> {
  static const _channel = MethodChannel('org.localsend.localsend_app/clipboard_pairing_links');
  bool _draining = false;
  bool _again = false;
  bool _routeOpen = false;
  @override
  void initState() {
    super.initState();
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'pairingLinkReady') unawaited(_drain());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_drain());
    });
  }

  Future<void> _drain() async {
    if (!mounted) return;
    if (_draining) {
      _again = true;
      return;
    }
    _draining = true;
    try {
      do {
        _again = false;
        final link = await _channel.invokeMethod<String>('takePairingLink');
        if (!mounted || link == null) continue;
        // Reject malformed endpoints before opening a route. Rust validates all
        // credential fields and expiry before making any network connection.
        decodeClipboardPairingLink(link);
        if (_routeOpen) continue;
        final ref = context.ref;
        final navigator = ref.read(navigationProvider).key.currentState;
        if (navigator == null) continue;
        final controller = ref.notifier(clipboardSyncProvider);
        if (!ref.read(clipboardSyncProvider).ready) continue;
        _routeOpen = true;
        unawaited(
          navigator
              .push<void>(
                MaterialPageRoute(
                  builder: (_) => ClipboardPairingPage(
                    controller: controller,
                    deviceName: ref.read(settingsProvider).alias,
                    initialInvitation: link,
                  ),
                ),
              )
              .whenComplete(() {
                _routeOpen = false;
              }),
        );
      } while (_again && mounted);
    } catch (_) {
      // Never quote an invitation URL or credentials in logs/errors.
    } finally {
      _draining = false;
    }
  }

  @override
  void dispose() {
    if (Platform.isAndroid) _channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
