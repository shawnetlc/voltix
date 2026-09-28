import 'dart:async';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import '../preference/user_preferences.dart';
import 'platform_detection.dart';

/// Evaluates device hardware capabilities to prevent GPU crashes and stutter
/// from heavy animations (e.g. animated background particle layers) on lower-end
/// or crash-prone hardware such as Google Chromecast / Google TV devices.
class HardwareCapability {
  HardwareCapability._();

  static bool _hasEvaluated = false;
  static bool _isLowPerformance = false;
  static String? _detectionReason;
  static bool _isCheckingOrShowingDialog = false;

  /// Whether the hardware was detected as low-performance / crash-prone.
  static bool get isLowPerformance => _isLowPerformance;

  /// The reason why this hardware was classified as low performance, if any.
  static String? get detectionReason => _detectionReason;

  /// Evaluates the device hardware and determines if resource-intensive
  /// animations and effects should be disabled to prevent crashes or failure.
  static Future<bool> evaluate({bool force = false}) async {
    if (_hasEvaluated && !force) {
      return _isLowPerformance;
    }

    try {
      if (PlatformDetection.isAndroid) {
        final deviceInfo = DeviceInfoPlugin();
        final androidInfo = await deviceInfo.androidInfo;

        final brand = androidInfo.brand.toLowerCase().trim();
        final model = androidInfo.model.toLowerCase().trim();
        final hardware = androidInfo.hardware.toLowerCase().trim();
        final board = androidInfo.board.toLowerCase().trim();
        final product = androidInfo.product.toLowerCase().trim();
        final device = androidInfo.device.toLowerCase().trim();

        // 1. Google Chromecast & Google TV dongles
        // Specifically Chromecast with Google TV (4K 'sabrina', HD 'boreal')
        // and other low-tier Google TV streaming sticks that suffer GPU crashes
        // under persistent canvas particle redraws.
        final isGoogleDevice = brand == 'google' ||
            model.contains('chromecast') ||
            model.contains('google tv') ||
            hardware.contains('sabrina') ||
            board.contains('sabrina') ||
            hardware.contains('boreal') ||
            board.contains('boreal') ||
            product.contains('sabrina') ||
            product.contains('boreal') ||
            device.contains('sabrina') ||
            device.contains('boreal');

        if (isGoogleDevice) {
          _isLowPerformance = true;
          _detectionReason = 'Google streaming device detected (${androidInfo.model})';
          _hasEvaluated = true;
          return true;
        }

        // 2. Android OS low-RAM device flag (ActivityManager.isLowRamDevice)
        if (androidInfo.isLowRamDevice) {
          _isLowPerformance = true;
          _detectionReason = 'Low-RAM Android device (${androidInfo.model})';
          _hasEvaluated = true;
          return true;
        }

        // 3. Physical RAM <= 2GB on Android TV / Leanback devices
        final ram = androidInfo.physicalRamSize;
        if (ram > 0 && ram <= 2147483648 && PlatformDetection.isTV) {
          _isLowPerformance = true;
          _detectionReason =
              'Limited memory Android TV device (${(ram / (1024 * 1024)).round()} MB RAM)';
          _hasEvaluated = true;
          return true;
        }

        // 4. Low-end TV SoCs known to fail with continuous canvas repaints
        final platformHw = (PlatformDetection.deviceHardware ?? '').toLowerCase();
        final platformModel = (PlatformDetection.deviceModel ?? '').toLowerCase();
        if (hardware.contains('s905w') ||
            hardware.contains('s905y2') ||
            platformHw.contains('s905w') ||
            platformHw.contains('s905y2') ||
            platformModel.contains('mibox') ||
            platformModel.contains('mdz-')) {
          _isLowPerformance = true;
          _detectionReason = 'Entry-level TV hardware detected ($hardware)';
          _hasEvaluated = true;
          return true;
        }
      }
    } catch (e) {
      debugPrint('[HardwareCapability] Evaluation error: $e');
    }

    _hasEvaluated = true;
    return _isLowPerformance;
  }

  /// Checks device capabilities against user preferences. If low-performance
  /// hardware is detected and the user has not explicitly set a manual preference,
  /// silently disables background particle animations without showing intrusive modals.
  static Future<void> checkAndApplyOptimization(BuildContext context) async {
    if (_isCheckingOrShowingDialog) return;
    _isCheckingOrShowingDialog = true;

    try {
      if (!GetIt.instance.isRegistered<UserPreferences>()) {
        return;
      }

      final prefs = GetIt.instance<UserPreferences>();

      // If the user has manually changed the particle setting in settings, respect their choice.
      final manuallySet = prefs.get(UserPreferences.backgroundParticlesManuallySet);
      if (manuallySet) {
        return;
      }

      final isLow = await evaluate();
      if (!isLow) {
        return;
      }

      // Low performance hardware detected: silently disable background particles
      if (prefs.get(UserPreferences.backgroundParticlesEnabled)) {
        await prefs.set(UserPreferences.backgroundParticlesEnabled, false);
      }
    } catch (e) {
      debugPrint('[HardwareCapability] checkAndApplyOptimization error: $e');
    } finally {
      _isCheckingOrShowingDialog = false;
    }
  }
}
