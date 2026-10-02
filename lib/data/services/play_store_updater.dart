import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../util/app_distribution.dart';

/// What Google Play said about this install.
enum PlayUpdateCheck {
  /// Play has a newer build and has started (or offered) the update.
  updateStarted,

  /// Play confirms this is the newest build.
  upToDate,

  /// Not a Play install, or Play could not be reached - use the other checks.
  unavailable,
}

/// Asks Google Play directly whether an update exists, every launch.
///
/// Before this, Play installs only asked the Voltix server's appConfig (and
/// GitHub as a fallback), at most once a day. When those didn't know about the
/// new build the result was "could not check for updates", and opening the
/// store listing by hand didn't help either. Play's In-App Updates API is the
/// authoritative answer and runs Google's own update screen inside the app.
class PlayStoreUpdater {
  const PlayStoreUpdater._();

  static bool _inFlight = false;

  /// Worth asking Play at all: an Android build that Play owns, or whose
  /// installer is unknown (older TV boxes report none - Play will say).
  static Future<bool> _mayBePlayInstall() async {
    if (kIsWeb || !Platform.isAndroid) return false;
    if (AppDistribution.isAppGalleryBuild) return false;
    if (AppDistribution.isPlayStoreBuild) return true;
    try {
      final info = await PackageInfo.fromPlatform();
      final installer = info.installerStore?.toLowerCase().trim() ?? '';
      return installer.isEmpty || installer == 'com.android.vending';
    } catch (_) {
      return true;
    }
  }

  /// Checks Play and, if an update exists, starts it.
  ///
  /// [forced] uses Play's full-screen "immediate" flow (the app restarts on
  /// the new build); otherwise the update downloads in the background and is
  /// installed as soon as it has finished.
  static Future<PlayUpdateCheck> checkAndUpdate({bool forced = false}) async {
    if (_inFlight) return PlayUpdateCheck.unavailable;
    if (!await _mayBePlayInstall()) return PlayUpdateCheck.unavailable;
    _inFlight = true;
    try {
      final info = await InAppUpdate.checkForUpdate()
          .timeout(const Duration(seconds: 15));

      final availability = info.updateAvailability;
      if (availability == UpdateAvailability.developerTriggeredUpdateInProgress) {
        // An update Play already started (e.g. app was closed mid-install).
        await InAppUpdate.performImmediateUpdate();
        return PlayUpdateCheck.updateStarted;
      }
      if (availability != UpdateAvailability.updateAvailable) {
        return availability == UpdateAvailability.updateNotAvailable
            ? PlayUpdateCheck.upToDate
            : PlayUpdateCheck.unavailable;
      }

      final useImmediate =
          (forced && info.immediateUpdateAllowed) || !info.flexibleUpdateAllowed;
      if (useImmediate && info.immediateUpdateAllowed) {
        await InAppUpdate.performImmediateUpdate();
        return PlayUpdateCheck.updateStarted;
      }
      if (info.flexibleUpdateAllowed) {
        final result = await InAppUpdate.startFlexibleUpdate();
        if (result == AppUpdateResult.success) {
          // Downloaded: install now (Play restarts the app).
          await InAppUpdate.completeFlexibleUpdate();
        }
        return PlayUpdateCheck.updateStarted;
      }
      return PlayUpdateCheck.unavailable;
    } catch (e) {
      // ERROR_API_NOT_AVAILABLE (not installed from Play), no Play account,
      // timeout... - the caller falls back to the existing checks.
      debugPrint('[PlayStoreUpdater] Play update check unavailable: $e');
      return PlayUpdateCheck.unavailable;
    } finally {
      _inFlight = false;
    }
  }
}
