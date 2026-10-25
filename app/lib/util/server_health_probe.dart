import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:localsend_isolates/model/stored_security_context.dart';

/// Check HTTP readiness, including the receiver of server events. A TCP
/// handshake alone succeeds even when the server isolate has stopped listening.
Future<void> probeLocalServer({
  required int port,
  required bool https,
  required StoredSecurityContext identity,
  Duration timeout = const Duration(seconds: 2),
}) async {
  final context = SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(identity.certificate))
    ..usePrivateKeyBytes(utf8.encode(identity.privateKey));
  final client = HttpClient(context: context)
    ..connectionTimeout = timeout
    ..findProxy = ((_) => 'DIRECT')
    ..badCertificateCallback = ((cert, host, _) =>
        host == InternetAddress.loopbackIPv4.address && sha256.convert(cert.der).toString().toUpperCase() == identity.certificateHash);
  try {
    await (() async {
      final request = await client.getUrl(
        Uri(
          scheme: https ? 'https' : 'http',
          host: InternetAddress.loopbackIPv4.address,
          port: port,
          path: '/api/localsend/v2/info',
        ),
      );
      request.followRedirects = false;
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('Local server is not ready (${response.statusCode})');
      }
      await response.drain<void>();
    })().timeout(timeout);
  } finally {
    client.close(force: true);
  }
}
