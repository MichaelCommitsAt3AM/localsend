import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/device_info_result.dart';
import 'package:localsend_isolates/model/dto/multicast_dto.dart';
import 'package:localsend_isolates/model/stored_security_context.dart';
import 'package:localsend_isolates/rust/api/discovery.dart';
import 'package:localsend_isolates/rust/api/model.dart' as rust;
import 'package:localsend_isolates/rust/frb_generated.dart';
import 'package:localsend_isolates/src/isolate/child/sync_provider.dart';
import 'package:localsend_isolates/src/task/discovery/discovery.dart';
import 'package:refena_flutter/refena_flutter.dart';

void main() {
  late RefenaContainer container;
  late _DiscoveryApi api;
  late DiscoveryService service;
  late StreamSubscription<Device> subscription;

  setUpAll(() {
    api = _DiscoveryApi();
    RustLib.initMock(api: api);
  });
  tearDownAll(RustLib.dispose);

  setUp(() {
    api.instances.clear();
    api.failNextStart = false;
    api.nextStart = null;
    container = RefenaContainer(
      overrides: [
        syncProvider.overrideWithNotifier(
          (ref) => SyncService(
            initial: SyncState(
              rootIsolateToken: Object(),
              securityContext: const StoredSecurityContext(privateKey: '', publicKey: '', certificate: '', certificateHash: ''),
              deviceInfo: DeviceInfoResult(deviceType: DeviceType.mobile, deviceModel: null, androidSdkInt: null),
              alias: 'Phone',
              port: 53317,
              networkWhitelist: null,
              networkBlacklist: null,
              protocol: ProtocolType.https,
              multicastGroup: '224.0.0.167',
              discoveryTimeout: 500,
              serverRunning: true,
              download: false,
            ),
          ),
        ),
      ],
    );
    service = container.read(discoveryProvider);
    subscription = service.startListener().listen((_) {});
  });

  tearDown(() async {
    await subscription.cancel();
    container.disposeContainer();
  });

  Future<void> scan() => service.discoverStaged(
    favorites: [],
    networkInterfaces: ['192.168.1.2'],
    port: 53317,
    https: true,
    grace: Duration.zero,
  );

  test('refresh stops stale sockets and scans only after the new listener is ready', () async {
    await pumpEventQueue();
    final old = api.instances.single;
    final nextStart = Completer<RsDiscovery>();
    api.nextStart = nextStart.future;
    final scanFuture = scan();
    await pumpEventQueue();
    expect(old.stopped, true);
    expect(old.scans, 0);
    final replacement = _Discovery();
    nextStart.complete(replacement);
    await scanFuture;
    expect(replacement.scans, 1);
  });

  test('restart during startup discards the listener bound to the old interfaces', () async {
    // The initial start has returned but its asynchronous setup is still pending.
    service.restartListener();
    await scan();
    expect(api.instances, hasLength(2));
    expect(api.instances.first.stopped, true);
    expect(api.instances.first.scans, 0);
    expect(api.instances.last.scans, 1);
  });

  test('refresh retries after startup failed instead of waiting forever', () async {
    await pumpEventQueue();
    api.failNextStart = true;
    await scan();
    await scan();
    expect(api.instances, hasLength(2));
    expect(api.instances.last.scans, 1);
  });

  test('a listener error restarts discovery without closing the app device stream', () async {
    await pumpEventQueue();
    api.instances.single.events.addError(StateError('Socket failed'));
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(api.instances, hasLength(2));
    expect(api.instances.last.stopped, false);
  });

  test('subnet refresh also rebinds stale multicast sockets', () async {
    await pumpEventQueue();
    final old = api.instances.single;
    await service.scanSubnet(networkInterface: '192.168.1.2', port: 53317, https: true);
    expect(old.stopped, true);
    expect(api.instances.last.subnetScans, 1);
  });
}

class _DiscoveryApi implements RustLibApi {
  final instances = <_Discovery>[];
  Future<RsDiscovery>? nextStart;
  bool failNextStart = false;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #crateApiDiscoveryStartDiscovery) {
      if (failNextStart) {
        failNextStart = false;
        return Future<RsDiscovery>.error(StateError('Cannot bind'));
      }
      final pending = nextStart;
      nextStart = null;
      if (pending != null) return pending;
      final discovery = _Discovery();
      instances.add(discovery);
      return Future<RsDiscovery>.value(discovery);
    }
    return super.noSuchMethod(invocation);
  }
}

class _Discovery implements RsDiscovery {
  final events = StreamController<RsStoredDevice>();
  bool stopped = false;
  int scans = 0;
  int subnetScans = 0;

  @override
  Stream<RsStoredDevice> listen() => events.stream;
  @override
  Future<String?> multicastError() async => null;
  @override
  Future<void> announce() async {}
  @override
  Future<void> stop() async {
    stopped = true;
    unawaited(events.close());
  }

  @override
  Future<void> discoverStaged({
    required List<RsDeviceChannel> channels,
    required List<String> interfaceIps,
    required int port,
    required rust.ProtocolType protocol,
    required BigInt graceMs,
  }) async {
    scans++;
  }

  @override
  Future<void> scanSubnet({required String interfaceIp, required int port, required rust.ProtocolType protocol}) async {
    subnetScans++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
