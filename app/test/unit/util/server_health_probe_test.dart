import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/server_health_probe.dart';
import 'package:localsend_isolates/model/stored_security_context.dart';

void main() {
  final certificate = File('test/fixtures/clipboard_probe/cert.pem').readAsStringSync();
  final key = File('test/fixtures/clipboard_probe/key.pem').readAsStringSync();
  final identity = StoredSecurityContext(
    certificate: certificate,
    privateKey: key,
    publicKey: '',
    certificateHash: sha256.convert(base64Decode(certificate.replaceAll(RegExp(r'-----[^\r\n]+-----|\s'), ''))).toString().toUpperCase(),
  );

  test('HTTP readiness fails when TCP works but the event receiver is gone', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var status = HttpStatus.ok;
    server.listen((request) async {
      expect(request.uri.path, '/api/localsend/v2/info');
      request.response.statusCode = status;
      await request.response.close();
    });
    await probeLocalServer(port: server.port, https: false, identity: identity);
    status = HttpStatus.serviceUnavailable;
    await expectLater(probeLocalServer(port: server.port, https: false, identity: identity), throwsA(isA<HttpException>()));
  });

  test('a listener that accepts TCP but never answers HTTP times out', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    server.listen(sockets.add);
    addTearDown(() async {
      for (final socket in sockets) {
        socket.destroy();
      }
      await server.close();
    });
    await expectLater(
      probeLocalServer(port: server.port, https: false, identity: identity, timeout: const Duration(milliseconds: 100)),
      throwsA(isA<Exception>()),
    );
  });

  test('HTTPS readiness presents the device certificate to the TLS server', () async {
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(certificate))
      ..usePrivateKeyBytes(utf8.encode(key))
      ..setTrustedCertificatesBytes(utf8.encode(certificate));
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
      requestClientCertificate: true,
    );
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      expect(request.certificate, isNotNull);
      await request.response.close();
    });
    await probeLocalServer(port: server.port, https: true, identity: identity);
  });
}
