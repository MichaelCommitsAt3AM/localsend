import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/native/tray_helper.dart';
import 'package:logging/logging.dart';
import 'package:window_manager/window_manager.dart';

final _logger = Logger('IncomingRequestNotifier');

const _notificationId = 2; // 1 is the foreground service
const _channelId = 'localsend_incoming_request';

/// Notifies the user about an incoming file request while the app is not in the foreground.
class IncomingRequestNotifier {
  IncomingRequestNotifier._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static Future<bool>? _init;

  /// Whether the user is looking at the app right now.
  static Future<bool> _isInForeground() async {
    if (checkPlatformIsDesktop()) {
      return await windowManager.isVisible() && !await windowManager.isMinimized() && await windowManager.isFocused();
    }
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  static Future<bool> _ensureInitialized() {
    return _init ??= () async {
      try {
        await _plugin.initialize(
          settings: const InitializationSettings(
            android: AndroidInitializationSettings('@mipmap/ic_launcher'),
            iOS: DarwinInitializationSettings(),
            macOS: DarwinInitializationSettings(),
            linux: LinuxInitializationSettings(defaultActionName: 'Open LocalSend'),
            windows: WindowsInitializationSettings(
              appName: 'LocalSend',
              appUserModelId: 'org.localsend.localsend_app',
              guid: '8c1f3a52-6d0e-4b0b-9a53-2f4f9d4e7c11',
            ),
          ),
          onDidReceiveNotificationResponse: (_) {
            if (checkPlatformHasTray()) {
              unawaited(showFromTray());
            }
          },
        );
        return true;
      } catch (e, st) {
        _logger.warning('Could not initialize notifications', e, st);
        return false;
      }
    }();
  }

  /// Shows a notification if the app is not in the foreground. Never throws.
  static Future<void> notifyIfBackground({required String senderAlias, required int fileCount}) async {
    try {
      if (await _isInForeground()) {
        return;
      }
      if (!await _ensureInitialized()) {
        return;
      }

      // Android 13+ / iOS / macOS need a runtime permission; this is a no-op once decided.
      await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
      await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(alert: true, sound: true);
      await _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()?.requestPermissions(alert: true, sound: true);

      await _plugin.show(
        id: _notificationId,
        title: senderAlias,
        body: t.receivePage.subTitle(n: fileCount),
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            t.receiveTab.title,
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: const DarwinNotificationDetails(),
          macOS: const DarwinNotificationDetails(),
          linux: const LinuxNotificationDetails(),
          windows: const WindowsNotificationDetails(),
        ),
      );
    } catch (e, st) {
      _logger.warning('Could not show the incoming request notification', e, st);
    }
  }
}
