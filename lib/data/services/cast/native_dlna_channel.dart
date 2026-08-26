import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'cast_target.dart';
import '../../../l10n/current_app_localizations.dart';
import '../../../util/platform_detection.dart';

class NativeDlnaChannel {
  static const MethodChannel _channel = MethodChannel('com.voltix/native_dlna');
  static const EventChannel _events = EventChannel('com.voltix/native_dlna_events');
  static Stream<Map<String, dynamic>>? _cachedEventStream;
  static final StreamController<Map<String, dynamic>> _desktopEventController =
      StreamController<Map<String, dynamic>>.broadcast();

  static String? _activeDesktopControlUrl;
  static bool _isDesktopDiscovering = false;

  const NativeDlnaChannel();

  static bool get _isNativeMobile => PlatformDetection.isMobile;

  Future<List<CastTarget>> discoverDlnaTargets() async {
    final l10n = currentAppLocalizations();
    final targets = <CastTarget>[];

    if (_isNativeMobile) {
      try {
        final raw = await _channel.invokeMethod<List<dynamic>>('discoverDlnaTargets');
        if (raw != null) {
          targets.addAll(
            raw
                .whereType<Map>()
                .map((entry) => entry.cast<String, dynamic>())
                .map(
                  (entry) => CastTarget(
                    id: entry['id']?.toString() ?? '',
                    kind: CastTargetKind.dlna,
                    title: entry['title'] as String? ?? l10n.castDlna,
                    subtitle: entry['subtitle'] as String? ?? '',
                  ),
                )
                .where((target) => target.id.isNotEmpty),
          );
        }
      } catch (e) {
        debugPrint('⚡🎯 [DlnaChannel] Native discovery error: $e');
      }
    }

    // Pure Dart SSDP network scan (works on Windows, Linux, macOS & mobile)
    final dartTargets = await _discoverDartDlnaTargets();
    for (final dt in dartTargets) {
      if (!targets.any((t) => t.id == dt.id)) {
        targets.add(dt);
      }
    }

    return targets;
  }

  /// Starts a continuous DLNA (SSDP) scan across the local network.
  Future<void> startDlnaDiscovery() async {
    if (_isNativeMobile) {
      try {
        await _channel.invokeMethod<void>('startDlnaDiscovery');
      } catch (_) {}
    }

    if (_isDesktopDiscovering) return;
    _isDesktopDiscovering = true;

    Future.microtask(() async {
      final seenIds = <String>{};
      while (_isDesktopDiscovering) {
        final targets = await _discoverDartDlnaTargets();
        for (final t in targets) {
          if (seenIds.add(t.id)) {
            _desktopEventController.add({
              'kind': 'dlna',
              'state': 'deviceFound',
              'id': t.id,
              'title': t.title,
              'subtitle': t.subtitle,
            });
          }
        }
        if (_isDesktopDiscovering) {
          await Future.delayed(const Duration(seconds: 3));
        }
      }
    });
  }

  /// Stops continuous DLNA scan.
  Future<void> stopDlnaDiscovery() async {
    _isDesktopDiscovering = false;
    if (_isNativeMobile) {
      try {
        await _channel.invokeMethod<void>('stopDlnaDiscovery');
      } catch (_) {}
    }
  }

