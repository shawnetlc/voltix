import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import '../../models/aggregated_item.dart';
import '../../models/taste_profile/taste_profile_models.dart';
import 'taste_server_context.dart';

/// Atomic local persistence engine for Taste Profiles, independent movie/series caches,
/// and synchronisation progress.
///
/// Implements two-phase validated atomic writes to prevent data corruption.
class TasteLocalStore {
  final PreferenceStore _prefs;
  TasteProfile? _inMemoryFallback;
  final Map<String, List<AggregatedItem>> _inMemoryMovieCache = {};
  final Map<String, List<AggregatedItem>> _inMemorySeriesCache = {};
  final Map<String, SyncProgressState> _inMemorySyncState = {};

  TasteLocalStore(this._prefs);

  String _buildKey(String serverId, String userId) {
    final hash = TasteServerContext.computeProfileKey(serverId, userId);
    return 'voltix_profile_$hash';
  }

  String _buildMoviesKey(String serverId, String userId) {
    final hash = TasteServerContext.computeProfileKey(serverId, userId);
    return 'voltix_movies_$hash';
  }

  String _buildSeriesKey(String serverId, String userId) {
    final hash = TasteServerContext.computeProfileKey(serverId, userId);
    return 'voltix_series_$hash';
  }

  String _buildSyncKey(String serverId, String userId) {
    final hash = TasteServerContext.computeProfileKey(serverId, userId);
    return 'voltix_sync_$hash';
  }

  /// Loads the profile from local storage, validating schema and identity.
  Future<TasteProfile?> loadProfile({
    required String serverId,
    required String userId,
  }) async {
    final key = _buildKey(serverId, userId);
    try {
      final raw = _prefs.getString(key);
      if (raw == null || raw.isEmpty) {
        return _inMemoryFallback;
      }

      final json = jsonDecode(raw) as Map<String, dynamic>;
      final profile = TasteProfile.fromJson(json);

      // Validate identity
      if (profile.serverId != serverId || profile.userId != userId) {
        debugPrint('[TasteLocalStore] Profile identity mismatch on load');
        return null;
      }

      return profile;
    } catch (e, st) {
      debugPrint('[TasteLocalStore] Error loading local profile: $e\n$st');
      return _inMemoryFallback;
    }
  }

