import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:uuid/uuid.dart';
import '../../../auth/store/voltix_session_store.dart';
import '../../models/taste_profile/taste_profile_models.dart';
import '../voltix_api_service.dart';
import 'azure_storage_client.dart';
import 'taste_server_context.dart';

/// Result of conflict detection between local and cloud profiles.
enum ConflictResolutionChoice { keepLocal, keepCloud, merge }

/// Secure client-side synchronization and recovery service for Azure Blob Storage.
///
/// Supports direct connection via `AZURE_STORAGE_CONNECTION_STRING` or SAS token into
/// the dedicated taste profile container (defaults to `voltix-taste-profiles`) as well
/// as secure HTTPS sync proxy.
class AzureTasteSyncService extends ChangeNotifier {
  final Dio _dio;
  final String _tenantId;
  final String? _syncEndpointUrl; // e.g. https://api.voltix.media/sync/taste
  final AzureStorageClient _storageClient;

  bool _isUploading = false;
  bool get isUploading => _isUploading;

  String? _lastSyncError;
  String? get lastSyncError => _lastSyncError;

  DateTime? _lastSuccessfulSyncUtc;
  DateTime? get lastSuccessfulSyncUtc => _lastSuccessfulSyncUtc;

  AzureStorageClient get storageClient => _storageClient;

  // In-memory mock cloud store when offline / test environment
  final Map<String, TasteProfile> _mockCloudStore = {};

  AzureTasteSyncService({
    Dio? dio,
    String tenantId = 'default-tenant',
    String? syncEndpointUrl,
    AzureStorageClient? storageClient,
  })  : _dio = dio ?? Dio(),
        _tenantId = tenantId,
        _syncEndpointUrl = syncEndpointUrl,
        _storageClient = storageClient ?? AzureStorageClient(dio: dio);

  String _voltixBaseUrl() {
    try {
      return GetIt.instance<VoltixApiService>().baseUrl;
    } catch (_) {
      return VoltixApiService.defaultBaseUrl;
    }
  }

  String? _resolveUsername([String? explicitUsername]) {
    if (explicitUsername != null && explicitUsername.trim().isNotEmpty) {
      return explicitUsername.trim().toLowerCase();
    }
    try {
      if (GetIt.instance.isRegistered<VoltixSessionStore>()) {
        final voltixStore = GetIt.instance<VoltixSessionStore>();
        final u = voltixStore.username ?? voltixStore.displayName;
        if (u != null && u.trim().isNotEmpty) {
          return u.trim().toLowerCase();
        }
      }
    } catch (_) {}
    return null;
  }

  /// Generates the cloud blob storage path for a taste profile.
  ///
  /// Prioritizes human-readable username mapping:
  ///   `profiles/<username>/taste-profile.json` (e.g. `profiles/voltixadmin/taste-profile.json`)
  /// Falls back to deterministic server+user sha256 hash if no username is available.
  String getBlobPath({
    required String serverId,
    required String userId,
    String? username,
    int? profileId,
  }) {
    final user = _resolveUsername(username);
    final profileSuffix = profileId != null ? '/profile-$profileId' : '';
    if (user != null && user.isNotEmpty) {
      return 'profiles/$user$profileSuffix/taste-profile.json';
    }
    final profileKey = TasteServerContext.computeProfileKey(serverId, userId, profileId);
    return 'profiles/$_tenantId/$profileKey/taste-profile.json';
  }

  /// Returns the legacy hash path for backward compatibility.
  String getLegacyBlobPath({
    required String serverId,
    required String userId,
  }) {
    final profileKey = TasteServerContext.computeProfileKey(serverId, userId);
    return 'profiles/$_tenantId/$profileKey/taste-profile.json';
  }

