import 'package:flutter/foundation.dart';
import 'package:server_core/server_core.dart';
import '../../models/taste_profile/taste_profile_models.dart';

/// Service responsible for discovering, safely normalizing, and aggregating genres
/// directly from the primary Jellyfin server's accessible libraries.
class TasteGenreService {
  final MediaServerClient _client;

  TasteGenreService(this._client);

  /// Discovers real genres occurring in the primary server's movie & series libraries,
  /// counts eligible items and user watched items, safely normalizes casing, and
  /// sorts by frequency and relevance.
  Future<List<ServerGenreInfo>> discoverServerGenres({
    required String userId,
    Set<String> selectedGenreKeys = const {},
    bool forceRefresh = false,
  }) async {
    try {
      // 1. Fetch library items with genres and user data to count occurrences
      final libraryItemsRes = await _client.itemsApi.getItems(
        recursive: true,
        includeItemTypes: const ['Movie', 'Series'],
        fields: 'Genres,UserData',
        limit: 1000,
      );

      final items = (libraryItemsRes['Items'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();

      final genreLibraryCounts = <String, int>{};
      final genreWatchedCounts = <String, int>{};
      final genreDisplayLabels = <String, String>{};

      for (final item in items) {
        final rawGenres = (item['Genres'] as List<dynamic>? ?? [])
            .map((g) => g.toString().trim())
            .where((g) => g.isNotEmpty);

        final userData = item['UserData'] as Map<String, dynamic>?;
        final isWatched = userData?['Played'] == true ||
            (userData?['PlayCount'] as num?)?.toInt() != null &&
                (userData!['PlayCount'] as num).toInt() > 0;

        for (final rawGenre in rawGenres) {
          final normalizedKey = normalizeGenreKey(rawGenre);
          if (normalizedKey.isEmpty) continue;

          // Preserve best display label (prefer capitalization)
          genreDisplayLabels.putIfAbsent(normalizedKey, () => rawGenre);

          genreLibraryCounts[normalizedKey] =
              (genreLibraryCounts[normalizedKey] ?? 0) + 1;

          if (isWatched) {
            genreWatchedCounts[normalizedKey] =
                (genreWatchedCounts[normalizedKey] ?? 0) + 1;
          }
        }
      }

      // If library search returned few or none, fallback to Genre items
      if (genreLibraryCounts.isEmpty) {
        try {
          final genresRes = await _client.itemsApi.getItems(
            includeItemTypes: const ['Genre'],
            recursive: true,
          );
          final genreItems = (genresRes['Items'] as List? ?? [])
              .whereType<Map<String, dynamic>>()
              .toList();

          for (final g in genreItems) {
            final name = g['Name']?.toString().trim() ?? '';
            if (name.isEmpty) continue;
            final key = normalizeGenreKey(name);
            genreDisplayLabels.putIfAbsent(key, () => name);
            genreLibraryCounts.putIfAbsent(key, () => 1);
          }
        } catch (e) {
          debugPrint('[TasteGenreService] Genre items fallback failed: $e');
        }
      }

      final genreList = <ServerGenreInfo>[];

      for (final entry in genreLibraryCounts.entries) {
        final key = entry.key;
        final count = entry.value;
        final isSelected = selectedGenreKeys.contains(key);
        // Exclude zero eligible titles and exclude documentary/cooking/non-entertainment genres unless currently selected
        if ((count > 0 && !isExcludedGenreKey(key)) || isSelected) {
          genreList.add(
            ServerGenreInfo(
              key: key,
              label: genreDisplayLabels[key] ?? key,
              libraryCount: count,
              watchedCount: genreWatchedCounts[key] ?? 0,
            ),
          );
        }
      }

      // Sort: 1) Number of eligible titles, 2) Watched count, 3) Alphabetical
      genreList.sort((a, b) {
        if (b.libraryCount != a.libraryCount) {
          return b.libraryCount.compareTo(a.libraryCount);
        }
        if (b.watchedCount != a.watchedCount) {
          return b.watchedCount.compareTo(a.watchedCount);
        }
        return a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });

      return genreList;
    } catch (e, st) {
      debugPrint('[TasteGenreService] Error discovering server genres: $e\n$st');
      return [];
    }
  }

  /// Safely normalizes genre name for lookup while retaining strict uniqueness.
  /// (e.g. " Sci-Fi " -> "sci-fi", "Science Fiction" stays "science fiction").
  static String normalizeGenreKey(String genre) {
    return genre.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }

  /// Whether a genre key represents non-entertainment (e.g. documentaries, cooking, earth/planets).
  static bool isExcludedGenreKey(String key) {
    final lower = key.toLowerCase().trim();
    const excluded = {
      'documentary',
      'documentaries',
      'nature',
      'science',
      'cook',
      'cooking',
      'food',
      'food & cooking',
      'cooking show',
      'cooking shows',
      'reality',
      'reality-tv',
      'special interest',
      'earth',
      'planets',
      'planet',
      'talk show',
      'talk-show',
      'news',
      'fitness',
      'instructional',
    };
    for (final e in excluded) {
      if (lower == e || lower.startsWith('$e ') || lower.endsWith(' $e') || lower.contains(e)) {
        return true;
      }
    }
    return false;
  }
}
