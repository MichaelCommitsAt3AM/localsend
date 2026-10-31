import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/clipboard_peer_probe.dart';
import 'package:localsend_isolates/rust/api/clipboard.dart';
import 'package:localsend_isolates/rust/api/crypto.dart' as rust_crypto;
import 'package:refena_flutter/refena_flutter.dart';

const clipboardSyncPort = 53318;
final clipboardSyncProvider = NotifierProvider<ClipboardSyncController, ClipboardSyncState>(
  (ref) => ClipboardSyncController(),
  debugLabel: 'ClipboardSync',
);

class ClipboardPeer {
  final String fingerprint;
  final String address;
  final bool send;
  final bool receive;
  final String name;
  final bool pending;

  const ClipboardPeer({
    required this.fingerprint,
    required this.address,
    this.send = true,
    this.receive = true,
    this.name = '',
    this.pending = false,
  });
  Map<String, Object> toJson() => {
    'fingerprint': fingerprint,
    'address': address,
    'send': send,
    'receive': receive,
    'name': name,
    'pending': pending,
  };
  factory ClipboardPeer.fromJson(Map<String, dynamic> json) {
    final peer = ClipboardPeer(
      fingerprint: json['fingerprint'] as String,
      address: json['address'] as String,
      send: json['send'] as bool,
      receive: json['receive'] as bool,
      name: json['name'] as String? ?? '',
      pending: json['pending'] as bool? ?? false,
    );
    if (!RegExp(r'^[A-F0-9]{64}$').hasMatch(peer.fingerprint) || peer.address.length > 128) {
      throw const FormatException('Invalid clipboard peer');
    }
    return peer;
  }
}

/// UI-visible metadata only. Clipboard values and secret keys never enter Refena.
class ClipboardSyncState {
  final bool ready;
  final bool enabled;
  final bool running;
  final bool syncImages;
  final int connected;
  final Set<String> connectedPeers;
  final bool connectionWarning;
  final bool hasEnabledBefore;
  final int captures;
  final int applied;
  final String status;
  final String pairingCode;
  final List<ClipboardPeer> peers;

  const ClipboardSyncState({
    this.ready = false,
    this.enabled = false,
    this.running = false,
    this.syncImages = false,
    this.connected = 0,
    this.connectedPeers = const {},
    this.connectionWarning = false,
    this.hasEnabledBefore = false,
    this.captures = 0,
    this.applied = 0,
    this.status = 'Disabled',
    this.pairingCode = '',
    this.peers = const [],
  });
}

class ClipboardSyncController extends PureNotifier<ClipboardSyncState> {
  final Future<RsClipboardPairing> Function(String name)? _pairingReceiverFactory;
  ClipboardSyncController({
    Future<RsClipboardPairing> Function(String name)? createPairingReceiver,
    this.probePeers = probeClipboardPeers,
  }) : _pairingReceiverFactory = createPairingReceiver;

  final Future<Map<String, String>> Function(String, String, Set<String>, List<String>, int) probePeers;
  Iterable<String> Function()? _discoveryHosts;
  Timer? _addressTimer;
  bool _refreshingAddresses = false;
  static const _methods = MethodChannel('org.localsend.localsend_app/clipboard');
  static const _events = EventChannel('org.localsend.localsend_app/clipboard_events');
  String? _certificate;
  String? _privateKey;
  String _fingerprint = '';
  String _pairingCode = '';
  bool _enabled = false;
  bool _syncImages = false;
  bool _busy = false;
  int _connected = 0;
  Set<String> _connectedPeers = {};
  bool _hasEnabledBefore = false;
  int _captures = 0;
  int _applied = 0;
  int _sequence = 0;
  List<ClipboardPeer> _peers = [];
  RsClipboardRuntime? _runtime;
  StreamSubscription<dynamic>? _subscription;
  Future<void> _nativeQueue = Future.value();
  bool _captureQueued = false;
  String? _notificationMetadata;
  Timer? _connectionTimer;
  bool _connectionWarning = false;
  String? _captureIssue;
  String? _screenshotIssue;
  final _pairingRequests = StreamController<RsClipboardPairing>.broadcast();
  Stream<RsClipboardPairing> get pairingRequests => _pairingRequests.stream;
  RsClipboardPairing? _receiver;
  Future<RsClipboardPairing>? _receiverStarting;
  Timer? _receiverRetry;
  bool _receiverAttached = false;
  bool _acceptPairingRequests = false;
  bool _pairingDisposed = false;
  String _pairingDeviceName = 'LocalSend';
  DateTime? _pairingRetryAfter;
  int _pairingScreens = 0;
  void pairingScreenOpened() => _pairingScreens++;
  void pairingScreenClosed() => _pairingScreens--;

