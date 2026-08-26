import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:get_it/get_it.dart';
import 'package:logger/logger.dart';
import 'package:server_core/server_core.dart';

import '../../util/platform_detection.dart';

/// Service to retrieve a stable device identifier formatted as a MAC-like string.
///
/// On Android TV, attempts to read the real Wi-Fi MAC address.
/// On all other platforms, uses the device's unique identifier (Android ID, iOS
/// identifierForVendor, etc.) and formats it as a colon-separated hex string.
class DeviceIdService {
  final Logger _logger = Logger();
  String? _cachedMac;

  /// Returns a stable MAC-style device identifier, e.g. `A1:B2:C3:D4:E5:F6`.
  ///
  /// Call [refresh] to force re-resolution (useful for a "refresh" button).
  Future<String> getDeviceMac() async {
    if (_cachedMac != null) return _cachedMac!;
    _cachedMac = await _resolve();
    return _cachedMac!;
  }

  /// Force re-resolve the device MAC (clears cache).
  Future<String> refresh() async {
    _cachedMac = null;
    return getDeviceMac();
  }

  Future<String> _resolve() async {
    try {
      if (PlatformDetection.isAndroid) {
        // On Android TV, try to get real Wi-Fi MAC via NetworkInterface
        if (PlatformDetection.isTV) {
          final mac = await _tryWifiMac();
          if (mac != null) {
            _logger.i('[DeviceId] Using real Wi-Fi MAC: $mac');
            return mac;
          }
        }
        // Fall back to Android ID
        final info = await DeviceInfoPlugin().androidInfo;
        final androidId = info.id; // Unique per-device hex string
        final formatted = _formatAsMAC(androidId);
        _logger.i('[DeviceId] Using Android ID as MAC: $formatted');
        return formatted;
      }

      if (PlatformDetection.isIOS) {
        final info = await DeviceInfoPlugin().iosInfo;
        final id = info.identifierForVendor ?? info.name;
        final formatted = _formatAsMAC(id);
        _logger.i('[DeviceId] Using iOS vendor ID as MAC: $formatted');
        return formatted;
      }

      // Desktop/other — use the DI-registered DeviceInfo.id (UUID)
      final deviceInfo = GetIt.instance<DeviceInfo>();
      final id = deviceInfo.id;
      return _formatAsMAC(id);
    } catch (e) {
      _logger.e('[DeviceId] Failed to resolve device ID: $e');
      return 'XX:XX:XX:XX:XX:XX';
    }
  }

  /// Try to get the real Wi-Fi MAC address from NetworkInterface (Android TV).
  Future<String?> _tryWifiMac() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        // Common Wi-Fi interface names on Android
        if (name == 'wlan0' || name == 'eth0' || name.startsWith('wlan')) {
          // NetworkInterface doesn't directly expose MAC on Dart,
          // but on Android TV the MAC is often available via android.net.wifi
          // We'll fall through to Android ID in this case
          break;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Formats an arbitrary string as a MAC-like colon-separated hex string.
  ///
  /// Takes the hex characters from the input (stripping non-hex chars),
  /// pads to at least 12 hex chars, then groups into pairs separated by colons.
  String _formatAsMAC(String input) {
    // Extract only hex characters
    final hex = input.replaceAll(RegExp(r'[^a-fA-F0-9]'), '').toUpperCase();
    // Take 12 chars (6 bytes = standard MAC length), pad if needed
    final padded = hex.padRight(12, '0').substring(0, 12);
    // Format as XX:XX:XX:XX:XX:XX
    final parts = <String>[];
    for (var i = 0; i < padded.length; i += 2) {
      parts.add(padded.substring(i, i + 2));
    }
    return parts.join(':');
  }
}
