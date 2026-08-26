import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:logger/logger.dart';

import '../../auth/store/voltix_session_store.dart';
import '../models/aggregated_item.dart';
import '../repositories/multi_server_repository.dart';

/// Single item entry in the Voltix Watch Registry.
class WatchRegistryEntry {
  final String contentKey;
  final String itemId;
  final String serverId;
  final String serverName;
  final String type; // 'Movie', 'Episode', 'Video', 'Audio'
  final String name;
  final String? seriesName;
  final String? seriesId;
  final int? seasonNumber;
  final int? episodeNumber;
  final int? year;
  final List<String> genres;
  final List<String> actors;
  final List<String> directors;
  final List<String> studios;
  final String? overview;
  final String? primaryImageTag;
  final String? primaryImageItemId;
  final List<String> backdropImageTags;
  final String? parentBackdropItemId;
  final int playbackPositionTicks;
  final int durationTicks;
  final double progressPercent;
  final bool isPlayed;
  final int playCount;
  final DateTime lastWatchedAt;

  const WatchRegistryEntry({
    required this.contentKey,
    required this.itemId,
    required this.serverId,
    required this.serverName,
    required this.type,
    required this.name,
    this.seriesName,
    this.seriesId,
    this.seasonNumber,
    this.episodeNumber,
    this.year,
    this.genres = const [],
    this.actors = const [],
    this.directors = const [],
    this.studios = const [],
    this.overview,
    this.primaryImageTag,
    this.primaryImageItemId,
    this.backdropImageTags = const [],
    this.parentBackdropItemId,
    this.playbackPositionTicks = 0,
    this.durationTicks = 0,
    this.progressPercent = 0.0,
    this.isPlayed = false,
    this.playCount = 0,
    required this.lastWatchedAt,
  });

  Map<String, dynamic> toJson() => {
        'contentKey': contentKey,
        'itemId': itemId,
        'serverId': serverId,
        'serverName': serverName,
        'type': type,
        'name': name,
        'seriesName': seriesName,
        'seriesId': seriesId,
        'seasonNumber': seasonNumber,
        'episodeNumber': episodeNumber,
        'year': year,
        'genres': genres,
        'actors': actors,
        'directors': directors,
        'studios': studios,
        'overview': overview,
        'primaryImageTag': primaryImageTag,
        'primaryImageItemId': primaryImageItemId,
        'backdropImageTags': backdropImageTags,
        'parentBackdropItemId': parentBackdropItemId,
        'playbackPositionTicks': playbackPositionTicks,
        'durationTicks': durationTicks,
        'progressPercent': progressPercent,
        'isPlayed': isPlayed,
        'playCount': playCount,
        'lastWatchedAt': lastWatchedAt.toIso8601String(),
      };

