import 'dart:convert';

import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';

import '../models/iptv_models.dart';

/// One entry in the local "recently played IPTV" list.
///
/// Carries just enough to (a) render a Continue Watching card and (b) rebuild
/// the playable stream URL without another catalogue round-trip.
class IptvRecentItem {
  /// [IptvProgressType.movie] or [IptvProgressType.episode].
  final String type;

  /// Progress key: the movie content id, or the episode id for an episode.
  final String itemId;

  /// Label for the card (movie title, or the episode title).
  final String title;
  final String? poster;

  /// Movie stream id (`resolveVodStreamUrl` falls back to [itemId]).
  final int? streamId;
  final String? containerExtension;

  // Episode-only metadata.
  final String? seriesId;
  final String? seriesTitle;
  final int? seasonNumber;
  final int? episodeNumber;
  final String? episodeId;

  /// When this entry was last played locally (epoch seconds). Only used as a
  /// tiebreaker; the server `updatedAt` wins when progress is available.
  final int playedAt;

  const IptvRecentItem({
    required this.type,
    required this.itemId,
    required this.title,
    this.poster,
    this.streamId,
    this.containerExtension,
    this.seriesId,
    this.seriesTitle,
    this.seasonNumber,
    this.episodeNumber,
    this.episodeId,
    this.playedAt = 0,
  });

  bool get isEpisode => type == IptvProgressType.episode;

  /// One card per movie, and one card per *series* (not per episode), so a
  /// series only ever shows its latest episode.
  String get dedupeKey =>
      isEpisode && (seriesId?.isNotEmpty ?? false) ? 'series|$seriesId' : '$type|$itemId';

  /// `S1E4` for episodes, null otherwise.
  String? get episodeCode => (seasonNumber != null && episodeNumber != null)
      ? 'S${seasonNumber}E$episodeNumber'
      : null;

  /// Card heading — the series name for episodes, the movie title otherwise.
  String get displayTitle =>
      isEpisode && (seriesTitle?.isNotEmpty ?? false) ? seriesTitle! : title;

  /// Card subheading (`S1E4 · Episode name`), or null for movies.
  String? get displaySubtitle {
    if (!isEpisode) return null;
    final code = episodeCode;
    if (code == null) return title;
    return title.isEmpty ? code : '$code · $title';
  }

  IptvRecentItem copyWith({int? playedAt}) => IptvRecentItem(
        type: type,
        itemId: itemId,
        title: title,
        poster: poster,
        streamId: streamId,
        containerExtension: containerExtension,
        seriesId: seriesId,
        seriesTitle: seriesTitle,
        seasonNumber: seasonNumber,
        episodeNumber: episodeNumber,
        episodeId: episodeId,
        playedAt: playedAt ?? this.playedAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type,
        'itemId': itemId,
        'title': title,
        if (poster != null) 'poster': poster,
        if (streamId != null) 'streamId': streamId,
        if (containerExtension != null) 'containerExtension': containerExtension,
        if (seriesId != null) 'seriesId': seriesId,
        if (seriesTitle != null) 'seriesTitle': seriesTitle,
        if (seasonNumber != null) 'seasonNumber': seasonNumber,
        if (episodeNumber != null) 'episodeNumber': episodeNumber,
        if (episodeId != null) 'episodeId': episodeId,
        'playedAt': playedAt,
      };

  static IptvRecentItem? fromJson(Map<String, dynamic> json) {
    final type = json['type']?.toString() ?? '';
    final itemId = json['itemId']?.toString() ?? '';
    if (itemId.isEmpty ||
        (type != IptvProgressType.movie && type != IptvProgressType.episode)) {
      return null;
    }
    return IptvRecentItem(
      type: type,
      itemId: itemId,
      title: json['title']?.toString() ?? '',
      poster: json['poster']?.toString(),
      streamId: json['streamId'] is num ? (json['streamId'] as num).toInt() : null,
      containerExtension: json['containerExtension']?.toString(),
      seriesId: json['seriesId']?.toString(),
      seriesTitle: json['seriesTitle']?.toString(),
      seasonNumber:
          json['seasonNumber'] is num ? (json['seasonNumber'] as num).toInt() : null,
      episodeNumber:
          json['episodeNumber'] is num ? (json['episodeNumber'] as num).toInt() : null,
      episodeId: json['episodeId']?.toString(),
      playedAt: json['playedAt'] is num ? (json['playedAt'] as num).toInt() : 0,
    );
  }
}

/// Bounded local list of recently played IPTV movies/episodes.
///
/// The backend has no "list all in-progress items" endpoint — only a batch
/// lookup by id — so the client remembers *which* items to ask about. Stored as
/// a single JSON string in SharedPreferences (via [PreferenceStore]) and capped
/// at [maxEntries] so it stays tiny on entry-level TVs. All writes are
/// best-effort and never throw.
class IptvRecentStore {
  static const String storageKey = 'iptv_recently_played_v1';
  static const int maxEntries = 30;

  final PreferenceStore _store;

  IptvRecentStore([PreferenceStore? store])
      : _store = store ?? GetIt.instance<PreferenceStore>();

  /// Most-recent-first. Returns an empty list when nothing is stored or the
  /// stored blob is unreadable.
  List<IptvRecentItem> get items {
    try {
      final raw = _store.getString(storageKey);
      if (raw == null || raw.isEmpty) return const <IptvRecentItem>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <IptvRecentItem>[];
      final result = <IptvRecentItem>[];
      for (final entry in decoded) {
        if (entry is! Map) continue;
        final item = IptvRecentItem.fromJson(entry.cast<String, dynamic>());
        if (item != null) result.add(item);
        if (result.length >= maxEntries) break;
      }
      return result;
    } catch (_) {
      return const <IptvRecentItem>[];
    }
  }

  /// Moves [item] to the head of the list (replacing any previous entry for the
  /// same movie / series) and trims to [maxEntries].
  Future<void> touch(IptvRecentItem item) async {
    if (item.itemId.isEmpty) return;
    final stamped = item.copyWith(
      playedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    final next = <IptvRecentItem>[stamped];
    final key = stamped.dedupeKey;
    for (final existing in items) {
      if (existing.dedupeKey == key) continue;
      next.add(existing);
      if (next.length >= maxEntries) break;
    }
    await _write(next);
  }

  /// Drops the entry for [itemId] (used when its progress is cleared).
  Future<void> remove(String type, String itemId) async {
    final next = items
        .where((e) => !(e.type == type && e.itemId == itemId))
        .toList(growable: false);
    await _write(next);
  }

  Future<void> clear() async {
    try {
      await _store.remove(storageKey);
    } catch (_) {}
  }

  Future<void> _write(List<IptvRecentItem> entries) async {
    try {
      await _store.setString(
        storageKey,
        jsonEncode(entries.map((e) => e.toJson()).toList(growable: false)),
      );
    } catch (_) {}
  }
}