  @override
  ClipboardSyncState init() => const ClipboardSyncState();

  @override
  void dispose() {
    _addressTimer?.cancel();
    _connectionTimer?.cancel();
    _pairingDisposed = true;
    _acceptPairingRequests = false;
    _receiverRetry?.cancel();
    final receiver = _receiver;
    if (receiver != null) unawaited(receiver.stop());
    unawaited(_pairingRequests.close());
    super.dispose();
  }

  void _publish(String status) {
    state = ClipboardSyncState(
      ready: _certificate != null,
      enabled: _enabled,
      running: _runtime != null,
      syncImages: _syncImages,
      connected: _connected,
      connectedPeers: Set.unmodifiable(_connectedPeers),
      connectionWarning: _connectionWarning,
      hasEnabledBefore: _hasEnabledBefore,
      captures: _captures,
      applied: _applied,
      status: _runtime != null ? _captureIssue ?? _screenshotIssue ?? status : status,
      pairingCode: _pairingCode,
      peers: List.unmodifiable(_peers),
    );
    if (Platform.isAndroid) {
      final names = _peers.where((p) => !p.pending && _connectedPeers.contains(p.fingerprint)).map((p) => _pairingName(p.name)).toList();
      final notification = {'names': names, 'connected': _connected, 'connectionIssue': _connectionWarning ? t.clipboardSync.networkWarning : null};
      final metadata = jsonEncode(notification);
      if (_notificationMetadata != metadata) {
        _notificationMetadata = metadata;
        unawaited(
          _methods.invokeMethod<void>('updateNotification', notification).catchError((Object _) {
            // Notification metadata is best effort; it must not interrupt clipboard sync.
            _notificationMetadata = null;
          }),
        );
      }
    }
  }

  Future<void> initialize({Iterable<String> Function()? discoveryHosts}) async {
    _discoveryHosts = discoveryHosts;
    if (!Platform.isWindows && !Platform.isAndroid) return;
    try {
      final stored = await _methods.invokeMethod<String>('loadSecret');
      if (stored == null) {
        final identity = await rust_crypto.generateSecurityContext();
        _certificate = identity.certificate;
        _privateKey = identity.privateKey;
        _fingerprint = identity.certificateHash;
        await _save();
      } else {
        final json = jsonDecode(stored) as Map<String, dynamic>;
        if (json['version'] != 1) throw const FormatException('Unsupported clipboard configuration');
        _certificate = json['certificate'] as String;
        _privateKey = json['privateKey'] as String;
        _fingerprint = json['fingerprint'] as String;
        _enabled = json['enabled'] as bool;
        _hasEnabledBefore = json['hasEnabledBefore'] as bool? ?? _enabled;
        _syncImages = json['syncImages'] as bool? ?? false;
        _peers = (json['peers'] as List).map((p) => ClipboardPeer.fromJson(p as Map<String, dynamic>)).toList();
        if (_peers.length > 8 || !RegExp(r'^[A-F0-9]{64}$').hasMatch(_fingerprint)) {
          throw const FormatException('Invalid clipboard configuration');
        }
      }
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      final addresses = interfaces.expand((i) => i.addresses).map((a) => a.address).where((a) => !a.startsWith('169.254.')).toSet().toList();
      _pairingCode = jsonEncode({'version': 1, 'fingerprint': _fingerprint, 'port': clipboardSyncPort, 'addresses': addresses});
      _publish(_enabled ? 'Starting' : 'Disabled');
      if (_enabled) await _start();
    } catch (_) {
      _certificate = null;
      _privateKey = null;
      _enabled = false;
      _publish('Secure clipboard configuration unavailable. Restore secure storage before pairing.');
    }
  }