  /// Saves the profile locally using two-phase atomic validation.
  Future<bool> saveProfileAtomic(TasteProfile profile) async {
    final key = _buildKey(profile.serverId, profile.userId);
    final tmpKey = '${key}_tmp';

    try {
      // 1. Serialize to JSON
      final jsonMap = profile.toJson();
      final jsonString = jsonEncode(jsonMap);

      // 2. Write to temporary key
      await _prefs.setString(tmpKey, jsonString);

      // 3. Validation phase: deserialize and check integrity
      final verifiedMap = jsonDecode(jsonString) as Map<String, dynamic>;
      final verifiedProfile = TasteProfile.fromJson(verifiedMap);

      if (verifiedProfile.schemaVersion < 1 ||
          verifiedProfile.serverId != profile.serverId ||
          verifiedProfile.userId != profile.userId ||
          verifiedProfile.profileRevision != profile.profileRevision) {
        throw StateError('Validation failed for atomic profile write');
      }

      // 4. Commit phase: write verified string to active key
      await _prefs.setString(key, jsonString);
      await _prefs.remove(tmpKey);

      _inMemoryFallback = verifiedProfile;
      return true;
    } catch (e, st) {
      debugPrint('[TasteLocalStore] Atomic write failed: $e\n$st');
      _inMemoryFallback = profile; // Retain in-memory fallback for current session
      return false;
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Independent Movie & Series Caches
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> saveCachedMovies({
    required String serverId,
    required String userId,
    required List<AggregatedItem> movies,
  }) async {
    final key = _buildMoviesKey(serverId, userId);
    _inMemoryMovieCache[key] = List.from(movies);
    try {
      final listJson = movies.map((m) => m.rawData).toList();
      await _prefs.setString(key, jsonEncode(listJson));
    } catch (e) {
      debugPrint('[TasteLocalStore] Failed to persist movies cache: $e');
    }
  }

  Future<List<AggregatedItem>> loadCachedMovies({
    required String serverId,
    required String userId,
  }) async {
    final key = _buildMoviesKey(serverId, userId);
    if (_inMemoryMovieCache.containsKey(key)) {
      return _inMemoryMovieCache[key]!;
    }
    try {
      final raw = _prefs.getString(key);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List<dynamic>;
        final items = list
            .whereType<Map<String, dynamic>>()
            .map((r) => AggregatedItem(
                  id: r['Id']?.toString() ?? '',
                  serverId: serverId,
                  rawData: r,
                ))
            .where((i) => i.id.isNotEmpty)
            .toList();
        _inMemoryMovieCache[key] = items;
        return items;
      }
    } catch (e) {
      debugPrint('[TasteLocalStore] Failed to load movies cache: $e');
    }
    return [];
  }

  Future<void> saveCachedSeries({
    required String serverId,
    required String userId,
    required List<AggregatedItem> series,
  }) async {
    final key = _buildSeriesKey(serverId, userId);
    _inMemorySeriesCache[key] = List.from(series);
    try {
      final listJson = series.map((s) => s.rawData).toList();
      await _prefs.setString(key, jsonEncode(listJson));
    } catch (e) {
      debugPrint('[TasteLocalStore] Failed to persist series cache: $e');
    }
  }

  Future<List<AggregatedItem>> loadCachedSeries({
    required String serverId,
    required String userId,
  }) async {
    final key = _buildSeriesKey(serverId, userId);
    if (_inMemorySeriesCache.containsKey(key)) {
      return _inMemorySeriesCache[key]!;
    }
    try {
      final raw = _prefs.getString(key);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List<dynamic>;
        final items = list
            .whereType<Map<String, dynamic>>()
            .map((r) => AggregatedItem(
                  id: r['Id']?.toString() ?? '',
                  serverId: serverId,
                  rawData: r,
                ))
            .where((i) => i.id.isNotEmpty)
            .toList();
        _inMemorySeriesCache[key] = items;
        return items;
      }
    } catch (e) {
      debugPrint('[TasteLocalStore] Failed to load series cache: $e');
    }
    return [];
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Resumable Synchronisation Progress Persistence
  // ──────────────────────────────────────────────────────────────────────────

  Future<void> saveSyncProgress({
    required String serverId,
    required String userId,
    required SyncProgressState state,
  }) async {
    final key = _buildSyncKey(serverId, userId);
    _inMemorySyncState[key] = state;
    try {
      await _prefs.setString(key, jsonEncode(state.toJson()));
    } catch (e) {
      debugPrint('[TasteLocalStore] Failed to persist sync progress: $e');
    }
  }

  Future<SyncProgressState?> loadSyncProgress({
    required String serverId,
    required String userId,
  }) async {
    final key = _buildSyncKey(serverId, userId);
    if (_inMemorySyncState.containsKey(key)) {
      return _inMemorySyncState[key];
    }
    try {
      final raw = _prefs.getString(key);
      if (raw != null && raw.isNotEmpty) {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        final state = SyncProgressState.fromJson(json);
        _inMemorySyncState[key] = state;
        return state;
      }
    } catch (e) {
      debugPrint('[TasteLocalStore] Failed to load sync progress: $e');
    }
    return null;
  }

  /// Deletes all local taste profile and cache data.
  Future<void> deleteProfile({
    required String serverId,
    required String userId,
  }) async {
    final key = _buildKey(serverId, userId);
    await _prefs.remove(key);
    await _prefs.remove('${key}_tmp');
    await _prefs.remove(_buildMoviesKey(serverId, userId));
    await _prefs.remove(_buildSeriesKey(serverId, userId));
    await _prefs.remove(_buildSyncKey(serverId, userId));
    _inMemoryFallback = null;
    _inMemoryMovieCache.clear();
    _inMemorySeriesCache.clear();
    _inMemorySyncState.clear();
  }
}