  Future<void> playToDlnaDevice({
    required String targetId,
    required String streamUrl,
    required String title,
    int? startPositionTicks,
  }) async {
    _activeDesktopControlUrl = targetId;

    if (_isNativeMobile) {
      try {
        await _channel.invokeMethod<void>('playToDlnaDevice', {
          'targetId': targetId,
          'streamUrl': streamUrl,
          'title': title,
          'startPositionTicks': startPositionTicks,
        });
        return;
      } catch (e) {
        debugPrint('⚡🎯 [DlnaChannel] Native play fallback to Dart SOAP: $e');
      }
    }

    final didlMetadata = '''
<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:sec="http://www.sec.co.kr/">
  <item id="1" parentID="0" restricted="1">
    <dc:title>${_escapeXml(title)}</dc:title>
    <upnp:class>object.item.videoItem.movie</upnp:class>
    <res protocolInfo="http-get:*:video/mp4:DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000">${_escapeXml(streamUrl)}</res>
  </item>
</DIDL-Lite>''';

    // Pure Dart UPnP AVTransport SOAP execution
    await _sendDartSoap(
      controlUrl: targetId,
      action: 'SetAVTransportURI',
      innerBody: '<InstanceID>0</InstanceID><CurrentURI>${_escapeXml(streamUrl)}</CurrentURI><CurrentURIMetaData>${_escapeXml(didlMetadata)}</CurrentURIMetaData>',
    );
    await _sendDartSoap(
      controlUrl: targetId,
      action: 'Play',
      innerBody: '<InstanceID>0</InstanceID><Speed>1</Speed>',
    );

    _desktopEventController.add({'kind': 'dlna', 'state': 'playing'});
  }

  Future<void> pauseDlna() async {
    final url = _activeDesktopControlUrl;
    if (_isNativeMobile) {
      try {
        await _channel.invokeMethod<void>('pauseDlna');
        return;
      } catch (_) {}
    }
    if (url != null) {
      await _sendDartSoap(controlUrl: url, action: 'Pause', innerBody: '<InstanceID>0</InstanceID>');
      _desktopEventController.add({'kind': 'dlna', 'state': 'paused'});
    }
  }

  Future<void> playDlna() async {
    final url = _activeDesktopControlUrl;
    if (_isNativeMobile) {
      try {
        await _channel.invokeMethod<void>('playDlna');
        return;
      } catch (_) {}
    }
    if (url != null) {
      await _sendDartSoap(controlUrl: url, action: 'Play', innerBody: '<InstanceID>0</InstanceID><Speed>1</Speed>');
      _desktopEventController.add({'kind': 'dlna', 'state': 'playing'});
    }
  }

  Future<void> seekDlna({required int positionTicks}) async {
    final url = _activeDesktopControlUrl;
    if (_isNativeMobile) {
      try {
        await _channel.invokeMethod<void>('seekDlna', {'positionTicks': positionTicks});
        return;
      } catch (_) {}
    }
    if (url != null) {
      final timeStr = _formatDlnaTime(positionTicks);
      await _sendDartSoap(
        controlUrl: url,
        action: 'Seek',
        innerBody: '<InstanceID>0</InstanceID><Unit>REL_TIME</Unit><Target>$timeStr</Target>',
      );
    }
  }

  Future<void> stopDlna() async {
    final url = _activeDesktopControlUrl;
    if (_isNativeMobile) {
      try {
        await _channel.invokeMethod<void>('stopDlna');
        return;
      } catch (_) {}
    }
    if (url != null) {
      await _sendDartSoap(controlUrl: url, action: 'Stop', innerBody: '<InstanceID>0</InstanceID>');
      _desktopEventController.add({'kind': 'dlna', 'state': 'idle'});
    }
  }

  Future<double?> getDlnaVolume() async {
    if (_isNativeMobile) {
      try {
        return await _channel.invokeMethod<double>('getDlnaVolume');
      } catch (_) {}
    }
    return 1.0;
  }

  Future<void> setDlnaVolume({required double volume}) async {
    if (_isNativeMobile) {
      try {
        await _channel.invokeMethod<void>('setDlnaVolume', {'volume': volume});
      } catch (_) {}
    }
  }

  Stream<Map<String, dynamic>> dlnaEventStream() {
    if (_isNativeMobile) {
      _cachedEventStream ??= _events
          .receiveBroadcastStream()
          .map((event) {
            if (event is Map) {
              return event.cast<String, dynamic>();
            }
            return <String, dynamic>{};
          })
          .where((event) => event.isNotEmpty);
      return _cachedEventStream!;
    }
    return _desktopEventController.stream;
  }

  // ──────────────── Pure Dart SSDP & SOAP Implementation ────────────────

