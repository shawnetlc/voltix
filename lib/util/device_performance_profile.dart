import 'package:flutter/painting.dart';

import '../preference/preference_constants.dart';
import '../preference/user_preferences.dart';
import 'platform_detection.dart';

/// What the setup wizard's "Media box" and "Internet connection" answers
/// change. Kept in one place so the wizard, startup and settings agree.
///
/// Entry level is exactly today's behaviour: nothing about memory changes for
/// it. Only an explicit "Performance" answer raises the limits.
class DevicePerformanceProfile {
  const DevicePerformanceProfile._();

  static const tierEntry = 'entry';
  static const tierPerformance = 'performance';
  static const networkWifi = 'wifi';
  static const networkFibre = 'fibre';

  static bool isPerformance(UserPreferences prefs) =>
      prefs.get(UserPreferences.deviceTier) == tierPerformance;

  /// In-memory decoded-image budget. Called at startup (after preferences are
  /// available) and again when the wizard finishes.
  static void applyImageCache(UserPreferences prefs) {
    if (PlatformDetection.isWeb) return;
    final cache = PaintingBinding.instance.imageCache;
    final performance = isPerformance(prefs);
    if (PlatformDetection.isTV) {
      // Entry level: unchanged (20 images / 16 MB) - leaves headroom for the
      // video decoder on 1-1.5 GB boxes. Performance: 2 GB+ boxes.
      cache.maximumSize = performance ? 100 : 20;
      cache.maximumSizeBytes = (performance ? 96 : 16) << 20;
      return;
    }
    if (PlatformDetection.isMobile) {
      cache.maximumSize = performance ? 200 : 100;
      cache.maximumSizeBytes = (performance ? 192 : 120) << 20;
      return;
    }
    // Desktop already has a generous budget.
  }

  /// Settings the "Media box" answer controls.
  static Future<void> applyTier(UserPreferences prefs, String tier) async {
    await prefs.set(UserPreferences.deviceTier, tier);
    final performance = tier == tierPerformance;
    // Trailer previews on the home banner start a second video decoder -
    // fine on a capable box, a common cause of stutter on entry-level ones.
    await prefs.set(UserPreferences.mediaBarTrailerPreview, performance);
    // Animated background particles cost GPU time on every frame.
    await prefs.set(UserPreferences.backgroundParticlesEnabled, performance);
    applyImageCache(prefs);
  }

  /// Settings the "Internet connection" answer controls.
  static Future<void> applyNetwork(UserPreferences prefs, String network) async {
    await prefs.set(UserPreferences.networkType, network);
    if (network == networkFibre) {
      await prefs.set(UserPreferences.maxBitrate, '200');
      await prefs.set(
        UserPreferences.maxVideoResolution,
        MaxVideoResolution.res2160p,
      );
      // With bandwidth to spare, let the banner trailers play with sound.
      await prefs.set(UserPreferences.mediaBarTrailerAudio, true);
    }
    // Wi-Fi: transcoding and resolution limits are left exactly as they are.
  }
}
