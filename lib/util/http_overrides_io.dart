import 'dart:io';

import 'package:server_core/server_core.dart';

import 'insecure_certificates.dart';

void configureHttpOverrides() {
  // Some strict or older Nginx reverse proxies on 443 abort the handshake unless
  // the client allows legacy TLS renegotiation, so enable it for every connection.
  // This is a deliberate trade-off. It weakens TLS against the CVE-2009-3555
  // renegotiation attack to reach those servers, and the real fix is the server's
  // TLS config, so revisit this if that changes.
  try {
    SecurityContext.defaultContext.allowLegacyUnsafeRenegotiation = true;
  } catch (_) {}
  HttpOverrides.global = _MoonfinHttpOverrides();
}

class _MoonfinHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final secContext = context ?? SecurityContext.defaultContext;
    try {
      secContext.allowLegacyUnsafeRenegotiation = true;
    } catch (_) {}
    final client = super.createHttpClient(secContext);
    // Six connections per server, the same ceiling a browser gives the
    // Jellyfin web client. Extra requests queue on the device instead of
    // hitting a slow server all at once (60+ concurrent queries made it
    // time out and answer 502 for everything).
    // 3 for images (was 6); see configure_server_dio_io.dart.
    client.maxConnectionsPerHost = 3;
    // Every plain HttpClient (poster/image loading, package:http, WebSockets)
    // would otherwise send "Dart/x.y (dart:io)". Use the same browser agent as
    // the media-server API so Lumistream sees one consistent client.
    client.userAgent = serverUserAgent;
    // Only bypass certificate validation when the user has explicitly opted in
    // (self-signed / private-CA servers). The flag is read on every failed
    // handshake, so the toggle applies live without reinstalling the override.
    client.badCertificateCallback = (_, _, _) => gAllowSelfSignedCertificates;
    return client;
  }
}