  Future<void> _save() => _methods.invokeMethod<void>(
    'saveSecret',
    {
      'value': jsonEncode({
        'version': 1,
        'certificate': _certificate,
        'privateKey': _privateKey,
        'fingerprint': _fingerprint,
        'enabled': _enabled,
        'hasEnabledBefore': _hasEnabledBefore,
        'syncImages': _syncImages,
        'peers': _peers.map((p) => p.toJson()).toList(),
      }),
    },
  );

  Future<bool> authorize() async {
    try {
      final result = await _methods.invokeMapMethod<String, dynamic>('authorize');
      _publish(
        result?['managerOpened'] == true
            ? 'Start Shizuku, then return here to allow clipboard access'
            : result?['authorized'] == true
            ? 'Clipboard access authorized'
            : 'Clipboard access not authorized',
      );
      if (result?['authorized'] == true && _syncImages && Platform.isAndroid) {
        final photos = await _methods.invokeMethod<bool>('authorizeImages') == true;
        _screenshotIssue = photos ? null : 'Screenshot sharing paused: allow full photo access';
        _publish(photos ? 'Clipboard and screenshot access authorized' : _screenshotIssue!);
      }
      if (result?['authorized'] == true && _enabled && _runtime == null) await _start();
      return result?['authorized'] == true;
    } on PlatformException catch (error) {
      _publish(error.message ?? 'Clipboard authorization failed');
      return false;
    }
  }

  Future<void> setEnabled(bool value) async {
    if (_busy) {
      if (!value) _halt('Disabled');
      return;
    }
    _busy = true;
    try {
      if (value) {
        if (_certificate == null || !_peers.any((p) => !p.pending)) {
          _publish('Pair a device before enabling clipboard sync');
          return;
        }
        _enabled = true;
        await _start();
        if (_runtime == null) {
          _enabled = false;
        } else {
          _hasEnabledBefore = true;
          _publish(_connected > 0 ? 'Connected' : 'Waiting for paired devices');
        }
      } else {
        _enabled = false;
        await _stop();
        _publish('Disabled');
      }
      await _save();
    } catch (_) {
      await _stop();
      _enabled = false;
      _publish('Clipboard configuration could not be saved');
    } finally {
      _busy = false;
    }
  }

  Future<void> setPeers(List<ClipboardPeer> peers) async {
    if (_busy || peers.length > 8 || peers.any((p) => p.fingerprint == _fingerprint)) return;
    if (peers.map((p) => p.fingerprint).toSet().length != peers.length) return;
    _busy = true;
    try {
      await _stop();
      _peers = List.of(peers);
      if (_peers.isEmpty) _enabled = false;
      // Save authorization before any new connection can start.
      await _save();
      if (_enabled) {
        await _start();
      } else {
        _publish('Disabled');
      }
    } catch (_) {
      _enabled = false;
      _publish('Clipboard peer configuration could not be saved');
    } finally {
      _busy = false;
    }
  }

  /// File-transfer and clipboard certificates are independent. Never match by
  /// discovery fingerprint or alias: prove possession of the pinned clipboard key.
  Future<void> refreshDiscoveredAddresses(Iterable<String> hosts, {String? fingerprint}) async {
    if (_refreshingAddresses || _busy || !_enabled || _certificate == null || _pairingDisposed) return;
    final snapshot = _peers;
    final pins = snapshot
        .where((p) => !p.pending && !_connectedPeers.contains(p.fingerprint) && (fingerprint == null || p.fingerprint == fingerprint))
        .map((p) => p.fingerprint)
        .toSet();
    if (pins.isEmpty) return;
    final candidates = hosts
        .where((host) {
          final ip = InternetAddress.tryParse(host);
          return ip != null && ip.type == InternetAddressType.IPv4 && !ip.isLoopback && !ip.isMulticast && host != '0.0.0.0';
        })
        .toSet()
        .take(64)
        .toList();
    if (candidates.isEmpty) return;
    _refreshingAddresses = true;
    try {
      final verified = await probePeers(_certificate!, _privateKey!, pins, candidates, clipboardSyncPort);
      // Pairing, consent, and connection state may have changed during the probe.
      if (_pairingDisposed || !_enabled || _busy || !identical(snapshot, _peers)) return;
      final peers = snapshot.map((peer) {
        final address = verified[peer.fingerprint];
        if (peer.pending || _connectedPeers.contains(peer.fingerprint) || address == null || address == peer.address) return peer;
        return ClipboardPeer(
          fingerprint: peer.fingerprint,
          address: address,
          send: peer.send,
          receive: peer.receive,
          name: peer.name,
        );
      }).toList();
      if (List.generate(peers.length, (i) => identical(peers[i], snapshot[i])).every((same) => same)) return;
      await setPeers(peers);
    } catch (_) {
      // Discovery failure must not disable an otherwise working clipboard runtime.
    } finally {
      _refreshingAddresses = false;
    }
  }