  static Future<List<CastTarget>> _discoverDartDlnaTargets() async {
    final targets = <CastTarget>[];
    final seenLocations = <String>{};
    final l10n = currentAppLocalizations();

    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      socket.readEventsEnabled = true;

      final searchTargets = [
        'urn:schemas-upnp-org:service:AVTransport:1',
        'urn:schemas-upnp-org:device:MediaRenderer:1',
        'upnp:rootdevice',
        'ssdp:all',
      ];

      final group = InternetAddress('239.255.255.250');
      for (final st in searchTargets) {
        final msg = 'M-SEARCH * HTTP/1.1\r\n'
            'HOST: 239.255.255.250:1900\r\n'
            'MAN: "ssdp:discover"\r\n'
            'MX: 2\r\n'
            'ST: $st\r\n'
            '\r\n';
        socket.send(utf8.encode(msg), group, 1900);
      }

      final httpClient = HttpClient()..connectionTimeout = const Duration(seconds: 2);

      final sub = socket.listen((event) async {
        if (event == RawSocketEvent.read) {
          final packet = socket.receive();
          if (packet == null) return;
          final response = utf8.decode(packet.data, allowMalformed: true);

          final locationMatch = RegExp(r'LOCATION:\s*(http[s]?://[^\s\r\n]+)', caseSensitive: false).firstMatch(response);
          if (locationMatch == null) return;
          final locationUrl = locationMatch.group(1)!;

          if (!seenLocations.add(locationUrl)) return;

          try {
            final req = await httpClient.getUrl(Uri.parse(locationUrl));
            final res = await req.close();
            if (res.statusCode == 200) {
              final xmlStr = await res.transform(utf8.decoder).join();

              final friendlyNameMatch = RegExp(r'<friendlyName>([^<]+)</friendlyName>', caseSensitive: false).firstMatch(xmlStr);
              final title = friendlyNameMatch?.group(1) ?? l10n.castDlna;

              final modelNameMatch = RegExp(r'<modelName>([^<]+)</modelName>', caseSensitive: false).firstMatch(xmlStr);
              final subtitle = modelNameMatch?.group(1) ?? 'Smart TV';

              if (xmlStr.contains('AVTransport')) {
                final controlMatch = RegExp(r'<serviceType>[^<]*AVTransport[^<]*</serviceType>[\s\S]*?<controlURL>([^<]+)</controlURL>', caseSensitive: false).firstMatch(xmlStr);
                if (controlMatch != null) {
                  final relUrl = controlMatch.group(1)!;
                  final resolvedControlUrl = Uri.parse(locationUrl).resolve(relUrl).toString();

                  targets.add(CastTarget(
                    id: resolvedControlUrl,
                    kind: CastTargetKind.dlna,
                    title: title,
                    subtitle: subtitle,
                  ));
                }
              }
            }
          } catch (_) {}
        }
      });

      await Future.delayed(const Duration(seconds: 2));
      await sub.cancel();
      socket.close();
      httpClient.close();
    } catch (e) {
      debugPrint('⚡🎯 [DartDlna] SSDP scan error: $e');
    }

    return targets;
  }

  static Future<void> _sendDartSoap({
    required String controlUrl,
    required String action,
    required String innerBody,
  }) async {
    final envelope = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:$action xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
      $innerBody
    </u:$action>
  </s:Body>
</s:Envelope>''';

    try {
      final uri = Uri.parse(controlUrl);
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
      final req = await client.postUrl(uri);
      req.headers.set('Content-Type', 'text/xml; charset="utf-8"');
      req.headers.set('SOAPAction', '"urn:schemas-upnp-org:service:AVTransport:1#$action"');
      req.write(envelope);
      final res = await req.close();
      await res.drain();
      client.close();
    } catch (e) {
      debugPrint('⚡🎯 [DartDlna] SOAP error ($action): $e');
    }
  }

  static String _formatDlnaTime(int ticks) {
    final totalSeconds = ticks ~/ 10000000;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  static String _escapeXml(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}
