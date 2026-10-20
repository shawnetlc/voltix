import 'package:flutter/painting.dart';

import '../preference/preference_constants.dart';
import '../preference/user_preferences.dart';
import 'hardware_capability.dart';
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
      prefs.get(UserPreferences.deviceTier) == tierPerformance &&
      !isConstrained;

  /// Low-memory / entry-level hardware (Skyworth-class TVs, Chromecast, any
  /// Android TV with <= 2 GB RAM). Set once at startup by
  /// [HardwareCapability.evaluate].
  ///
  /// On these devices the heavy options are refused at the point of use, not
  /// by rewriting the user's preferences - several of them (trailer preview,
  /// bitrate, resolution) roam between a user's devices through the settings
  /// backup, so a "Performance" or "Fibre" choice made on a strong box or phone
  /// used to arrive on a Skyworth TV and crash it.
  static bool get isConstrained =>
      HardwareCapability.isLowPerformance && !_performanceChosenHere;

  /// "Performance" picked in the setup wizard ON THIS DEVICE (the device tier
  /// is never synced between devices). An explicit choice overrides the
  /// automatic low-memory detection, so Performance / Fibre take effect.
  static bool _performanceChosenHere = false;

  /// Highest bitrate (Mbps) and resolution a constrained device will request.
  static const int constrainedMaxBitrateMbps = 200;

  /// Trailer previews start a second video decoder behind the home screen.
  static bool trailerPreviewAllowed(UserPreferences prefs) =>
      !isConstrained && prefs.get(UserPreferences.mediaBarTrailerPreview);

  /// The max bitrate playback should use on this device.
  static int? effectiveMaxBitrateMbps(UserPreferences prefs) {
    final chosen = int.tryParse(prefs.get(UserPreferences.maxBitrate));
    if (!isConstrained) return chosen;
    if (chosen == null || chosen <= 0 || chosen > constrainedMaxBitrateMbps) {
      return constrainedMaxBitrateMbps;
    }
    return chosen;
  }

  /// The max resolution playback should use on this device.
  static MaxVideoResolution effectiveMaxResolution(UserPreferences prefs) {
    final chosen = prefs.get(UserPreferences.maxVideoResolution);
    if (!isConstrained) return chosen;
    if (chosen == MaxVideoResolution.auto ||
        chosen == MaxVideoResolution.res2160p) {
      return MaxVideoResolution.res1080p;
    }
    return chosen;
  }

  /// Startup safety net for constrained devices: entry-level image budget and
  /// no animated particles (unless the user chose particles themselves).
  static Future<void> applyStartupLimits(UserPreferences prefs) async {
    await HardwareCapability.evaluate();
    _performanceChosenHere =
        prefs.get(UserPreferences.deviceTier) == tierPerformance;
    applyImageCache(prefs);
    if (!isConstrained) return;
    if (!prefs.get(UserPreferences.backgroundParticlesManuallySet) &&
        prefs.get(UserPreferences.backgroundParticlesEnabled)) {
      await prefs.set(UserPreferences.backgroundParticlesEnabled, false);
    }
  }

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
    _performanceChosenHere = tier == tierPerformance;
    // A constrained device never gets the performance extras, whatever was picked.
    final performance = tier == tierPerformance && !isConstrained;
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
    if (network == networkFibre && isConstrained) {
      // Fibre on an entry-level TV: more headroom than Wi-Fi, but no 4K - a
      // 2160p / 200 Mbps stream is more than these decoders and their memory
      // can hold.
      await prefs.set(UserPreferences.maxBitrate, '$constrainedMaxBitrateMbps');
      await prefs.set(
        UserPreferences.maxVideoResolution,
        MaxVideoResolution.res1080p,
      );
      return;
    }
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