  /// Retry a disconnected peer using discovery hints authenticated by its pinned key.
  Future<void> retryPeer(String fingerprint) async {
    if (_busy || !_enabled || !_peers.any((p) => p.fingerprint == fingerprint && !p.pending) || _connectedPeers.contains(fingerprint)) return;
    final previousRuntime = _runtime;
    if (_discoveryHosts != null) await refreshDiscoveredAddresses(_discoveryHosts!(), fingerprint: fingerprint);
    if (_busy || !_enabled || !_peers.any((p) => p.fingerprint == fingerprint && !p.pending) || _connectedPeers.contains(fingerprint)) return;
    // Address refresh already restarts the runtime when it finds a new address.
    if (_runtime != previousRuntime) return;
    _busy = true;
    try {
      await _stop();
      if (_enabled) await _start();
    } finally {
      _busy = false;
    }
  }

  Future<void> setSyncImages(bool value) async {
    if (_busy || _certificate == null) return;
    _busy = true;
    try {
      if (value && Platform.isAndroid && await _methods.invokeMethod<bool>('authorizeImages') != true) {
        _publish('Allow full photo access to synchronize new screenshots');
        return;
      }
      await _stop();
      _syncImages = value;
      await _save();
      if (_enabled) await _start();
      _publish(_runtime != null ? 'Waiting for paired devices' : 'Disabled');
    } catch (_) {
      _enabled = false;
      _publish('Image sync preference could not be saved; synchronization is disabled');
    } finally {
      _busy = false;
    }
  }

  String _pairingName(String alias) {
    return alias.runes.take(32).map(String.fromCharCode).join().replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
  }

  Future<RsClipboardPairing> hostPairing({required String name}) async {
    _pairingDeviceName = name;
    if (_receiverAttached) throw StateError('A pairing screen is already open');
    _receiverAttached = true;
    try {
      return await _ensurePairingReceiver();
    } catch (_) {
      _receiverAttached = false;
      rethrow;
    }
  }

  /// The invitation listener can receive an approval request anywhere in the
  /// running app. The secret and code exchange stay in Rust and the route.
  Future<void> startPairingRequests({required String name}) async {
    _acceptPairingRequests = true;
    _pairingDeviceName = name;
    try {
      await _ensurePairingReceiver();
    } catch (_) {
      _schedulePairingReceiver();
    }
  }

  void _schedulePairingReceiver() {
    if (_pairingDisposed || !_acceptPairingRequests) return;
    _receiverRetry?.cancel();
    final cooldown = _pairingRetryAfter?.difference(DateTime.now()) ?? Duration.zero;
    _receiverRetry = Timer(cooldown > const Duration(seconds: 2) ? cooldown : const Duration(seconds: 2), () {
      unawaited(startPairingRequests(name: _pairingDeviceName));
    });
  }

  Future<RsClipboardPairing> _ensurePairingReceiver() async {
    if (_pairingDisposed) throw StateError('Pairing unavailable');
    if (_receiver != null) return _receiver!;
    if (_receiverStarting != null) return _receiverStarting!;
    if (_pairingRetryAfter?.isAfter(DateTime.now()) == true) throw StateError('Pairing request cooldown');
    final starting = _pairingReceiverFactory?.call(_pairingDeviceName) ?? _createPairingReceiver();
    _receiverStarting = starting;
    try {
      final receiver = await starting;
      if (_pairingDisposed) {
        await receiver.stop();
        throw StateError('Pairing unavailable');
      }
      _receiver = receiver;
      unawaited(_monitorPairingReceiver(receiver));
      return receiver;
    } finally {
      _receiverStarting = null;
    }
  }

