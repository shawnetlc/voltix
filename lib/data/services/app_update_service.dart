import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../../preference/user_preferences.dart';
import '../../util/app_distribution.dart';
import '../../util/platform_detection.dart';
import 'voltix_api_service.dart';

enum DesktopUpdateCheckStatus {
  updateAvailable,
  upToDate,
  checkFailed,
  unsupportedPlatform,
  disabledByPreference,
  rateLimited,
  alreadyNotified,
  noMatchingAsset,
}

class DesktopUpdateCheckResult {
  final DesktopUpdateCheckStatus status;
  final DesktopUpdateInfo? update;

  const DesktopUpdateCheckResult({
    required this.status,
    this.update,
  });
}

class DesktopUpdateInfo {
  final String version;
  final Uri downloadUri;
  final String assetName;
  final String releaseNotesUrl;
  final String releaseNotesBody;
  final bool forceUpdate;

  const DesktopUpdateInfo({
    required this.version,
    required this.downloadUri,
    required this.assetName,
    required this.releaseNotesUrl,
    this.releaseNotesBody = '',
    this.forceUpdate = false,
  });
}

class AppUpdateService {
  AppUpdateService(this._store, this._userPreferences);

  static const _latestReleaseHost = 'api.github.com';
  static const _latestReleasePath = '/repos/shawnetlc/voltix/releases/latest';
  static const _checkCooldown = Duration(hours: 24);

  static const _lastCheckMsKey = 'app_update_last_check_ms';
  static const _lastNotifiedVersionKey = 'app_update_last_notified_version';

  final PreferenceStore _store;
  final UserPreferences _userPreferences;

  Future<DesktopUpdateInfo?> checkForUpdateIfDue() async {
    final result = await _checkForUpdate(
      enforceCooldown: true,
      respectNotificationPreference: true,
      suppressIfAlreadyNotified: true,
    );
    return result.update;
  }

  Future<DesktopUpdateInfo?> checkForUpdateNow() async {
    final result = await checkForUpdateNowDetailed();
    return result.update;
  }

  Future<DesktopUpdateCheckResult> checkForUpdateNowDetailed() {
    return _checkForUpdate(
      enforceCooldown: false,
      respectNotificationPreference: false,
      suppressIfAlreadyNotified: false,
    );
  }

