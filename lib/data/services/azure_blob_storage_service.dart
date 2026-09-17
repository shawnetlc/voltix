import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:get_it/get_it.dart';
import 'package:logger/logger.dart';

import 'voltix_api_service.dart';

class AzureBlobStorageService {
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 20),
  ));
  final Logger _logger = Logger();

  static const String _envAccountName =
      String.fromEnvironment('AZURE_BLOB_ACCOUNT_NAME');
  static const String _envContainerName =
      String.fromEnvironment('AZURE_BLOB_CONTAINER_NAME');
  /// SAS for the settings container specifically.
  ///
  /// A SAS is scoped to one container, and this service writes to
  /// `voltix-user-settings` while the taste-profile client writes to
  /// `voltix-taste-profiles` -- so the two need separate tokens. This one
  /// covers both settings and watch history, which live in the same container
  /// under different path prefixes rather than in containers of their own.
  static const String _envSettingsSasToken =
      String.fromEnvironment('AZURE_BLOB_SETTINGS_SAS_TOKEN');

  /// Older single-token builds. Kept as a fallback so a build that only sets
  /// AZURE_BLOB_SAS_TOKEN behaves as it did before, rather than silently
  /// losing the direct path.
  static const String _envSasToken =
      String.fromEnvironment('AZURE_BLOB_SAS_TOKEN');
  static const String _envCustomEndpoint =
      String.fromEnvironment('AZURE_BLOB_CUSTOM_ENDPOINT');

  /// Base URL of the Voltix backend, honouring the test-server preference.
  ///
  /// Resolved through the registered service rather than
  /// VoltixApiService.defaultBaseUrl so that a developer with the test server
  /// selected does not silently write settings to production.
  String _voltixBaseUrl() {
    try {
      return GetIt.instance<VoltixApiService>().baseUrl;
    } catch (_) {
      return VoltixApiService.defaultBaseUrl;
    }
  }

  String get accountName {
    if (_envAccountName.isNotEmpty) return _envAccountName;
    try {
      final platEnv = Platform.environment['AZURE_BLOB_ACCOUNT_NAME'];
      if (platEnv != null && platEnv.isNotEmpty) return platEnv;
    } catch (_) {}
    return 'voltixstorage';
  }

  String get containerName {
    if (_envContainerName.isNotEmpty) return _envContainerName;
    try {
      final platEnv = Platform.environment['AZURE_BLOB_CONTAINER_NAME'];
      if (platEnv != null && platEnv.isNotEmpty) return platEnv;
    } catch (_) {}
    return 'voltix-user-settings';
  }

  /// The container-specific token first, then the legacy shared one.
  String get envSasToken {
    if (_envSettingsSasToken.isNotEmpty) return _envSettingsSasToken;
    if (_envSasToken.isNotEmpty) return _envSasToken;
    try {
      final platEnv = Platform.environment['AZURE_BLOB_SETTINGS_SAS_TOKEN'] ??
          Platform.environment['AZURE_BLOB_SAS_TOKEN'];
      if (platEnv != null && platEnv.isNotEmpty) return platEnv;
    } catch (_) {}
    return '';
  }

  String get accountUrl {
    if (_envCustomEndpoint.isNotEmpty) return _envCustomEndpoint;
    try {
      final platEnv = Platform.environment['AZURE_BLOB_CUSTOM_ENDPOINT'];
      if (platEnv != null && platEnv.isNotEmpty) return platEnv;
    } catch (_) {}
    return 'https://$accountName.blob.core.windows.net';
  }

  String _buildBlobUrl(String username, String? overrideSasToken) {
    final blobName = '${username.toLowerCase().trim()}_settings.json';
    final token = (overrideSasToken != null && overrideSasToken.isNotEmpty)
        ? overrideSasToken
        : envSasToken;
    final tokenQuery = token.isNotEmpty
        ? (token.startsWith('?') ? token : '?$token')
        : '';
    return '$accountUrl/$containerName/$blobName$tokenQuery';
  }

  /// Uploads per-user settings to Azure Blob Storage as a Block Blob
  /// (`<username>_settings.json`).
  Future<bool> uploadUserSettingsBlob({
    required String username,
    required Map<String, dynamic> settingsData,
    String? sasToken,
  }) async {
    final cleanUser = username.toLowerCase().trim();
    if (cleanUser.isEmpty) return false;
    final blobName = '${cleanUser}_settings.json';

    final payloadJson = jsonEncode({
      'username': cleanUser,
      'settings': settingsData,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    });

    _logger.i('[AzureBlob] Syncing settings for @$cleanUser');

    // 1. Production Voltix Sync Proxy endpoint
    try {
      final syncDio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 12),
        headers: {'Content-Type': 'application/json'},
      ));
      // Instance baseUrl, not the hardcoded production constant: with the
      // test-server preference on, saves were still being sent to production.
      final proxyUrl = '${_voltixBaseUrl()}/api/voltix/azure-sync';
      final response = await syncDio.post(
        proxyUrl,
        data: {
          'username': cleanUser,
          'blobName': blobName,
          'settings': settingsData,
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        },
      );
      final body = response.data;
      final reportedSuccess = body is Map ? body['success'] != false : true;
      if ((response.statusCode == 200 || response.statusCode == 201) &&
          reportedSuccess) {
        final store = body is Map ? body['store'] : null;
        _logger.i(
          '[AzureBlob] Sync server upload succeeded for @$cleanUser'
          '${store != null ? ' (stored in $store)' : ''}',
        );
        return true;
      }
      // The proxy used to answer 200 with {"success": false} when nothing had
      // actually been stored, and only the status code was checked - so a total
      // failure to save looked like a successful backup right up until restore.
      _logger.w(
        '[AzureBlob] Sync server reported failure for @$cleanUser: '
        '${body is Map ? (body['error'] ?? body['reason'] ?? body) : body}',
      );
    } catch (e) {
      _logger.w('[AzureBlob] Production proxy upload failed ($e), trying direct Azure blob...');
    }

    // 2. Direct Azure Blob Storage fallback
    try {
      final url = _buildBlobUrl(cleanUser, sasToken);
      final response = await _dio.put(
        url,
        data: payloadJson,
        options: Options(
          headers: {
            'x-ms-blob-type': 'BlockBlob',
            'Content-Type': 'application/json; charset=utf-8',
          },
        ),
      );
      return response.statusCode == 201 || response.statusCode == 200;
    } catch (e) {
      _logger.e('[AzureBlob] All Azure upload attempts failed', error: e);
      return false;
    }
  }

  /// Downloads per-user settings blob from Azure Blob Storage.
  Future<Map<String, dynamic>?> downloadUserSettingsBlob({
    required String username,
    String? sasToken,
  }) async {
    final cleanUser = username.toLowerCase().trim();
    if (cleanUser.isEmpty) return null;
    final blobName = '${cleanUser}_settings.json';

    _logger.i('[AzureBlob] Downloading settings blob for @$cleanUser');

    // 1. Production Voltix Sync Proxy endpoint
    try {
      final syncDio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 12),
      ));
      final proxyUrl = '${_voltixBaseUrl()}/api/voltix/azure-sync';
      final response = await syncDio.get(
        proxyUrl,
        queryParameters: {'username': cleanUser, 'blobName': blobName},
      );
      final data = response.data;
      if (data is Map) {
        if (data['settings'] is Map) {
          return Map<String, dynamic>.from(data['settings'] as Map);
        } else if (data['settings'] is String) {
          return jsonDecode(data['settings'] as String) as Map<String, dynamic>;
        }
        return Map<String, dynamic>.from(data);
      }
    } catch (e) {
      _logger.w('[AzureBlob] Production proxy download failed ($e), trying direct Azure blob...');
    }

    // 2. Direct Azure Blob Storage fallback
    try {
      final url = _buildBlobUrl(cleanUser, sasToken);
      final response = await _dio.get(url);
      final data = response.data;
      if (data is Map) {
        if (data['settings'] is Map) {
          return Map<String, dynamic>.from(data['settings'] as Map);
        } else if (data['settings'] is String) {
          return jsonDecode(data['settings'] as String) as Map<String, dynamic>;
        }
        return Map<String, dynamic>.from(data);
      } else if (data is String) {
        final decoded = jsonDecode(data);
        if (decoded is Map) {
          if (decoded['settings'] is Map) {
            return Map<String, dynamic>.from(decoded['settings'] as Map);
          }
          return Map<String, dynamic>.from(decoded);
        }
      }
    } catch (_) {}
    return null;
  }

  /// Deletes the user's settings blob.
  Future<bool> deleteUserSettingsBlob({
    required String username,
    String? sasToken,
  }) async {
    final cleanUser = username.toLowerCase().trim();
    if (cleanUser.isEmpty) return false;
    final blobName = '${cleanUser}_settings.json';

    _logger.i('[AzureBlob] Deleting settings blob for @$cleanUser');

    try {
      final syncDio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 12),
      ));
      final proxyUrl = '${_voltixBaseUrl()}/api/voltix/azure-sync';
      final response = await syncDio.delete(
        proxyUrl,
        queryParameters: {'username': cleanUser, 'blobName': blobName},
      );
      if (response.statusCode == 200 || response.statusCode == 204) {
        return true;
      }
    } catch (e) {
      _logger.w('[AzureBlob] Proxy settings delete failed ($e), trying direct...');
    }

    try {
      final url = _buildBlobUrl(cleanUser, sasToken);
      final response = await _dio.delete(url);
      return response.statusCode == 202 || response.statusCode == 200;
    } catch (e) {
      _logger.e('[AzureBlob] All settings delete attempts failed', error: e);
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // ── Watch Registry Blob (watch-history/<username>_watch_history.json)
  // ═══════════════════════════════════════════════════════════════════

  String _buildWatchRegistryBlobUrl(String username, String? overrideSasToken, {int? profileId}) {
    final cleanUser = username.toLowerCase().trim();
    final blobName = profileId != null 
        ? 'watch-history/${cleanUser}_profile${profileId}_watch_history.json'
        : 'watch-history/${cleanUser}_watch_history.json';
    final token = (overrideSasToken != null && overrideSasToken.isNotEmpty)
        ? overrideSasToken
        : envSasToken;
    final tokenQuery = token.isNotEmpty
        ? (token.startsWith('?') ? token : '?$token')
        : '';
    return '$accountUrl/$containerName/$blobName$tokenQuery';
  }

  /// Uploads the user's watch registry to a dedicated blob under
  /// `watch-history/<username>_watch_history.json`.
  Future<bool> uploadWatchRegistryBlob({
    required String username,
    required Map<String, dynamic> registryData,
    String? sasToken,
    int? profileId,
  }) async {
    final cleanUser = username.toLowerCase().trim();
    if (cleanUser.isEmpty) return false;
    final blobName = profileId != null 
        ? 'watch-history/${cleanUser}_profile${profileId}_watch_history.json'
        : 'watch-history/${cleanUser}_watch_history.json';

    final payloadJson = jsonEncode(registryData);
    _logger.i('[AzureBlob] Uploading watch registry for @$cleanUser');

    // 1. Production Voltix Sync Proxy endpoint
    try {
      final syncDio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 12),
        headers: {'Content-Type': 'application/json'},
      ));
      final proxyUrl = '${_voltixBaseUrl()}/api/voltix/azure-sync';
      final response = await syncDio.post(
        proxyUrl,
        data: {
          'username': cleanUser,
          'blobName': blobName,
          'settings': registryData,
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        },
      );
      final body = response.data;
      final reportedSuccess = body is Map ? body['success'] != false : true;
      if ((response.statusCode == 200 || response.statusCode == 201) &&
          reportedSuccess) {
        _logger.i('[AzureBlob] Watch registry upload succeeded for @$cleanUser');
        return true;
      }
    } catch (e) {
      _logger.w('[AzureBlob] Proxy watch registry upload failed ($e), trying direct...');
    }

    // 2. Direct Azure Blob Storage fallback
    try {
      final url = _buildWatchRegistryBlobUrl(cleanUser, sasToken, profileId: profileId);
      final response = await _dio.put(
        url,
        data: payloadJson,
        options: Options(
          headers: {
            'x-ms-blob-type': 'BlockBlob',
            'Content-Type': 'application/json; charset=utf-8',
          },
        ),
      );
      return response.statusCode == 201 || response.statusCode == 200;
    } catch (e) {
      _logger.e('[AzureBlob] All watch registry upload attempts failed', error: e);
      return false;
    }
  }

  /// Downloads the user's dedicated watch registry blob.
  Future<Map<String, dynamic>?> downloadWatchRegistryBlob({
    required String username,
    String? sasToken,
    int? profileId,
  }) async {
    final cleanUser = username.toLowerCase().trim();
    if (cleanUser.isEmpty) return null;
    final blobName = profileId != null 
        ? 'watch-history/${cleanUser}_profile${profileId}_watch_history.json'
        : 'watch-history/${cleanUser}_watch_history.json';

    _logger.i('[AzureBlob] Downloading watch registry for @$cleanUser');

    // 1. Production Voltix Sync Proxy endpoint
    try {
      final syncDio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 12),
      ));
      final proxyUrl = '${_voltixBaseUrl()}/api/voltix/azure-sync';
      final response = await syncDio.get(
        proxyUrl,
        queryParameters: {'username': cleanUser, 'blobName': blobName},
      );
      final data = response.data;
      if (data is Map) {
        if (data['settings'] is Map) {
          return Map<String, dynamic>.from(data['settings'] as Map);
        }
        return Map<String, dynamic>.from(data);
      }
    } catch (e) {
      _logger.w('[AzureBlob] Proxy watch registry download failed ($e), trying direct...');
    }

    // 2. Direct Azure Blob Storage fallback
    try {
      final url = _buildWatchRegistryBlobUrl(cleanUser, sasToken, profileId: profileId);
      final response = await _dio.get(url);
      if (response.statusCode == 200) {
        final decoded = response.data is String
            ? jsonDecode(response.data as String)
            : response.data;
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      }
    } catch (_) {}
    return null;
  }

  // ═══════════════════════════════════════════════════════════════════
  // ── Favorites Registry Blob (favorites/<username>_profile<profileId>_favorites.json)
  // ═══════════════════════════════════════════════════════════════════

  String _buildFavoritesRegistryBlobUrl(String username, int profileId, String? overrideSasToken) {
    final cleanUser = username.toLowerCase().trim();
    final blobName = 'favorites/${cleanUser}_profile${profileId}_favorites.json';
    final token = (overrideSasToken != null && overrideSasToken.isNotEmpty)
        ? overrideSasToken
        : envSasToken;
    final tokenQuery = token.isNotEmpty
        ? (token.startsWith('?') ? token : '?$token')
        : '';
    return '$accountUrl/$containerName/$blobName$tokenQuery';
  }

  Future<bool> uploadFavoritesRegistryBlob({
    required String username,
    required int profileId,
    required Map<String, dynamic> registryData,
    String? sasToken,
  }) async {
    final cleanUser = username.toLowerCase().trim();
    if (cleanUser.isEmpty) return false;
    final blobName = 'favorites/${cleanUser}_profile${profileId}_favorites.json';

    final payloadJson = jsonEncode(registryData);
    _logger.i('[AzureBlob] Uploading favorites registry for @$cleanUser profile $profileId');

    // 1. Production Voltix Sync Proxy endpoint
    try {
      final syncDio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 12),
        headers: {'Content-Type': 'application/json'},
      ));
      final proxyUrl = '${_voltixBaseUrl()}/api/voltix/azure-sync';
      final response = await syncDio.post(
        proxyUrl,
        data: {
          'username': cleanUser,
          'blobName': blobName,
          'settings': registryData,
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        },
      );
      final body = response.data;
      final reportedSuccess = body is Map ? body['success'] != false : true;
      if ((response.statusCode == 200 || response.statusCode == 201) &&
          reportedSuccess) {
        _logger.i('[AzureBlob] Favorites registry upload succeeded for @$cleanUser');
        return true;
      }
    } catch (e) {
      _logger.w('[AzureBlob] Proxy favorites registry upload failed ($e), trying direct...');
    }

    // 2. Direct Azure Blob Storage fallback
    try {
      final url = _buildFavoritesRegistryBlobUrl(cleanUser, profileId, sasToken);
      final response = await _dio.put(
        url,
        data: payloadJson,
        options: Options(
          headers: {
            'x-ms-blob-type': 'BlockBlob',
            'Content-Type': 'application/json; charset=utf-8',
          },
        ),
      );
      return response.statusCode == 201 || response.statusCode == 200;
    } catch (e) {
      _logger.e('[AzureBlob] All favorites registry upload attempts failed', error: e);
      return false;
    }
  }

  Future<Map<String, dynamic>?> downloadFavoritesRegistryBlob({
    required String username,
    required int profileId,
    String? sasToken,
  }) async {
    final cleanUser = username.toLowerCase().trim();
    if (cleanUser.isEmpty) return null;
    final blobName = 'favorites/${cleanUser}_profile${profileId}_favorites.json';

    _logger.i('[AzureBlob] Downloading favorites registry for @$cleanUser profile $profileId');

    // 1. Production Voltix Sync Proxy endpoint
    try {
      final syncDio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 12),
      ));
      final proxyUrl = '${_voltixBaseUrl()}/api/voltix/azure-sync';
      final response = await syncDio.get(
        proxyUrl,
        queryParameters: {'username': cleanUser, 'blobName': blobName},
      );
      final data = response.data;
      if (data is Map) {
        if (data['settings'] is Map) {
          return Map<String, dynamic>.from(data['settings'] as Map);
        }
        return Map<String, dynamic>.from(data);
      }
    } catch (e) {
      _logger.w('[AzureBlob] Proxy favorites registry download failed ($e), trying direct...');
    }

    // 2. Direct Azure Blob Storage fallback
    try {
      final url = _buildFavoritesRegistryBlobUrl(cleanUser, profileId, sasToken);
      final response = await _dio.get(url);
      if (response.statusCode == 200) {
        final decoded = response.data is String
            ? jsonDecode(response.data as String)
            : response.data;
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      }
    } catch (_) {}
    return null;
  }
}

