import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/clipboard_peer_probe.dart';

void main() {
  final certificate = File('test/fixtures/clipboard_probe/cert.pem').readAsStringSync();
  final key = File('test/fixtures/clipboard_probe/key.pem').readAsStringSync();
  final der = base64Decode(certificate.replaceAll(RegExp(r'-----[^\r\n]+-----|\s'), ''));
  final identity = sha256.convert(der).toString().toUpperCase();

  Future<SecureServerSocket> serve(List<String> protocols) async {
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(certificate))
      ..usePrivateKeyBytes(utf8.encode(key))
      ..setTrustedCertificatesBytes(utf8.encode(certificate))
      ..setAlpnProtocols(protocols, true);
    final server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      context,
      requestClientCertificate: true,
      requireClientCertificate: true,
      supportedProtocols: protocols,
    );
    server.listen((socket) {
      socket.listen((_) => fail('Address probes must not send application data'), onDone: socket.destroy, onError: (Object _) => socket.destroy());
    }, onError: (Object _) {});
    addTearDown(server.close);
    return server;
  }

  test('probe proves the clipboard certificate identity using a real TLS handshake', () async {
    final server = await serve(['localsend-clipboard/2']);
    expect(await probeClipboardPeers(certificate, key, {identity}, ['127.0.0.1'], server.port), {identity: '127.0.0.1:${server.port}'});
  });

  test('a reachable TLS server with an unpaired certificate is rejected', () async {
    final server = await serve(['localsend-clipboard/2']);
    expect(await probeClipboardPeers(certificate, key, {'A' * 64}, ['127.0.0.1'], server.port), isEmpty);
  });

  test('a paired certificate serving another protocol is rejected', () async {
    final server = await serve(['another-protocol']);
    expect(await probeClipboardPeers(certificate, key, {identity}, ['127.0.0.1'], server.port), isEmpty);
  });
}
