import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'server_user_agent.dart';

void configureServerDio(Dio dio) {
  // The server WebSocket (/socket, /embywebsocket) otherwise announces itself
  // as "Dart/x.y (dart:io)"; give it the same browser agent as HTTP traffic.
  WebSocket.userAgent = serverUserAgent;

  dio.transformer = FusedTransformer(contentLengthIsolateThreshold: 50 * 1024);

  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient();

      client.userAgent = serverUserAgent;

      client.badCertificateCallback = (_, _, _) => true;

      client.connectionTimeout = const Duration(seconds: 30);
      client.idleTimeout = const Duration(seconds: 120);

      // Six connections per server, the same ceiling a browser gives the
      // Jellyfin web client. Extra requests queue on the device instead of
      // hitting a slow server all at once (60+ concurrent queries made it
      // time out and answer 502 for everything).
      // 4 (was 6): together with images and the video stream this kept
      // Voltix at ~13 connections to one provider; the Jellyfin app uses ~5.
      client.maxConnectionsPerHost = 4;

      return client;
    },
  );
}