import 'dart:io';

/// Build-time distribution channel. Set via
/// `--dart-define=DISTRIBUTION_CHANNEL=<value>` when building.
///
/// Supported values:
///   apk            : Android sideload APK (mobile)
///   aab            : Android App Bundle / Play Store
///   huawei         : Huawei AppGallery APK
///   android_tv_apk : Android TV sideload APK
///   android_tv_aab : Android TV App Bundle / Play Store
///   macos_dmg      : macOS DMG (GitHub direct download)
///   macos_pkg      : macOS App Store PKG
///   windows        : Windows installer EXE
///   linux          : Linux direct download (opens browser)
///   linux_aur      : Linux AUR package (no in-app updater)
///   ios_signed     : Signed IPA (App Store)
///   ios_unsigned   : Unsigned IPA (sideload)
enum DistributionChannel {
  apk,
  aab,
  huawei,
  androidTvApk,
  androidTvAab,
  macosDmg,
  macosPkg,
  windows,
  linux,
  linuxAur,
  iosSigned,
  iosUnsigned,
  unknown,
}

class AppDistribution {
  const AppDistribution._();

  static const _raw =
      String.fromEnvironment('DISTRIBUTION_CHANNEL');

  static DistributionChannel get channel {
    switch (_raw.toLowerCase().trim()) {
      case 'apk':
        return DistributionChannel.apk;
      case 'aab':
        return DistributionChannel.aab;
      case 'huawei':
        return DistributionChannel.huawei;
      case 'android_tv_apk':
        return DistributionChannel.androidTvApk;
      case 'android_tv_aab':
        return DistributionChannel.androidTvAab;
      case 'macos_dmg':
        return DistributionChannel.macosDmg;
      case 'macos_pkg':
        return DistributionChannel.macosPkg;
      case 'windows':
        return DistributionChannel.windows;
      case 'linux':
        return DistributionChannel.linux;
      case 'linux_aur':
        return DistributionChannel.linuxAur;
      case 'ios_signed':
        return DistributionChannel.iosSigned;
      case 'ios_unsigned':
        return DistributionChannel.iosUnsigned;
      default:
        return DistributionChannel.unknown;
    }
  }

  /// Whether this build supports in-app update *checking*.
  ///
  /// Play Store (AAB) builds are included: they may still surface an update
  /// notice, but only as a Play Store link — see [allowsApkSelfUpdate], which
  /// is what gates the APK download path.
  ///
  /// Returns false for managed distributions (AUR, PKG, signed IPA).
  ///
  /// This deliberately does NOT short-circuit on [Platform.isAndroid]. It used
  /// to `return true` for every Android build, which made the switch below dead
  /// code on Android — any channel the switch meant to exclude was silently
  /// re-enabled.
  static bool get supportsInAppUpdates {
    switch (channel) {
      case DistributionChannel.apk:
      case DistributionChannel.androidTvApk:
      case DistributionChannel.aab:
      case DistributionChannel.androidTvAab:
      case DistributionChannel.huawei:
      case DistributionChannel.macosDmg:
      case DistributionChannel.windows:
      case DistributionChannel.linux:
        return true;
      case DistributionChannel.unknown:
        // A build produced without --dart-define=DISTRIBUTION_CHANNEL. Treat
        // Android as a sideloaded APK (the historical default) so genuine
        // sideload users keep getting updates; everything else stays off.
        return Platform.isAndroid;
      default:
        return false;
    }
  }

  /// Whether this build may download and install an APK over itself.
  ///
  /// False for any store-managed build: Google Play and Huawei AppGallery both
  /// prohibit an app from updating itself outside the store. Doing so over a
  /// Play install is what produced the "update the APK" prompt on launch, and on
  /// AppGallery it additionally leaves the store's record of the installed
  /// version wrong.
  static bool get allowsApkSelfUpdate =>
      Platform.isAndroid && !isManagedStoreBuild;

  /// Whether this is a Play Store (AAB) build that should show Play Store
  /// update links instead of direct APK downloads.
  static bool get isPlayStoreBuild =>
      channel == DistributionChannel.aab ||
      channel == DistributionChannel.androidTvAab;

  /// Whether this build is distributed through Huawei AppGallery.
  ///
  /// AppGallery builds are ordinary APKs - no HMS dependency and no separate
  /// flavor - so the channel is the only thing distinguishing them from a
  /// sideload build. Without it they would inherit the sideload behaviour and
  /// self-install updates from GitHub, which AppGallery does not permit.
  static bool get isAppGalleryBuild =>
      channel == DistributionChannel.huawei;

  /// Whether an app store owns updates for this build.
  static bool get isManagedStoreBuild =>
      isPlayStoreBuild || isAppGalleryBuild;

  /// Whether downloading an update opens a browser instead of downloading
  /// the file in-app. True only for Linux direct builds.
  static bool get opensReleasesInBrowser =>
      channel == DistributionChannel.linux;
}
