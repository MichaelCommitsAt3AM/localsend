import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/rust/api/clipboard.dart';

class PairingSessionFake extends Fake implements RsClipboardPairing {
  RsPairingUpdate? _latest;
  Completer<void> _changed = Completer<void>();
  bool _stopped = false;
  int stops = 0;
  final approvals = <bool>[];
  final codes = <String>[];
  final persistedValues = <bool>[];

  void emit(String phase, {String code = ''}) {
    _latest = RsPairingUpdate(
      revision: (_latest?.revision ?? BigInt.zero) + BigInt.one,
      phase: phase,
      code: code,
      fingerprint: 'C' * 64,
      address: '192.0.2.2:53318',
      name: 'Other device',
      expires: BigInt.from(DateTime.now().millisecondsSinceEpoch ~/ 1000 + 180),
    );
    _changed.complete();
    _changed = Completer<void>();
  }

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
  Future<RsPairingUpdate?> nextUpdate({required BigInt after}) async {
    while (true) {
      if ((_latest?.revision ?? BigInt.zero) > after) return _latest;
      if (_stopped) return null;
      await _changed.future;
    }
  }

  @override
  Future<void> approve({required bool approved}) async => approvals.add(approved);

  @override
  Future<void> submitCode({required String code}) async => codes.add(code);

  @override
  Future<void> persisted({required bool saved}) async => persistedValues.add(saved);

  @override
  Future<void> stop() async {
    stops++;
    if (!_stopped) {
      _stopped = true;
      _changed.complete();
    }
  }
}
