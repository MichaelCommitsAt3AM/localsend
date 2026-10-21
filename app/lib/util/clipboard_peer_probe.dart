import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

/// Discovery supplies routing hints only. Authenticate the separate clipboard
/// identity before changing a saved pairing, without sending clipboard content.
Future<Map<String, String>> probeClipboardPeers(
  String certificate,
  String privateKey,
  Set<String> pins,
  List<String> hosts,
  int port,
) => Isolate.run(() async {
  final context = SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(certificate))
    ..usePrivateKeyBytes(utf8.encode(privateKey));
  final found = <String, String>{};
  // Keep connection attempts bounded even on a large shared network.
  for (var offset = 0; offset < hosts.length; offset += 4) {
    await Future.wait(
      hosts.skip(offset).take(4).map((host) async {
        SecureSocket? socket;
        try {
          socket = await SecureSocket.connect(
            host,
            port,
            context: context,
            supportedProtocols: ['localsend-clipboard/2'],
            timeout: const Duration(seconds: 3),
            onBadCertificate: (cert) => pins.contains(sha256.convert(cert.der).toString().toUpperCase()),
          );
          final cert = socket.peerCertificate;
          if (cert == null || socket.selectedProtocol != 'localsend-clipboard/2') return;
          final identity = sha256.convert(cert.der).toString().toUpperCase();
          if (pins.contains(identity)) found[identity] = '$host:$port';
        } on IOException {
          // Offline, unpaired, or blocked peers are expected during discovery.
        } finally {
          socket?.destroy();
        }
      }),
    );
  }
  return found;
});