  Future<RsClipboardPairing> _createPairingReceiver() async {
    if (_certificate == null) throw StateError('Clipboard identity unavailable');
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
    final addresses = interfaces.expand((i) => i.addresses).map((a) => a.address).where((a) => !a.startsWith('169.254.')).toSet().toList();
    return hostClipboardPairing(
      certificate: _certificate!,
      privateKey: _privateKey!,
      port: 53319,
      addresses: addresses,
      name: _pairingName(_pairingDeviceName).isEmpty ? 'LocalSend' : _pairingName(_pairingDeviceName),
      clipboardPort: clipboardSyncPort,
    );
  }

  Future<void> _monitorPairingReceiver(RsClipboardPairing receiver) async {
    var revision = BigInt.zero;
    var requested = false;
    try {
      while (!_pairingDisposed && identical(receiver, _receiver)) {
        final update = await receiver.nextUpdate(after: revision);
        if (update == null) break;
        revision = update.revision;
        if (update.phase == 'request') {
          requested = true;
          _pairingRetryAfter = DateTime.now().add(const Duration(seconds: 30));
          if (!_receiverAttached) {
            _receiverAttached = true;
            if (_pairingRequests.hasListener && _pairingScreens == 0) {
              _pairingRequests.add(receiver);
            } else {
              await receiver.approve(approved: false);
            }
          }
        }
        if (['complete', 'failed', 'expired', 'cancelled'].contains(update.phase)) break;
      }
    } catch (_) {
      // Never log invitation tokens or pairing codes.
    } finally {
      await receiver.stop();
      if (identical(receiver, _receiver)) {
        _receiver = null;
        _receiverAttached = false;
      }
      // Bound repeated requests across listener restarts, including declines.
      if (requested) _pairingRetryAfter = DateTime.now().add(const Duration(seconds: 30));
      _schedulePairingReceiver();
    }
  }

  Future<void> closePairing(RsClipboardPairing session) async {
    if (identical(session, _receiver)) {
      _receiver = null;
      _receiverAttached = false;
    }
    await session.stop();
  }

  Future<RsClipboardPairing> joinPairing({String? invitation, String? address, required String name}) async {
    if (_certificate == null) throw StateError('Clipboard identity unavailable');
    return joinClipboardPairing(
      certificate: _certificate!,
      privateKey: _privateKey!,
      invitation: invitation,
      address: address,
      name: _pairingName(name).isEmpty ? 'LocalSend' : _pairingName(name),
      clipboardPort: clipboardSyncPort,
    );
  }

  /// Pending records survive process death but cannot send or receive text.
  /// Activate only after both endpoints acknowledge protected storage.
  Future<void> savePairing(RsPairingUpdate update, {required bool pending}) async {
    if (_busy || _certificate == null || update.fingerprint == _fingerprint || !RegExp(r'^[A-F0-9]{64}$').hasMatch(update.fingerprint)) {
      throw StateError('Pairing unavailable');
    }
    final existing = _peers.where((p) => p.fingerprint != update.fingerprint).toList();
    if (existing.length >= 8) throw StateError('Clipboard peer limit reached');
    final previousPeers = _peers;
    final previousSyncImages = _syncImages;
    final previousEnabledBefore = _hasEnabledBefore;
    _busy = true;
    try {
      await _stop();
      _peers = [...existing, ClipboardPeer(fingerprint: update.fingerprint, address: update.address, name: update.name, pending: pending)];
      if (!pending) {
        _enabled = true;
        _syncImages = true;
        _hasEnabledBefore = true;
      }
      await _save();
      _publish(pending ? 'Finishing pairing' : 'Device paired');
    } catch (_) {
      _peers = previousPeers;
      _syncImages = previousSyncImages;
      _hasEnabledBefore = previousEnabledBefore;
      _enabled = false;
      _publish('Pairing could not be saved; synchronization is disabled');
      rethrow;
    } finally {
      _busy = false;
    }
    if (!pending && !_pairingDisposed) {
      // Both routes execute this only after mutual authentication and storage.
      // Keep the saved preferences on if OS access still needs user approval.
      try {
        await authorize();
      } catch (_) {
        _publish('Device paired; authorize clipboard access to start sharing');
      }
    }
  }

