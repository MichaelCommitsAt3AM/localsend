import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_app/util/clipboard_pairing_link.dart';

void main() {
  const invitation = '{"version":2,"kind":"localsend-clipboard-pair"}';
  test('HTTPS QR link round-trips with the invitation entirely in the fragment', () {
    final link = encodeClipboardPairingLink(invitation);
    final uri = Uri.parse(link);
    expect(uri.scheme, 'https');
    expect(uri.host, 'localsend.currenta.tech');
    expect(uri.path, '/pair');
    expect(uri.query, isEmpty);
    expect(decodeClipboardPairingLink(link), invitation);
  });
  test('custom app fallback and legacy QR remain accepted', () {
    final fragment = Uri.parse(encodeClipboardPairingLink(invitation)).fragment;
    expect(decodeClipboardPairingLink('localsend-clipboard://pair#$fragment'), invitation);
    expect(decodeClipboardPairingLink(invitation), invitation);
  });
  test('wrong domains, credentials, endpoints and malformed payloads are rejected', () {
    final fragment = Uri.parse(encodeClipboardPairingLink(invitation)).fragment;
    for (final link in [
      'http://localsend.currenta.tech/pair#$fragment',
      'https://localsend.currenta.tech.evil.test/pair#$fragment',
      'https://evil@localsend.currenta.tech/pair#$fragment',
      'https://localsend.currenta.tech:444/pair#$fragment',
      'https://localsend.currenta.tech/other#$fragment',
      'https://localsend.currenta.tech/pair?token=private#$fragment',
      'localsend-clipboard://other#$fragment',
      'https://localsend.currenta.tech/pair#invalid*',
      'https://localsend.currenta.tech/pair#${base64Url.encode([255]).replaceAll('=', '')}',
      'x' * 8193,
    ]) {
      expect(() => decodeClipboardPairingLink(link), throwsFormatException);
    }
  });
  test('both encoded and decoded invitation bounds are enforced', () {
    expect(() => encodeClipboardPairingLink('x' * 4097), throwsFormatException);
    final fragment = base64Url.encode(utf8.encode('x' * 4097)).replaceAll('=', '');
    expect(() => decodeClipboardPairingLink('localsend-clipboard://pair#$fragment'), throwsFormatException);
  });
}