  /// Silently backs up the profile to Azure Blob Storage in the background.
  Future<bool> uploadProfileSilently({
    required TasteProfile profile,
    String? username,
    String? authToken,
    int? profileId,
  }) async {
    if (!profile.azureBackupEnabled) {
      debugPrint('[AzureTasteSyncService] Cloud backup is disabled by user');
      return false;
    }

    _isUploading = true;
    _lastSyncError = null;
    notifyListeners();

    final profileKey =
        TasteServerContext.computeProfileKey(profile.serverId, profile.userId, profileId);
    final blobPath = getBlobPath(
      serverId: profile.serverId,
      userId: profile.userId,
      username: username,
      profileId: profileId,
    );

    int attempt = 0;
    const maxAttempts = 3;

    while (attempt < maxAttempts) {
      attempt++;
      try {
        // 1. Primary: Direct Azure Storage Upload into allocated taste container
        if (_storageClient.isConfigured) {
          final directSuccess = await _storageClient.putBlockBlobJson(
            blobPath: blobPath,
            jsonData: profile.toJson(),
          );
          if (directSuccess) {
            _lastSuccessfulSyncUtc = DateTime.now().toUtc();
            _isUploading = false;
            notifyListeners();
            return true;
          }
        }

        // 2. Secondary: Explicit HTTPS sync proxy API call
        if (_syncEndpointUrl != null && _syncEndpointUrl.isNotEmpty) {
          final headers = <String, dynamic>{
            'Content-Type': 'application/json',
            if (authToken != null) 'Authorization': 'Bearer $authToken',
            'X-Profile-Key': profileKey,
            'X-Blob-Path': blobPath,
          };

          final response = await _dio.put<void>(
            '$_syncEndpointUrl/$profileKey',
            data: profile.toJson(),
            options: Options(headers: headers),
          );

          if (response.statusCode == 200 || response.statusCode == 201) {
            _lastSuccessfulSyncUtc = DateTime.now().toUtc();
            _isUploading = false;
            notifyListeners();
            return true;
          }
        }

        // 3. Tertiary: Voltix Sync Proxy Fallback
        try {
          final proxyUrl = '${_voltixBaseUrl()}/api/voltix/azure-sync';
          final response = await _dio.post<dynamic>(
            proxyUrl,
            data: {
              'username': profile.userId,
              'blobName': blobPath,
              'tasteProfile': profile.toJson(),
              'container': _storageClient.containerName,
              'updatedAt': DateTime.now().toUtc().toIso8601String(),
            },
            options: Options(
              headers: {'Content-Type': 'application/json'},
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 12),
            ),
          );
          final body = response.data;
          final reportedSuccess = body is Map ? body['success'] != false : true;
          if ((response.statusCode == 200 || response.statusCode == 201) &&
              reportedSuccess) {
            _lastSuccessfulSyncUtc = DateTime.now().toUtc();
            _isUploading = false;
            notifyListeners();
            return true;
          }
        } catch (_) {}

        if (!_storageClient.isConfigured &&
            (_syncEndpointUrl == null || _syncEndpointUrl.isEmpty)) {
          // In-memory / mock persistence for test environment
          _mockCloudStore[profileKey] = profile.copyWith(
            syncStatus: SyncStatus.synced,
            lastSyncedAtUtc: DateTime.now().toUtc(),
          );
          _lastSuccessfulSyncUtc = DateTime.now().toUtc();
          _isUploading = false;
          notifyListeners();
          return true;
        }

        throw StateError('All Azure upload routes failed for $blobPath');
      } catch (e) {
        if (attempt >= maxAttempts) {
          debugPrint('[AzureTasteSyncService] Upload failed after $attempt attempts: $e');
          _lastSyncError = e.toString();
          _isUploading = false;
          notifyListeners();
          return false;
        }
        await Future.delayed(Duration(milliseconds: 500 * (1 << attempt)));
      }
    }

