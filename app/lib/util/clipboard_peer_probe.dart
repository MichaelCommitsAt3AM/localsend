import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';

/// Discovery supplies routing hints only. Authenticate the separate clipboard
/// identity before changing a saved pairing, without sending clipboard content.
Future<Map<String, String>> probeClipboardPeers(
  String certificate,
  String privateKey,
  Set<String> pins,
  List<String> hosts,
  int port,
) async {
  final (found, outcomes) = await Isolate.run(() => _probe(certificate, privateKey, pins, hosts, port));
  // Outcomes are gathered in the probe isolate, whose log records never reach
  // this isolate's persistent connection log.
  final log = Logger('ClipboardSync');
  for (final outcome in outcomes) {
    log.info('Probe $outcome');
  }
  return found;
}

Future<(Map<String, String>, List<String>)> _probe(
  String certificate,
  String privateKey,
  Set<String> pins,
  List<String> hosts,
  int port,
) async {
  final context = SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(certificate))
    ..usePrivateKeyBytes(utf8.encode(privateKey));
  final found = <String, String>{};
  final outcomes = <String>[];
  // Keep connection attempts bounded even on a large shared network.
  for (var offset = 0; offset < hosts.length; offset += 4) {
    await Future.wait(
      hosts.skip(offset).take(4).map((host) async {
        RawSocket? transport;
        RawSecureSocket? socket;
        var stage = 'connect';
        try {
          transport = await RawSocket.connect(host, port, timeout: const Duration(seconds: 3));
          stage = 'TLS';
          // SecureSocket.connect's timeout only covers TCP. An old discovery
          // address may accept TCP without answering TLS; never let that stall
          // this batch and all subsequent address refreshes indefinitely.
          socket = await RawSecureSocket.secure(
            transport,
            context: context,
            supportedProtocols: ['localsend-clipboard/2'],
            onBadCertificate: (cert) => pins.contains(sha256.convert(cert.der).toString().toUpperCase()),
          ).timeout(const Duration(seconds: 3));
          final cert = socket.peerCertificate;
          if (cert == null || socket.selectedProtocol != 'localsend-clipboard/2') {
            outcomes.add('$host: no certificate or protocol ${socket.selectedProtocol}');
            return;
          }
          final identity = sha256.convert(cert.der).toString().toUpperCase();
          if (pins.contains(identity)) {
            found[identity] = '$host:$port';
            outcomes.add('$host: verified ${identity.substring(0, 8)}');
          } else {
            outcomes.add('$host: unpinned identity ${identity.substring(0, 8)}');
          }
        } on IOException catch (error) {
          // Offline, unpaired, or blocked peers are expected during discovery.
          outcomes.add('$host: $stage failed: $error');
        } on TimeoutException {
          // A reachable host is not necessarily a responsive clipboard server.
          outcomes.add('$host: $stage timed out');
        } finally {
          unawaited(socket?.close());
          // Keep ownership of TCP through the handshake so a TLS timeout also
          // closes its underlying connection, even before a secure socket exists.
          unawaited(transport?.close());
        }
      }),
    );
  }
  return (found, outcomes);
}
