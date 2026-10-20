import '../models/device_info.dart';

/// Client name sent to media servers in the authorization header.
///
/// Lumistream rejects sign-ins whose Client names a third-party app with a
/// bare 403 ("Moonfin" from 2026-10-01, "Voltix for ..." from 2026-10-05),
/// while "Jellyfin Web" is accepted - the same identity the Voltix server
/// proxy already uses. The device name and version are still sent, so
/// sessions stay identifiable in the server dashboard.
const String serverClientName = 'Jellyfin Web';

/// Version sent with [serverClientName]. A Jellyfin Web release number, so
/// the header matches what a real Jellyfin Web session sends. (The Voltix app
/// version is still reported to the Voltix backend separately.)
const String serverClientVersion = '10.10.7';

String buildServerAuthorizationHeader({
  required String scheme,
  required DeviceInfo deviceInfo,
  String? accessToken,
}) {
  final client = _sanitizeHeaderValue(serverClientName);
  final device = _sanitizeHeaderValue(deviceInfo.name);
  final deviceId = _sanitizeHeaderValue(deviceInfo.id);
  final version = _sanitizeHeaderValue(serverClientVersion);

  final authHeader = StringBuffer(
    '$scheme Client="$client", '
    'Device="$device", '
    'DeviceId="$deviceId", '
    'Version="$version"',
  );

  if (accessToken != null && accessToken.isNotEmpty) {
    authHeader.write(', Token="${_sanitizeHeaderValue(accessToken)}"');
  }

  return authHeader.toString();
}

String _sanitizeHeaderValue(String value) {
  final asciiOnly = value.replaceAll(RegExp(r'[^\x20-\x7E]'), ' ');
  final noQuotes = asciiOnly
      .replaceAll('"', '')
      .replaceAll('\\', '')
      .replaceAll(',', ' ')
      .replaceAll(RegExp(r'[\r\n\t]'), ' ');

  final collapsed = noQuotes.replaceAll(RegExp(r'\s+'), ' ').trim();
  return collapsed.isEmpty ? 'Unknown' : collapsed;
}