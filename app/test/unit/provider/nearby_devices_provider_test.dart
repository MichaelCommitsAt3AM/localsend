import 'dart:async';

import 'package:localsend_app/model/state/nearby_devices_state.dart';
import 'package:localsend_app/provider/favorites_provider.dart';
import 'package:localsend_app/provider/logging/discovery_logs_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_isolates/isolate.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:test/test.dart';

import '../../mocks.mocks.dart';

void main() {
  late _FailingIsolateController controller;
  late ReduxNotifierTester<NearbyDevicesState> service;

  setUp(() {
    controller = _FailingIsolateController();
    service = ReduxNotifier.test(
      redux: NearbyDevicesService(
        isolateController: controller,
        favoriteService: FavoritesService(MockPersistenceService()),
        discoveryLogs: DiscoveryLogger(),
      ),
    );
  });

  test('failed staged scans stop the spinner and allow a subsequent scan', () async {
    for (var attempt = 0; attempt < 2; attempt++) {
      await expectLater(
        service.dispatchAsync(
          StartStagedScan(
            favorites: [],
            interfaces: ['192.168.1.2'],
            port: 53317,
            https: true,
            grace: Duration.zero,
          ),
        ),
        throwsA('Discovery failed'),
      );
      expect(service.state.runningFavoriteScan, false);
    }
    expect(controller.requests, 2);
  });

  test('failed subnet scans clear their running IP and allow retry', () async {
    for (var attempt = 0; attempt < 2; attempt++) {
      await expectLater(
        service.dispatchAsync(
          StartLegacyScan(
            port: 53317,
            localIp: '192.168.1.2',
            https: true,
          ),
        ),
        throwsA('Discovery failed'),
      );
      expect(service.state.runningIps, isEmpty);
    }
    expect(controller.requests, 2);
  });
}

class _FailingIsolateController implements IsolateController {
  int requests = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #dispatchTakeResult) {
      requests++;
      return Stream<Device>.error('Discovery failed');
    }
    return super.noSuchMethod(invocation);
  }
}