  factory WatchRegistryEntry.fromJson(Map<String, dynamic> json) {
    return WatchRegistryEntry(
      contentKey: json['contentKey'] as String? ?? '',
      itemId: json['itemId'] as String? ?? '',
      serverId: json['serverId'] as String? ?? '',
      serverName: json['serverName'] as String? ?? '',
      type: json['type'] as String? ?? 'Movie',
      name: json['name'] as String? ?? '',
      seriesName: json['seriesName'] as String?,
      seriesId: json['seriesId'] as String?,
      seasonNumber: json['seasonNumber'] as int?,
      episodeNumber: json['episodeNumber'] as int?,
      year: json['year'] as int?,
      genres: (json['genres'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      actors: (json['actors'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      directors:
          (json['directors'] as List?)?.map((e) => e.toString()).toList() ??
              const [],
      studios: (json['studios'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      overview: json['overview'] as String?,
      primaryImageTag: json['primaryImageTag'] as String?,
      primaryImageItemId: json['primaryImageItemId'] as String?,
      backdropImageTags: (json['backdropImageTags'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      parentBackdropItemId: json['parentBackdropItemId'] as String?,
      playbackPositionTicks: json['playbackPositionTicks'] as int? ?? 0,
      durationTicks: json['durationTicks'] as int? ?? 0,
      progressPercent: (json['progressPercent'] as num?)?.toDouble() ?? 0.0,
      isPlayed: json['isPlayed'] as bool? ?? false,
      playCount: json['playCount'] as int? ?? 0,
      lastWatchedAt: json['lastWatchedAt'] != null
          ? DateTime.tryParse(json['lastWatchedAt'].toString()) ??
              DateTime.now()
          : DateTime.now(),
    );
  }

  /// Converts this registry entry to an [AggregatedItem] with UserData populated.
  AggregatedItem toAggregatedItem() {
    final raw = <String, dynamic>{
      'Id': itemId,
      'Name': name,
      'Type': type,
      if (seriesName != null) 'SeriesName': seriesName,
      if (seasonNumber != null) 'ParentIndexNumber': seasonNumber,
      if (episodeNumber != null) 'IndexNumber': episodeNumber,
      if (year != null) 'ProductionYear': year,
      'Genres': genres,
      'Overview': overview,
      'RunTimeTicks': durationTicks,
      'PrimaryImageTag': primaryImageTag,
      if (primaryImageItemId != null) 'PrimaryImageItemId': primaryImageItemId,
      'ImageTags': {
        if (primaryImageTag != null) 'Primary': primaryImageTag,
      },
      'BackdropImageTags': backdropImageTags,
      if (parentBackdropItemId != null)
        'ParentBackdropItemId': parentBackdropItemId,
      'UserData': {
        'Played': isPlayed,
        'PlayCount': playCount,
        'PlaybackPositionTicks': playbackPositionTicks,
        'PlayedPercentage': progressPercent,
        'LastPlayedDate': lastWatchedAt.toIso8601String(),
        'IsFavorite': false,
      },
    };

    return AggregatedItem(
      id: itemId,
      serverId: serverId,
      rawData: raw,
      serverName: serverName,
    );
  }
}

/// Profile-Scoped Watch Registry Service.
///
/// Records watch progress, completions, and continue-watching state per Voltix User,
/// isolating shared streaming servers (Extra & 4K) from polluting other users' profiles.
class VoltixWatchRegistryService extends ChangeNotifier {
  final Logger _logger = Logger();
  static const String _prefKeyPrefix = 'pref_voltix_watch_registry_';

  Map<String, WatchRegistryEntry> _entries = {};
  String? _currentLoadedUsername;
  Timer? _debounceSaveTimer;

  VoltixWatchRegistryService() {
    _loadForCurrentUser();
  }

  String _resolveUsername() {
    try {
      final voltixStore = GetIt.instance<VoltixSessionStore>();
      final username = voltixStore.username ?? voltixStore.displayName;
      if (username != null && username.trim().isNotEmpty) {
        return username.trim().toLowerCase();
      }
    } catch (_) {}
    return 'default_user';
  }

  String _prefKey(String username) => '$_prefKeyPrefix$username';

  void _loadForCurrentUser() {
    final username = _resolveUsername();
    if (_currentLoadedUsername == username && _entries.isNotEmpty) return;
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
                  _entries[entry.key] =
                      WatchRegistryEntry.fromJson(entry.value as Map<String, dynamic>);
                }
              }
            }
          }
        }
      }
    } catch (e) {
      _logger.w('[WatchRegistry] Failed to load registry for @$username: $e');
    }
  }

  /// Computes a normalized key for cross-server matching.
  static String computeContentKey(AggregatedItem item) {
    final name = item.name.toLowerCase().trim();
    final year = item.productionYear?.toString() ?? '';
    if (item.type == 'Episode') {
      final series = (item.seriesName ?? '').toLowerCase().trim();
      final s = item.parentIndexNumber ?? 0;
      final e = item.indexNumber ?? 0;
      return 'ep_${series}_s${s}e${e}_$name';
    }
    return 'media_${item.type}_${name}_$year';
  }

  /// Records or updates playback progress for an item.
  Future<void> recordPlayback(
    AggregatedItem item,
    int positionTicks, {
    bool isStopped = false,
  }) async {
    _loadForCurrentUser();
    final key = computeContentKey(item);
    if (key.isEmpty) return;

    final durationTicks = item.runTimeTicks ?? 0;
    double progress = 0.0;
    if (durationTicks > 0 && positionTicks > 0) {
      progress = (positionTicks / durationTicks) * 100.0;
    }

    final isCompleted = item.isPlayed || progress >= 90.0;
    final existing = _entries[key];
    final playCount = isCompleted ? ((existing?.playCount ?? 0) + 1) : (existing?.playCount ?? 0);

    // Extract actors/directors from raw item metadata if available
    final rawData = item.rawData;
    final people = (rawData['People'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final actors = people
        .where((p) => p['Type'] == 'Actor')
        .map((p) => p['Name']?.toString() ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
    final directors = people
        .where((p) => p['Type'] == 'Director')
        .map((p) => p['Name']?.toString() ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
    final studios = (rawData['Studios'] as List?)
            ?.map((s) => (s is Map ? s['Name'] : s)?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .toList() ??
        [];

    final entry = WatchRegistryEntry(
      contentKey: key,
      itemId: item.id,
      serverId: item.serverId,
      serverName: _resolveServerName(item, existing),
      type: item.type ?? 'Movie',
      name: item.name,
      seriesName: item.seriesName,
      seriesId: item.seriesId ?? existing?.seriesId,
      seasonNumber: item.parentIndexNumber,
      episodeNumber: item.indexNumber,
      year: item.productionYear,
      genres: item.genres,
      actors: actors.isNotEmpty ? actors : (existing?.actors ?? const []),
      directors: directors.isNotEmpty ? directors : (existing?.directors ?? const []),
      studios: studios.isNotEmpty ? studios : (existing?.studios ?? const []),
      overview: item.overview,
      primaryImageTag: item.primaryImageTag ?? item.primaryImageTagField,
      primaryImageItemId: item.primaryImageItemId,
      backdropImageTags: item.backdropImageTags,
      parentBackdropItemId: item.parentBackdropItemId,
      playbackPositionTicks: isCompleted ? 0 : positionTicks,
      durationTicks: durationTicks,
      progressPercent: isCompleted ? 100.0 : progress,
      isPlayed: isCompleted || (existing?.isPlayed ?? false),
      playCount: playCount,
      lastWatchedAt: DateTime.now(),
    );

    _entries[key] = entry;
    _scheduleSave();
    notifyListeners();

    _logger.i(
      '[WatchRegistry] Recorded for @$_currentLoadedUsername: "${entry.name}" (${entry.serverName}) -> '
      'progress=${progress.toStringAsFixed(1)}%, completed=$isCompleted',
    );
  }

  /// Removes an item from in-progress/continue watching.
  Future<void> removeInProgress(AggregatedItem item) async {
    _loadForCurrentUser();
    final key = computeContentKey(item);
    if (_entries.containsKey(key)) {
      final existing = _entries[key]!;
      _entries[key] = WatchRegistryEntry(
        contentKey: existing.contentKey,
        itemId: existing.itemId,
        serverId: existing.serverId,
        serverName: existing.serverName,
        type: existing.type,
        name: existing.name,
        seriesName: existing.seriesName,
        seriesId: existing.seriesId,
        seasonNumber: existing.seasonNumber,
        episodeNumber: existing.episodeNumber,
        year: existing.year,
        genres: existing.genres,
        actors: existing.actors,
        directors: existing.directors,
        studios: existing.studios,
        overview: existing.overview,
        primaryImageTag: existing.primaryImageTag,
        primaryImageItemId: existing.primaryImageItemId,
        backdropImageTags: existing.backdropImageTags,
        parentBackdropItemId: existing.parentBackdropItemId,
        playbackPositionTicks: 0,
        durationTicks: existing.durationTicks,
        progressPercent: 0.0,
        isPlayed: existing.isPlayed,
        playCount: existing.playCount,
        lastWatchedAt: existing.lastWatchedAt,
      );
      _scheduleSave();
      notifyListeners();
    }
  }

  /// Returns items currently in progress for the logged-in user.
  List<AggregatedItem> getInProgressItems({String? serverNameFilter}) {
    _loadForCurrentUser();
    final list = _entries.values
        .where((e) =>
            !e.isPlayed &&
            e.playbackPositionTicks > 0 &&
            e.progressPercent > 1.0 &&
            e.progressPercent < 90.0)
        .toList();

    if (serverNameFilter != null && serverNameFilter.isNotEmpty) {
      list.retainWhere((e) =>
          e.serverName.toLowerCase().contains(serverNameFilter.toLowerCase()));
    }

    list.sort((a, b) => b.lastWatchedAt.compareTo(a.lastWatchedAt));
    return list.map((e) => e.toAggregatedItem()).toList();
  }

  /// Returns played items for the logged-in user (useful for recommendations and taste profiles).
  List<AggregatedItem> getPlayedItems({int limit = 20, String? itemType}) {
    _loadForCurrentUser();
    final list = _entries.values.where((e) => e.isPlayed).toList();

    if (itemType != null && itemType.isNotEmpty) {
      list.retainWhere((e) => e.type.toLowerCase() == itemType.toLowerCase());
    }

    list.sort((a, b) => b.lastWatchedAt.compareTo(a.lastWatchedAt));
    return list.take(limit).map((e) => e.toAggregatedItem()).toList();
  }

  /// Checks if an item is marked as played for the current Voltix user.
  bool isItemPlayed(AggregatedItem item) {
    _loadForCurrentUser();
    final key = computeContentKey(item);
    return _entries[key]?.isPlayed ?? false;
  }

  /// Returns the saved playback position ticks for the current Voltix user.
  int? getItemProgressTicks(AggregatedItem item) {
    _loadForCurrentUser();
    final key = computeContentKey(item);
    final entry = _entries[key];
    if (entry != null && !entry.isPlayed && entry.playbackPositionTicks > 0) {
      return entry.playbackPositionTicks;
    }
    return null;
  }

  /// Resolves the display name of the server an item was played from.
  ///
  /// Home-row items are parsed without a server name, so fall back to the
  /// logged-in server list. Correct attribution is what keeps shared
  /// (Extra / 4K) entries separable from Primary ones.
  String _resolveServerName(AggregatedItem item, WatchRegistryEntry? existing) {
    final direct = item.serverName;
    if (direct != null && direct.trim().isNotEmpty) return direct.trim();
    try {
      if (GetIt.instance.isRegistered<MultiServerRepository>()) {
        final resolved =
            GetIt.instance<MultiServerRepository>().serverNameForId(item.serverId);
        if (resolved != null && resolved.trim().isNotEmpty) return resolved.trim();
      }
    } catch (_) {}
    return existing?.serverName ?? '';
  }

  /// Latest watched episode per series for the current Voltix user.
  ///
  /// Used to build Next Up for shared servers from *this* user's history
  /// instead of the shared Jellyfin account's history. Only completed episodes
  /// qualify — anything still in progress belongs in Continue Watching.
  List<WatchRegistryEntry> latestCompletedEpisodePerSeries({
    String? serverNameFilter,
  }) {
    _loadForCurrentUser();
    final byService = <String, WatchRegistryEntry>{};

    for (final e in _entries.values) {
      if (e.type.toLowerCase() != 'episode') continue;
      if (!e.isPlayed && e.progressPercent < 90.0) continue;
      final seriesId = e.seriesId;
      if (seriesId == null || seriesId.isEmpty) continue;

      if (serverNameFilter != null && serverNameFilter.isNotEmpty) {
        if (!e.serverName.toLowerCase().contains(serverNameFilter.toLowerCase())) {
          continue;
        }
      }

      final key = '${e.serverId}_$seriesId';
      final current = byService[key];
      if (current == null || e.lastWatchedAt.isAfter(current.lastWatchedAt)) {
        byService[key] = e;
      }
    }

    final list = byService.values.toList()
      ..sort((a, b) => b.lastWatchedAt.compareTo(a.lastWatchedAt));
    return list;
  }

  void _scheduleSave() {
    _debounceSaveTimer?.cancel();
    _debounceSaveTimer = Timer(const Duration(milliseconds: 800), () async {
      await _persistLocal();
    });
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
      _logger.e('[WatchRegistry] Failed to save local registry for @$username: $e');
    }
  }

  /// Exports registry payload for cloud backup.
  Map<String, dynamic> exportRegistryData() {
    _loadForCurrentUser();
    final username = _currentLoadedUsername ?? _resolveUsername();
    return {
      'username': username,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'entries': _entries.map((k, v) => MapEntry(k, v.toJson())),
    };
  }

  /// Imports registry data from cloud sync.
  Future<void> importRegistryData(Map<String, dynamic> data) async {
    try {
      final entriesJson = data['entries'] as Map<String, dynamic>?;
      if (entriesJson != null) {
        for (final entry in entriesJson.entries) {
          if (entry.value is Map<String, dynamic>) {
            final parsed =
                WatchRegistryEntry.fromJson(entry.value as Map<String, dynamic>);
            final existing = _entries[entry.key];
            // Furthest / most recent watch wins
            if (existing == null ||
                parsed.lastWatchedAt.isAfter(existing.lastWatchedAt)) {
              _entries[entry.key] = parsed;
            }
          }
        }
        await _persistLocal();
        notifyListeners();
      }
    } catch (e) {
      _logger.w('[WatchRegistry] Import error: $e');
    }
  }
}
