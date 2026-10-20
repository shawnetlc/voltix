import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:logger/logger.dart';

import '../../auth/store/voltix_session_store.dart';
import '../models/aggregated_item.dart';

/// Single item entry in the Voltix Favorites Registry.
class FavoriteRegistryEntry {
  final String itemId;
  final String serverId;
  final String type; // 'Movie', 'Series', 'Episode', etc.
  final String name;
  final String? primaryImageTag;
  final DateTime addedAt;

  const FavoriteRegistryEntry({
    required this.itemId,
    required this.serverId,
    required this.type,
    required this.name,
    this.primaryImageTag,
    required this.addedAt,
  });

  Map<String, dynamic> toJson() => {
        'itemId': itemId,
        'serverId': serverId,
        'type': type,
        'name': name,
        'primaryImageTag': primaryImageTag,
        'addedAt': addedAt.toIso8601String(),
      };

  factory FavoriteRegistryEntry.fromJson(Map<String, dynamic> json) {
    return FavoriteRegistryEntry(
      itemId: json['itemId'] as String? ?? '',
      serverId: json['serverId'] as String? ?? '',
      type: json['type'] as String? ?? 'Movie',
      name: json['name'] as String? ?? '',
      primaryImageTag: json['primaryImageTag'] as String?,
      addedAt: json['addedAt'] != null
          ? DateTime.tryParse(json['addedAt'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}

/// Profile-Scoped Favorites Registry Service.
class VoltixFavoritesRegistryService extends ChangeNotifier {
  /// Ticks on every favourite add / remove so UserSettingsSyncService can
  /// upload the Voltix user's favourites immediately.
  static final ValueNotifier<int> syncNowTick = ValueNotifier<int>(0);

  final Logger _logger = Logger();
  static const String _prefKeyPrefix = 'pref_voltix_favorites_registry_';

  Map<String, FavoriteRegistryEntry> _entries = {};
  String? _currentLoadedUsername;

  VoltixFavoritesRegistryService() {
    _loadForCurrentUser();
  }

  String _resolveUsername() {
    try {
      final voltixStore = GetIt.instance<VoltixSessionStore>();
      final username = voltixStore.username ?? voltixStore.displayName;
      final profileId = voltixStore.activeProfileId;
      
      if (username != null && username.trim().isNotEmpty) {
        final baseUser = username.trim().toLowerCase();
        if (profileId != null) {
          return '${baseUser}_profile$profileId';
        }
        return baseUser;
      }
    } catch (_) {}
    return 'default_user';
  }

  String _prefKey(String username) => '$_prefKeyPrefix$username';

  bool get hasEntries {
    _loadForCurrentUser();
    return _entries.isNotEmpty;
  }

  void _loadForCurrentUser({bool forceReload = false}) {
    final username = _resolveUsername();
    if (!forceReload && _currentLoadedUsername == username) return;
    _currentLoadedUsername = username;
    _entries = {};

    try {
      if (GetIt.instance.isRegistered<PreferenceStore>()) {
        final prefStore = GetIt.instance<PreferenceStore>();
        final rawJson = prefStore.getString(_prefKey(username));
        if (rawJson != null && rawJson.isNotEmpty) {
          final decoded = jsonDecode(rawJson);
          if (decoded is Map<String, dynamic>) {
            final itemsMap = decoded['entries'] as Map<String, dynamic>?;
            if (itemsMap != null) {
              for (final entry in itemsMap.entries) {
                if (entry.value is Map<String, dynamic>) {
                  _entries[entry.key] = FavoriteRegistryEntry.fromJson(
                      entry.value as Map<String, dynamic>);
                }
              }
            }
          }
        }
      }
    } catch (e) {
      _logger.w('[FavoritesRegistry] Failed to load registry for @$username: $e');
    }
  }

  String _computeKey(String itemId, String serverId) {
    return '${serverId}_$itemId';
  }

  Future<void> addFavorite(AggregatedItem item) async {
    _loadForCurrentUser();
    final key = _computeKey(item.id, item.serverId);
    
    final entry = FavoriteRegistryEntry(
      itemId: item.id,
      serverId: item.serverId,
      type: item.type ?? 'Movie',
      name: item.name,
      primaryImageTag: item.primaryImageTag ?? item.primaryImageTagField,
      addedAt: DateTime.now(),
    );

    _entries[key] = entry;
    await _persistLocal();
    notifyListeners();
    syncNowTick.value++; // favourite changed: sync to the cloud now
  }

  Future<void> addMultipleFavorites(List<AggregatedItem> items) async {
    if (items.isEmpty) return;
    _loadForCurrentUser();
    for (final item in items) {
      final key = _computeKey(item.id, item.serverId);
      _entries[key] = FavoriteRegistryEntry(
        itemId: item.id,
        serverId: item.serverId,
        type: item.type ?? 'Movie',
        name: item.name,
        primaryImageTag: item.primaryImageTag ?? item.primaryImageTagField,
        addedAt: DateTime.now(),
      );
    }
    await _persistLocal();
    notifyListeners();
    syncNowTick.value++; // favourite changed: sync to the cloud now
  }

  Future<void> removeFavorite(AggregatedItem item) async {
    await removeFavoriteById(item.id, item.serverId);
  }

  Future<void> addFavoriteById(
    String itemId, 
    String serverId, {
    String name = 'Unknown', 
    String type = 'Movie', 
    String? imageTag,
  }) async {
    _loadForCurrentUser();
    final key = _computeKey(itemId, serverId);
    
    final entry = FavoriteRegistryEntry(
      itemId: itemId,
      serverId: serverId,
      type: type,
      name: name,
      primaryImageTag: imageTag,
      addedAt: DateTime.now(),
    );

    _entries[key] = entry;
    await _persistLocal();
    notifyListeners();
    syncNowTick.value++; // favourite changed: sync to the cloud now
  }

  Future<void> removeFavoriteById(String itemId, [String? serverId]) async {
    _loadForCurrentUser();
    if (serverId != null && serverId.isNotEmpty) {
      _entries.remove(_computeKey(itemId, serverId));
    }
    // Also remove by itemId across all entries to prevent leftover keys
    // when serverId was saved as baseUrl but removed with server.id (or vice versa).
    _entries.removeWhere((_, entry) => entry.itemId == itemId);
    await _persistLocal();
    notifyListeners();
    syncNowTick.value++; // favourite changed: sync to the cloud now
  }

  bool isFavorite(String itemId, [String? serverId]) {
    _loadForCurrentUser();
    if (serverId != null && serverId.isNotEmpty) {
      final key = _computeKey(itemId, serverId);
      if (_entries.containsKey(key)) return true;
    }
    // Also check by itemId directly because serverId may differ between baseUrl and server.id
    return _entries.values.any((e) => e.itemId == itemId);
  }

  bool isFavoriteByItem(AggregatedItem item) {
    return isFavorite(item.id, item.serverId);
  }

  List<String> getFavoriteItemIds({String? serverId}) {
    _loadForCurrentUser();
    if (serverId != null && serverId.isNotEmpty) {
      return _entries.values
          .where((e) => e.serverId == serverId)
          .map((e) => e.itemId)
          .toList();
    }
    return _entries.values.map((e) => e.itemId).toList();
  }

  /// Favorite item ids, most recently added first, de-duplicated.
  List<String> favoriteItemIdsByRecency({int? limit}) {
    _loadForCurrentUser();
    final sorted = _entries.values.toList()
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    final seen = <String>{};
    final out = <String>[];
    for (final e in sorted) {
      if (e.itemId.isEmpty || !seen.add(e.itemId)) continue;
      out.add(e.itemId);
      if (limit != null && out.length >= limit) break;
    }
    return out;
  }

  /// All favorite item ids, for quick membership checks.
  Set<String> favoriteItemIdSet() {
    _loadForCurrentUser();
    return _entries.values
        .map((e) => e.itemId)
        .where((id) => id.isNotEmpty)
        .toSet();
  }

  Future<void> _persistLocal() async {
    final username = _currentLoadedUsername ?? _resolveUsername();
    try {
      if (GetIt.instance.isRegistered<PreferenceStore>()) {
        final prefStore = GetIt.instance<PreferenceStore>();
        final payload = {
          'username': username,
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
          'entries': _entries.map((k, v) => MapEntry(k, v.toJson())),
        };
        await prefStore.setString(_prefKey(username), jsonEncode(payload));
      }
    } catch (e) {
      _logger.e(
          '[FavoritesRegistry] Failed to save local registry for @$username: $e');
    }
  }

  Map<String, dynamic> exportRegistryData() {
    _loadForCurrentUser();
    final username = _currentLoadedUsername ?? _resolveUsername();
    return {
      'username': username,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'entries': _entries.map((k, v) => MapEntry(k, v.toJson())),
    };
  }

  Future<void> importRegistryData(Map<String, dynamic> data) async {
    // Merge into the CURRENT user/profile's list (the profile may have been
    // picked since this registry was last touched).
    _loadForCurrentUser();
    try {
      final entriesJson = data['entries'] as Map<String, dynamic>?;
      if (entriesJson != null) {
        for (final entry in entriesJson.entries) {
          if (entry.value is Map<String, dynamic>) {
            final parsed = FavoriteRegistryEntry.fromJson(
                entry.value as Map<String, dynamic>);
            _entries[entry.key] = parsed;
          }
        }
        await _persistLocal();
        notifyListeners();
      }
    } catch (e) {
      _logger.w('[FavoritesRegistry] Import error: $e');
    }
  }
}