    _isUploading = false;
    notifyListeners();
    return false;
  }

  /// Checks if a remote cloud backup exists for the specified server and user.
  Future<TasteProfile?> fetchRemoteBackup({
    required String serverId,
    required String userId,
    String? username,
    String? authToken,
    int? profileId,
  }) async {
    final userBlobPath = getBlobPath(
      serverId: serverId,
      userId: userId,
      username: username,
      profileId: profileId,
    );
    final legacyBlobPath = getLegacyBlobPath(serverId: serverId, userId: userId);
    final profileKey = TasteServerContext.computeProfileKey(serverId, userId, profileId);

    try {
      if (_storageClient.isConfigured) {
        // 1. Primary: Try username-based path
        var data = await _storageClient.getBlockBlobJson(blobPath: userBlobPath);
        // 2. Fallback: Check legacy hash path if different
        if (data == null && userBlobPath != legacyBlobPath) {
          data = await _storageClient.getBlockBlobJson(blobPath: legacyBlobPath);
        }
        if (data != null) {
          return TasteProfile.fromJson(data);
        }
      }

      if (_syncEndpointUrl != null && _syncEndpointUrl.isNotEmpty) {
        final headers = <String, dynamic>{
          if (authToken != null) 'Authorization': 'Bearer $authToken',
          'X-Profile-Key': profileKey,
          'X-Blob-Path': userBlobPath,
        };

        final response = await _dio.get<Map<String, dynamic>>(
          '$_syncEndpointUrl/$profileKey',
          options: Options(headers: headers),
        );

        if (response.statusCode == 200 && response.data != null) {
          return TasteProfile.fromJson(response.data!);
        }
        return null;
      } else {
        return _mockCloudStore[profileKey];
      }
    } catch (e) {
      debugPrint('[AzureTasteSyncService] Failed to query remote backup: $e');
      return null;
    }
  }

  /// Deletes or tombstones the remote profile backup from Azure.
  Future<bool> deleteRemoteBackup({
    required String serverId,
    required String userId,
    String? username,
    String? authToken,
    int? profileId,
  }) async {
    final userBlobPath = getBlobPath(
      serverId: serverId,
      userId: userId,
      username: username,
      profileId: profileId,
    );
    final legacyBlobPath = getLegacyBlobPath(serverId: serverId, userId: userId);
    final profileKey = TasteServerContext.computeProfileKey(serverId, userId, profileId);

    try {
      if (_storageClient.isConfigured) {
        await _storageClient.deleteBlockBlob(blobPath: userBlobPath);
        if (userBlobPath != legacyBlobPath) {
          await _storageClient.deleteBlockBlob(blobPath: legacyBlobPath);
        }
      }

      if (_syncEndpointUrl != null && _syncEndpointUrl.isNotEmpty) {
        final headers = <String, dynamic>{
          if (authToken != null) 'Authorization': 'Bearer $authToken',
          'X-Profile-Key': profileKey,
        };

        await _dio.delete<void>(
          '$_syncEndpointUrl/$profileKey',
          options: Options(headers: headers),
        );
      } else {
        _mockCloudStore.remove(profileKey);
      }
      return true;
    } catch (e) {
      debugPrint('[AzureTasteSyncService] Failed to delete remote backup: $e');
      return false;
    }
  }

  /// Detects if there is a conflict between the local profile and cloud backup.
  static bool hasConflict(TasteProfile local, TasteProfile remote) {
    if (local.profileRevision == remote.profileRevision) return false;
    // Conflict if both have different revisions and distinct update timestamps
    return local.profileRevision != remote.profileRevision &&
        local.updatedAtUtc != remote.updatedAtUtc;
  }

  /// Merges local and cloud profiles deterministically.
  static TasteProfile mergeProfiles(TasteProfile local, TasteProfile remote) {
    // 1. Merge explicit title ratings & names (local takes precedence if both set)
    final mergedTitles = Map<String, TasteRating>.from(remote.explicit.titleRatings)
      ..addAll(local.explicit.titleRatings);
    final mergedTitleNames = Map<String, String>.from(remote.explicit.titleNames)
      ..addAll(local.explicit.titleNames);

    // 2. Merge genre ratings (local takes precedence)
    final mergedGenres = Map<String, TasteRating>.from(remote.explicit.genreRatings)
      ..addAll(local.explicit.genreRatings);

    // 3. Union selected moods
    final mergedMoods = Set<MoodCategory>.from(remote.explicit.selectedMoods)
      ..addAll(local.explicit.selectedMoods);

    // 4. Union negative signals by ID
    final negMap = <String, NegativeSignal>{};
    for (final n in remote.negativeSignals) {
      negMap[n.id] = n;
    }
    for (final n in local.negativeSignals) {
      negMap[n.id] = n;
    }

    // 5. Union feedback signals by event ID
    final feedMap = <String, FeedbackSignal>{};
    for (final f in remote.feedbackSignals) {
      feedMap[f.eventId] = f;
    }
    for (final f in local.feedbackSignals) {
      feedMap[f.eventId] = f;
    }

    final now = DateTime.now().toUtc();

    return local.copyWith(
      profileRevision: const Uuid().v4(),
      profileVersion: (local.profileVersion > remote.profileVersion
              ? local.profileVersion
              : remote.profileVersion) +
          1,
      explicit: local.explicit.copyWith(
        titleRatings: mergedTitles,
        titleNames: mergedTitleNames,
        genreRatings: mergedGenres,
        selectedMoods: mergedMoods,
        completedAt: local.explicit.completedAt ?? remote.explicit.completedAt,
      ),
      negativeSignals: negMap.values.toList(),
      feedbackSignals: feedMap.values.toList(),
      updatedAtUtc: now,
      lastUpdated: now,
      syncStatus: SyncStatus.pendingUpload,
    );
  }
}