  Future<void> discardPendingPairing(String fingerprint) async {
    if (_peers.any((p) => p.fingerprint == fingerprint && p.pending)) {
      await setPeers(_peers.where((p) => p.fingerprint != fingerprint || !p.pending).toList());
    }
  }

  Future<void> _start() async {
    if (_runtime != null) return;
    try {
      final native = await _methods.invokeMapMethod<String, dynamic>('status');
      if (!_enabled) return;
      if (native?['supported'] != true || native?['authorized'] != true) {
        _publish('Authorize clipboard access first. Android requires ADB-mode Shizuku and notifications.');
        return;
      }
      _sequence = native?['sequence'] as int? ?? 0;
      _subscription = _events.receiveBroadcastStream().listen(
        _nativeEvent,
        onError: (_) {
          _halt('Native clipboard monitor unavailable');
        },
      );
      final runtime = await startClipboardRuntime(
        certificate: _certificate!,
        privateKey: _privateKey!,
        port: clipboardSyncPort,
        syncImages: _syncImages,
        peers: _peers
            .where((p) => !p.pending)
            .map((p) => RsClipboardPeer(fingerprint: p.fingerprint, address: p.address, send: p.send, receive: p.receive))
            .toList(),
      );
      if (!_enabled) {
        await runtime.stop();
        return;
      }
      _runtime = runtime;
      if (_discoveryHosts != null) {
        _addressTimer = Timer.periodic(const Duration(seconds: 10), (_) {
          if (_refreshingAddresses || _busy || !_peers.any((p) => !p.pending && !_connectedPeers.contains(p.fingerprint))) return;
          unawaited(refreshDiscoveredAddresses(_discoveryHosts!()));
        });
      }
      if (Platform.isAndroid) _captureIssue = 'Starting Android clipboard listener';
      await _methods.invokeMethod<void>('start', {'syncImages': _syncImages});
      if (_runtime != runtime) return;
      _watchConnection();
      _publish('Waiting for paired devices');
      unawaited(_updates(runtime));
    } catch (_) {
      await _stop();
      _publish('Clipboard sync could not start. Check port, pairing and native permissions.');
    }
  }

  void _nativeEvent(dynamic event) {
    if (_runtime == null || event is! Map) return;
    switch (event['kind']) {
      case 'changed':
        _requestCapture();
      case 'status':
        _publish(event['message'] as String? ?? 'Clipboard monitor ready');
      case 'captureUnavailable':
        _captureIssue = event['message'] as String? ?? 'Android clipboard capture unavailable';
        _publish(_captureIssue!);
      case 'captureReady':
        _captureIssue = null;
        _publish(_connected > 0 ? 'Connected' : 'Waiting for paired devices');
      case 'screenshotUnavailable':
        _screenshotIssue = event['message'] as String? ?? 'Screenshot sharing unavailable';
        _publish(_screenshotIssue!);
      case 'screenshotReady':
        _screenshotIssue = null;
        _publish(_connected > 0 ? 'Connected' : 'Waiting for paired devices');
      case 'fatal':
        _halt(event['message'] as String? ?? 'Clipboard monitor failed');
      case 'stopped':
        _halt('Disabled');
    }
  }

  void _halt(String reason) {
    _enabled = false;
    final stop = _stop();
    _publish(reason);
    unawaited(
      stop
          .then((_) async {
            await _save();
            _publish(reason);
          })
          .catchError((Object _) {
            _publish(reason);
          }),
    );
  }

  Future<void> _enqueue(Future<void> Function() work) {
    final next = _nativeQueue.then((_) => work());
    _nativeQueue = next.catchError((Object _) {
      _publish('Native clipboard operation failed');
    });
    return next;
  }