  /// Downloads [update] to a temporary file, yielding progress in [0.0, 1.0].
  /// Completes with the local file path when done.
  Stream<DownloadEvent> downloadUpdate(DesktopUpdateInfo update) async* {
    final dir = PlatformDetection.isAndroid
        ? await getExternalStorageDirectory() ?? await getTemporaryDirectory()
        : await getTemporaryDirectory();

    final fileName = update.assetName.isNotEmpty
        ? update.assetName
        : 'voltix_update${_extensionFor(update.downloadUri.path)}';
    final savePath = '${dir.path}/$fileName';

    final client = HttpClient()
      ..userAgent = 'VoltixUpdateChecker/1.0'
      ..connectionTimeout = const Duration(seconds: 20);

    try {
      final request = await client.getUrl(update.downloadUri);
      final response = await request.close().timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>().catchError((_) {});
        yield DownloadEvent.failed('HTTP ${response.statusCode}');
        return;
      }

      final contentLength = response.contentLength;
      int received = 0;
      final file = File(savePath);
      await file.parent.create(recursive: true);
      final raf = await file.open(mode: FileMode.write);
      try {
        await for (final chunk in response) {
          await raf.writeFrom(chunk);
          received += chunk.length;
          if (contentLength > 0) {
            yield DownloadEvent.progress(received / contentLength);
          } else {
            yield DownloadEvent.progress(-1);
          }
        }
      } finally {
        await raf.close();
      }
      yield DownloadEvent.done(savePath);
    } catch (e) {
      yield DownloadEvent.failed(e.toString());
    } finally {
      client.close(force: true);
    }
  }

  /// Fetches the Voltix server's app configuration which may include:
  /// - `latestVersion`: the newest version published to stores
  /// - `minimumVersion`: the minimum version the server will accept
  /// - `releaseNotes`: optional release notes for the latest version
  /// - `forceUpdate`: whether this update is mandatory
  Future<_VoltixAppConfig?> _fetchAppConfig() async {
    try {
      final apiService = VoltixApiService();

      final client = HttpClient()
        ..userAgent = 'VoltixUpdateChecker/1.0'
        ..connectionTimeout = const Duration(seconds: 5);

      final url = Uri.parse('${apiService.baseUrl}/api/trpc/appConfig');
      final request = await client.getUrl(url);
      final httpResponse = await request.close().timeout(const Duration(seconds: 5));

      if (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
        await httpResponse.drain<void>().catchError((_) {});
        client.close(force: true);
        return null;
      }

      final body = await httpResponse.transform(utf8.decoder).join();
      client.close(force: true);

      final decoded = jsonDecode(body);
      final result = decoded is Map ? decoded['result'] : null;
      final data = result is Map ? result['data'] : null;
      if (data is! Map) return null;

      return _VoltixAppConfig(
        latestVersion: data['latestVersion']?.toString(),
        minimumVersion: data['minimumVersion']?.toString(),
        releaseNotes: data['releaseNotes']?.toString(),
        forceUpdate: data['forceUpdate'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  /// Update check path for Play Store / AppGallery builds.
  ///
  /// Queries the Voltix server's appConfig endpoint for the latest published
  /// version instead of the GitHub releases API (which has no releases — they
  /// go straight to the store). If a newer version exists, produces an
  /// [updateAvailable] result whose [downloadUri] points at the store listing.
  Future<DesktopUpdateCheckResult> _checkForUpdateViaVoltixApi({
    required String currentVersion,
    required bool suppressIfAlreadyNotified,
  }) async {
    final config = await _fetchAppConfig();
    if (config == null) {
      return const DesktopUpdateCheckResult(
        status: DesktopUpdateCheckStatus.checkFailed,
      );
    }

    // Determine the latest version. The server may provide `latestVersion`
    // explicitly; if not, fall back to `minimumVersion` (which at least tells
    // us *some* newer version exists if it's higher than ours).
    final serverVersion = config.latestVersion ?? config.minimumVersion;
    if (serverVersion == null || serverVersion.isEmpty || serverVersion == '0.0.0') {
      return const DesktopUpdateCheckResult(
        status: DesktopUpdateCheckStatus.upToDate,
      );
    }

    if (!_isNewerVersion(serverVersion, currentVersion)) {
      return const DesktopUpdateCheckResult(
        status: DesktopUpdateCheckStatus.upToDate,
      );
    }

    // Is this a force update?
    final minVersion = config.minimumVersion;
    final isForced = config.forceUpdate ||
        (minVersion != null &&
            minVersion.isNotEmpty &&
            minVersion != '0.0.0' &&
            _isNewerVersion(minVersion, currentVersion));

    final lastNotified = _store.getString(_lastNotifiedVersionKey);
    if (suppressIfAlreadyNotified &&
        !isForced &&
        _normalizeVersion(lastNotified) == _normalizeVersion(serverVersion)) {
      return const DesktopUpdateCheckResult(
        status: DesktopUpdateCheckStatus.alreadyNotified,
      );
    }

    await _store.setString(_lastNotifiedVersionKey, serverVersion);

    // Build a store-listing URI — the dialog will show "Update via Play Store"
    // or "Update via AppGallery" and open this.
    String pkgName = 'cc.voltix.streaming';
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      if (packageInfo.packageName.trim().isNotEmpty) {
        pkgName = packageInfo.packageName.trim();
      }
    } catch (_) {}
    final storeUri = Uri.parse(
      'https://play.google.com/store/apps/details?id=$pkgName',
    );

    return DesktopUpdateCheckResult(
      status: DesktopUpdateCheckStatus.updateAvailable,
      update: DesktopUpdateInfo(
        version: serverVersion,
        downloadUri: storeUri,
        assetName: '',
        releaseNotesUrl: storeUri.toString(),
        releaseNotesBody: config.releaseNotes ?? '',
        forceUpdate: isForced,
      ),
    );
  }

  /// Checks the server's minimum_version config. Returns true if the server
  /// requires a higher version than [currentVersion].
  Future<bool> _isServerForceUpdate(String currentVersion) async {
    final config = await _fetchAppConfig();
    if (config == null) return false;
    final minVersion = config.minimumVersion;
    if (minVersion == null || minVersion.isEmpty || minVersion == '0.0.0') {
      return false;
    }
    return _isNewerVersion(minVersion, currentVersion);
  }

  String _extensionFor(String path) {
    final lower = path.toLowerCase();
    for (final ext in const ['.apk', '.dmg', '.exe', '.appimage', '.deb', '.rpm']) {
      if (lower.endsWith(ext)) return ext;
    }
    return '';
  }

  Future<DesktopUpdateCheckResult> _checkForUpdate({
    required bool enforceCooldown,
    required bool respectNotificationPreference,
    required bool suppressIfAlreadyNotified,
  }) async {
    if (!AppDistribution.supportsInAppUpdates) {
      return const DesktopUpdateCheckResult(
        status: DesktopUpdateCheckStatus.unsupportedPlatform,
      );
    }

    if (respectNotificationPreference) {
      final notificationsEnabled = _userPreferences.get(UserPreferences.updateNotificationsEnabled);
      if (!notificationsEnabled) {
        return const DesktopUpdateCheckResult(
          status: DesktopUpdateCheckStatus.disabledByPreference,
        );
      }
    }

    final now = DateTime.now().toUtc();
    final lastCheckMs = _store.getInt(_lastCheckMsKey);
    if (enforceCooldown && lastCheckMs != null && lastCheckMs > 0) {
      final lastCheckAt = DateTime.fromMillisecondsSinceEpoch(lastCheckMs, isUtc: true);
      if (now.difference(lastCheckAt) < _checkCooldown) {
        return const DesktopUpdateCheckResult(
          status: DesktopUpdateCheckStatus.rateLimited,
        );
      }
    }

    await _store.setInt(_lastCheckMsKey, now.millisecondsSinceEpoch);

    final currentVersion = await _currentAppVersion();

    // ── Store-managed builds: use the Voltix API as the version source ──
    // Play Store and AppGallery releases are not published on GitHub, so the
    // GitHub releases API returns 404. Instead, the Voltix server's appConfig
    // endpoint provides `latestVersion` (and `minimumVersion` for force
    // updates). This path produces a store-listing link, never an APK.
    if (AppDistribution.isManagedStoreBuild) {
      return _checkForUpdateViaVoltixApi(
        currentVersion: currentVersion,
        suppressIfAlreadyNotified: suppressIfAlreadyNotified,
      );
    }

    // ── Sideload / APK / desktop builds: use GitHub releases ──
    final release = await _fetchLatestRelease();
    if (release == null) {
      return const DesktopUpdateCheckResult(
        status: DesktopUpdateCheckStatus.checkFailed,
      );
    }

    if (!_isNewerVersion(release.version, currentVersion)) {
      return const DesktopUpdateCheckResult(
        status: DesktopUpdateCheckStatus.upToDate,
      );
    }

    _ReleaseAsset? selectedAsset;
    if (!AppDistribution.opensReleasesInBrowser) {
      selectedAsset = _selectAsset(release.assets);
      if (selectedAsset == null) {
        return const DesktopUpdateCheckResult(
          status: DesktopUpdateCheckStatus.noMatchingAsset,
        );
      }
    }

    final lastNotified = _store.getString(_lastNotifiedVersionKey);
    if (suppressIfAlreadyNotified &&
        !release.forceUpdate &&
        _normalizeVersion(lastNotified) == _normalizeVersion(release.version)) {
      return const DesktopUpdateCheckResult(
        status: DesktopUpdateCheckStatus.alreadyNotified,
      );
    }

    await _store.setString(_lastNotifiedVersionKey, release.version);

    return DesktopUpdateCheckResult(
      status: DesktopUpdateCheckStatus.updateAvailable,
      update: DesktopUpdateInfo(
        version: release.version,
        downloadUri: selectedAsset != null
            ? Uri.parse(selectedAsset.downloadUrl)
            : Uri.parse(release.releaseNotesUrl),
        assetName: selectedAsset?.name ?? '',
        releaseNotesUrl: release.releaseNotesUrl,
        releaseNotesBody: release.releaseNotesBody,
        forceUpdate: release.forceUpdate || await _isServerForceUpdate(currentVersion),
      ),
    );
  }

  Future<String> _currentAppVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final version = packageInfo.version.trim();
      if (version.isNotEmpty) {
        return version;
      }
    } catch (_) {}
    return '0.0.0';
  }

  Future<_LatestRelease?> _fetchLatestRelease() async {
    final client = HttpClient()
      ..userAgent = 'VoltixUpdateChecker/1.0'
      ..connectionTimeout = const Duration(seconds: 10);

    try {
      final request = await client.getUrl(Uri.https(_latestReleaseHost, _latestReleasePath));
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');

      final response = await request.close().timeout(const Duration(seconds: 10));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        return null;
      }

      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }

      final tagName = decoded['tag_name']?.toString();
      if (tagName == null || tagName.trim().isEmpty) {
        return null;
      }

      final htmlUrl = decoded['html_url']?.toString() ??
          'https://github.com/shawnetlc/voltix/releases/latest';

      final releaseBody = decoded['body']?.toString() ?? '';
      final isForceUpdate = releaseBody.contains('<!-- force_update -->');

      final assetsJson = decoded['assets'];
      final assets = <_ReleaseAsset>[];
      if (assetsJson is List) {
        for (final asset in assetsJson) {
          if (asset is! Map) {
            continue;
          }
          final name = asset['name']?.toString();
          final downloadUrl = asset['browser_download_url']?.toString();
          if (name == null || name.isEmpty || downloadUrl == null || downloadUrl.isEmpty) {
            continue;
          }
          assets.add(_ReleaseAsset(name: name, downloadUrl: downloadUrl));
        }
      }

      return _LatestRelease(
        version: tagName,
        assets: assets,
        releaseNotesUrl: htmlUrl,
        releaseNotesBody: releaseBody,
        forceUpdate: isForceUpdate,
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  _ReleaseAsset? _selectAsset(List<_ReleaseAsset> assets) {
    if (assets.isEmpty) return null;

    var channel = AppDistribution.channel;
    if (channel == DistributionChannel.unknown && Platform.isAndroid) {
      channel = PlatformDetection.isTV ? DistributionChannel.androidTvApk : DistributionChannel.apk;
    }

    switch (channel) {
      case DistributionChannel.apk:
        return _firstWhere(assets, '.apk', excludeSubstring: 'tv') ??
            _firstByExtension(assets, const ['.apk']);
      case DistributionChannel.androidTvApk:
        return _firstWhere(assets, '.apk', requireSubstring: 'tv') ??
            _firstByExtension(assets, const ['.apk']);
      case DistributionChannel.macosDmg:
        return _firstByExtension(assets, const ['.dmg']);
      case DistributionChannel.windows:
        return _firstByExtension(assets, const ['.exe']);
      default:
        return null;
    }
  }

  _ReleaseAsset? _firstWhere(
    List<_ReleaseAsset> assets,
    String extension, {
    String? requireSubstring,
    String? excludeSubstring,
  }) {
    for (final asset in assets) {
      final lower = asset.name.toLowerCase();
      if (!lower.endsWith(extension)) continue;
      if (requireSubstring != null && !lower.contains(requireSubstring)) continue;
      if (excludeSubstring != null && lower.contains(excludeSubstring)) continue;
      return asset;
    }
    return null;
  }

  _ReleaseAsset? _firstByExtension(List<_ReleaseAsset> assets, List<String> preferredExtensions) {
    for (final extension in preferredExtensions) {
      for (final asset in assets) {
        if (asset.name.toLowerCase().endsWith(extension)) {
          return asset;
        }
      }
    }
    return null;
  }

  bool _isNewerVersion(String candidate, String current) {
    final candidateParts = _parseSemverCore(candidate);
    final currentParts = _parseSemverCore(current);
    final maxLength = candidateParts.length > currentParts.length
        ? candidateParts.length
        : currentParts.length;

    for (var i = 0; i < maxLength; i++) {
      final left = i < candidateParts.length ? candidateParts[i] : 0;
      final right = i < currentParts.length ? currentParts[i] : 0;
      if (left > right) {
        return true;
      }
      if (left < right) {
        return false;
      }
    }
    return false;
  }

  List<int> _parseSemverCore(String raw) {
    final normalized = _normalizeVersion(raw);
    if (normalized.isEmpty) {
      return const [0, 0, 0];
    }

    final core = normalized.split('-').first.split('+').first;
    final pieces = core.split('.');
    final numbers = <int>[];
    for (final piece in pieces) {
      final value = int.tryParse(piece.replaceAll(RegExp(r'[^0-9]'), ''));
      numbers.add(value ?? 0);
    }
    while (numbers.length < 3) {
      numbers.add(0);
    }
    return numbers;
  }

  String _normalizeVersion(String? raw) {
    if (raw == null) {
      return '';
    }
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    if (trimmed.startsWith('v') || trimmed.startsWith('V')) {
      return trimmed.substring(1);
    }
    return trimmed;
  }
}

class _LatestRelease {
  final String version;
  final List<_ReleaseAsset> assets;
  final String releaseNotesUrl;
  final String releaseNotesBody;
  final bool forceUpdate;

  const _LatestRelease({
    required this.version,
    required this.assets,
    required this.releaseNotesUrl,
    this.releaseNotesBody = '',
    this.forceUpdate = false,
  });
}

sealed class DownloadEvent {
  const DownloadEvent();

  const factory DownloadEvent.progress(double fraction) = DownloadProgressEvent;
  const factory DownloadEvent.done(String filePath) = DownloadDoneEvent;
  const factory DownloadEvent.failed(String error) = DownloadFailedEvent;
}

final class DownloadProgressEvent extends DownloadEvent {
  final double fraction;
  const DownloadProgressEvent(this.fraction);
}

final class DownloadDoneEvent extends DownloadEvent {
  final String filePath;
  const DownloadDoneEvent(this.filePath);
}

final class DownloadFailedEvent extends DownloadEvent {
  final String error;
  const DownloadFailedEvent(this.error);
}

class _ReleaseAsset {
  final String name;
  final String downloadUrl;

  const _ReleaseAsset({required this.name, required this.downloadUrl});
}

class _VoltixAppConfig {
  final String? latestVersion;
  final String? minimumVersion;
  final String? releaseNotes;
  final bool forceUpdate;

  const _VoltixAppConfig({
    this.latestVersion,
    this.minimumVersion,
    this.releaseNotes,
    this.forceUpdate = false,
  });
}