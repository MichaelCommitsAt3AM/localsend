import 'dart:convert';

const clipboardPairingHost = 'localsend.currenta.tech';

/// The fragment is never included in HTTP requests to the link website.
String encodeClipboardPairingLink(String invitation) {
  if (utf8.encode(invitation).length > 4096) throw const FormatException('Invalid pairing invitation');
  return Uri(
    scheme: 'https',
    host: clipboardPairingHost,
    path: '/pair',
    fragment: base64Url.encode(utf8.encode(invitation)).replaceAll('=', ''),
  ).toString();
}

/// Decode only our exact endpoints. Rust validates the invitation and TLS pins.
String decodeClipboardPairingLink(String value) {
  if (value.length > 8192) throw const FormatException('Invalid pairing link');
  // Accept development QR codes generated before app links were introduced.
  if (value.startsWith('{')) {
    if (utf8.encode(value).length > 4096) throw const FormatException('Invalid pairing invitation');
    return value;
  }
  final uri = Uri.tryParse(value);
  final web = uri?.scheme == 'https' && uri?.host == clipboardPairingHost && uri?.path == '/pair';
  final app = uri?.scheme == 'localsend-clipboard' && uri?.host == 'pair' && uri?.path == '';
  if (uri == null ||
      (!web && !app) ||
      uri.hasPort ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(uri.fragment)) {
    throw const FormatException('Invalid pairing link');
  }
  try {
    final bytes = base64Url.decode(base64Url.normalize(uri.fragment));
    if (bytes.length > 4096) throw const FormatException();
    return utf8.decode(bytes);
  } catch (_) {
    throw const FormatException('Invalid pairing link');
  }
}