  void _requestCapture([int retry = 0]) {
    if (_captureQueued) return;
    _captureQueued = true;
    unawaited(
      _enqueue(() async {
        _captureQueued = false;
        final runtime = _runtime;
        if (runtime == null) return;
        try {
          final data = await _methods.invokeMapMethod<String, dynamic>('read');
          if (_runtime != runtime) return;
          _sequence = data?['sequence'] as int? ?? _sequence;
          if (data?['suppressEcho'] == true) return;
          final image = data?['image'] as Uint8List?;
          if (_syncImages && image != null) {
            await runtime.captureImage(imagePng: image);
          } else {
            await runtime.captureText(text: data?['text'] as String?);
          }
          _captures++;
          _publish(_connected > 0 ? 'Connected' : 'Waiting for paired devices');
        } on PlatformException catch (error) {
          try {
            await runtime.captureText();
          } catch (_) {
            /* Owner may already have stopped. */
          }
          if (error.code == 'CLIPBOARD_BUSY' && retry < 4) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            _requestCapture(retry + 1);
          } else {
            _publish('Clipboard capture unavailable');
          }
        } catch (_) {
          _publish('Clipboard capture rejected');
        }
      }).catchError((Object _) {}),
    );
  }

  Future<void> _updates(RsClipboardRuntime runtime) async {
    var revision = BigInt.zero;
    try {
      while (_runtime == runtime) {
        final update = await runtime.nextUpdate(after: revision);
        if (_runtime != runtime) return;
        if (update == null) {
          await _stop();
          _publish('Clipboard runtime stopped; disable and enable sync to restart');
          return;
        }
        revision = update.revision;
        _connectedPeers = update.connectedPeers.toSet();
        _connected = _connectedPeers.length;
        _watchConnection();
        _publish(update.error ?? (_connected > 0 ? 'Connected' : 'Waiting for paired devices'));
        final text = update.text;
        final image = update.imagePng;
        final peer = _peers.where((p) => p.fingerprint == update.origin && !p.pending).firstOrNull;
        final deviceName = _pairingName(peer?.name ?? '');
        if (text != null || image != null) {
          await _enqueue(() async {
            if (_runtime != runtime) return;
            final expected = _sequence;
            final shouldApply = image != null
                ? _syncImages && await runtime.shouldApplyImage(imagePng: image)
                : await runtime.shouldApply(text: text!);
            if (!shouldApply || _runtime != runtime) return;
            try {
              _sequence =
                  await _methods.invokeMethod<int>(
                    image != null ? 'writeImage' : 'write',
                    {
                      if (image != null) ...{
                        'image': image,
                        'notificationTitle': t.clipboardSync.imageArrivedTitle,
                        'notificationBody': t.clipboardSync.imageArrivedBody(device: deviceName.isEmpty ? t.clipboardSync.unnamedDevice : deviceName),
                      } else
                        'text': text,
                      'sequence': expected,
                    },
                  ) ??
                  _sequence;
              _applied++;
              _publish('Connected');
            } on PlatformException catch (error) {
              if (error.code == 'STALE_WRITE') {
                _requestCapture();
              } else {
                _publish('Remote clipboard write failed; copy again when the clipboard is available');
              }
            }
          });
        }
      }
    } catch (_) {
      if (_runtime == runtime) {
        await _stop();
        _publish('Clipboard connection stopped unexpectedly');
      }
    }
  }

  // A failed connection cannot prove AP isolation: the peer may simply be
  // offline. Warn only after a sustained outage, and explain both possibilities.
  void _watchConnection() {
    if (_connected > 0) {
      _connectionTimer?.cancel();
      _connectionTimer = null;
      _connectionWarning = false;
    } else if (_connectionTimer == null && _peers.any((p) => !p.pending && (p.send || p.receive))) {
      _connectionTimer = Timer(const Duration(seconds: 30), () {
        if (_runtime == null || _connected > 0) return;
        _connectionWarning = true;
        _publish('Waiting for paired devices');
      });
    }
  }

  Future<void> _stop() async {
    _addressTimer?.cancel();
    _addressTimer = null;
    final runtime = _runtime;
    _runtime = null;
    _connectionTimer?.cancel();
    _connectionTimer = null;
    _connectionWarning = false;
    _captureIssue = null;
    _screenshotIssue = null;
    _connected = 0;
    _connectedPeers = {};
    await runtime?.stop();
    try {
      await _methods.invokeMethod<void>('stop');
    } catch (_) {
      /* Still release Rust ownership. */
    }
    await _subscription?.cancel();
    _subscription = null;
  }
}
