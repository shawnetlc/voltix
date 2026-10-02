import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:server_core/server_core.dart';
import '../../models/taste_profile/taste_profile_models.dart';

/// Analyzes a user's Jellyfin watch history, favorites, and playback behavior
/// to derive an inferred taste profile without requiring server plugins.
class TasteHistoryAnalyzer {
  final MediaServerClient _client;

  TasteHistoryAnalyzer(this._client);

  /// Performs full watch-history ingestion and returns an [InferredTasteProfile].
  Future<InferredTasteProfile> analyzeHistory({
    required String userId,
    int recencyHalfLifeDays = 365,
  }) async {
    try {
      // 1. Fetch played items with essential metadata fields (lightweight to avoid proxy/upstream timeouts)
      final playedFuture = _client.itemsApi.getItems(
        filters: const ['IsPlayed'],
        recursive: true,
        includeItemTypes: const ['Movie', 'Series', 'Episode'],
        fields: 'Genres,People,UserData,PremiereDate,ProductionYear,RunTimeTicks,SeriesId',
        sortBy: 'DatePlayed',
        sortOrder: 'Descending',
        limit: 50,
      ).timeout(const Duration(seconds: 30));

      // 2. Fetch favorites
      final favFuture = _client.itemsApi.getItems(
        isFavorite: true,
        recursive: true,
        includeItemTypes: const ['Movie', 'Series'],
        fields: 'Genres,People,ProductionYear,UserData',
        limit: 50,
      ).timeout(const Duration(seconds: 30));

      // 3. Fetch in-progress / resume items (useful for detecting early abandonment vs active watch)
      final resumeFuture = _client.itemsApi.getResumeItems(
        fields: 'Genres,People,UserData',
        limit: 20,
      ).timeout(const Duration(seconds: 30));

      final results = await Future.wait([
        playedFuture.catchError((_) => <String, dynamic>{'Items': []}),
        favFuture.catchError((_) => <String, dynamic>{'Items': []}),
        resumeFuture.catchError((_) => <String, dynamic>{'Items': []}),
      ]);

      final playedResponse = results[0];
      final favResponse = results[1];
      final resumeResponse = results[2];

      final playedItems = (playedResponse['Items'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();
      final favItems = (favResponse['Items'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();
      final resumeItems = (resumeResponse['Items'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();

      return computeInferredProfile(
        playedItems: playedItems,
        favoriteItems: favItems,
        resumeItems: resumeItems,
        halfLifeDays: recencyHalfLifeDays,
      );
    } catch (e, st) {
      debugPrint('[TasteHistoryAnalyzer] Error analyzing watch history: $e\n$st');
      return InferredTasteProfile();
    }
  }

  /// Pure computation for profile generation (easily unit-testable).
  static InferredTasteProfile computeInferredProfile({
    required List<Map<String, dynamic>> playedItems,
    required List<Map<String, dynamic>> favoriteItems,
    required List<Map<String, dynamic>> resumeItems,
    int halfLifeDays = 365,
  }) {
    final now = DateTime.now();
    final rawGenreScores = <String, double>{};
    final rawActorScores = <String, double>{};
    final rawDirectorScores = <String, double>{};
    final rawStudioScores = <String, double>{};
    final rawEraScores = <String, double>{};
    final rawMoodScores = <String, double>{};
    final negativeGenres = <String>{};
    final negativePeople = <String>{};

    int totalPlays = 0;
    int rewatchCount = 0;
    final seriesEpisodeDates = <String, List<DateTime>>{};

    // Helper for recency decay: weight = 0.5 ^ (daysAgo / halfLifeDays)
    double recencyMultiplier(DateTime? playedDate) {
      if (playedDate == null) return 0.65;
      final daysAgo = math.max(0, now.difference(playedDate).inDays);
      return math.pow(0.5, daysAgo / halfLifeDays).toDouble();
    }

    // Process played items
    for (final item in playedItems) {
      totalPlays++;
      final userData = item['UserData'] as Map<String, dynamic>? ?? {};
      final playCount = (userData['PlayCount'] as num?)?.toInt() ?? 1;
      if (playCount > 1) {
        rewatchCount += (playCount - 1);
      }

      final playedPercent =
          ((userData['PlayedPercentage'] as num?)?.toDouble() ?? 100.0) / 100.0;
      final lastPlayedStr = userData['LastPlayedDate'] as String?;
      final lastPlayed =
          lastPlayedStr != null ? DateTime.tryParse(lastPlayedStr) : null;
      final decay = recencyMultiplier(lastPlayed);
      final isFav = userData['IsFavorite'] == true;
      final favBonus = isFav ? 1.5 : 1.0;
      final rewatchBonus = 1.0 + (math.min(playCount - 1, 4) * 0.25);

      // Track series binge intervals
      final seriesId = item['SeriesId']?.toString();
      if (seriesId != null && lastPlayed != null) {
        seriesEpisodeDates.putIfAbsent(seriesId, () => []).add(lastPlayed);
      }

      // Abandonment check: if stopped < 25% and not marked played
      final isAbandoned = playedPercent < 0.25 && userData['Played'] != true;
      final itemWeight = isAbandoned
          ? -0.5 * decay
          : (playedPercent * decay * favBonus * rewatchBonus);

      // 1. Genres
      final genres = (item['Genres'] as List<dynamic>? ?? [])
          .map((g) => g.toString().trim())
          .where((g) => g.isNotEmpty);
      for (final genre in genres) {
        rawGenreScores[genre] = (rawGenreScores[genre] ?? 0.0) + itemWeight;
        if (isAbandoned) {
          negativeGenres.add(genre);
        }
      }

      // 2. Cast & Directors
      final people = item['People'] as List<dynamic>? ?? [];
      for (final p in people) {
        if (p is! Map) continue;
        final name = p['Name']?.toString().trim();
        if (name == null || name.isEmpty) continue;
        final type = p['Type']?.toString().toLowerCase() ?? '';

        if (type == 'actor') {
          rawActorScores[name] = (rawActorScores[name] ?? 0.0) + itemWeight;
        } else if (type == 'director') {
          rawDirectorScores[name] =
              (rawDirectorScores[name] ?? 0.0) + itemWeight;
          if (isAbandoned) {
            negativePeople.add(name);
          }
        }
      }

      // 3. Studios
      final studios = item['Studios'] as List<dynamic>? ?? [];
      for (final s in studios) {
        final name = s is Map ? s['Name']?.toString().trim() : s?.toString().trim();
        if (name == null || name.isEmpty) continue;
        rawStudioScores[name] = (rawStudioScores[name] ?? 0.0) + itemWeight;
      }

      // 4. Era
      final year = (item['ProductionYear'] as num?)?.toInt();
      if (year != null && year > 1900 && itemWeight > 0) {
        final eraKey = _resolveEra(year);
        rawEraScores[eraKey] = (rawEraScores[eraKey] ?? 0.0) + itemWeight;
      }

      // 5. Moods from genres & tags
      if (itemWeight > 0) {
        final moods = _inferMoodsFromItem(item);
        for (final mood in moods) {
          rawMoodScores[mood.name] =
              (rawMoodScores[mood.name] ?? 0.0) + itemWeight;
        }
      }
    }

    // Process explicit favorites as positive baseline
    for (final item in favoriteItems) {
      final genres = (item['Genres'] as List<dynamic>? ?? [])
          .map((g) => g.toString().trim())
          .where((g) => g.isNotEmpty);
      for (final genre in genres) {
        rawGenreScores[genre] = (rawGenreScores[genre] ?? 0.0) + 1.5;
      }
      final people = item['People'] as List<dynamic>? ?? [];
      for (final p in people) {
        if (p is! Map) continue;
        final name = p['Name']?.toString().trim();
        if (name == null || name.isEmpty) continue;
        final type = p['Type']?.toString().toLowerCase() ?? '';
        if (type == 'actor') {
          rawActorScores[name] = (rawActorScores[name] ?? 0.0) + 1.5;
        } else if (type == 'director') {
          rawDirectorScores[name] = (rawDirectorScores[name] ?? 0.0) + 1.5;
        }
      }
    }

    // Compute Binge Metric: fraction of series with episodes watched < 48 hours apart
    double bingeScore = 0.5;
    if (seriesEpisodeDates.isNotEmpty) {
      int rapidSeriesCount = 0;
      for (final dates in seriesEpisodeDates.values) {
        if (dates.length >= 3) {
          dates.sort();
          bool isRapid = false;
          for (int i = 0; i < dates.length - 1; i++) {
            if (dates[i + 1].difference(dates[i]).inHours <= 48) {
              isRapid = true;
              break;
            }
          }
          if (isRapid) rapidSeriesCount++;
        }
      }
      bingeScore = (rapidSeriesCount / seriesEpisodeDates.length).clamp(0.0, 1.0);
    }

    // Compute Rewatch score
    final rewatchScore = totalPlays > 0
        ? (rewatchCount / totalPlays).clamp(0.0, 1.0)
        : 0.0;

    return InferredTasteProfile(
      genreAffinities: _normalizeMap(rawGenreScores),
      actorAffinities: _normalizeMap(rawActorScores, maxEntries: 40),
      directorAffinities: _normalizeMap(rawDirectorScores, maxEntries: 20),
      studioAffinities: _normalizeMap(rawStudioScores, maxEntries: 20),
      eraAffinities: _normalizeMap(rawEraScores),
      moodAffinities: _normalizeMap(rawMoodScores),
      bingeScore: bingeScore,
      rewatchScore: rewatchScore,
      negativeGenreSignals: negativeGenres,
      negativePeopleSignals: negativePeople,
      computedAt: now,
    );
  }

  static String _resolveEra(int year) {
    if (year < 1980) return 'classic';
    if (year < 2000) return 'eighties_nineties';
    if (year < 2015) return 'two_thousands';
    return 'modern';
  }

  static Set<MoodCategory> _inferMoodsFromItem(Map<String, dynamic> item) {
    final result = <MoodCategory>{};
    final genres = (item['Genres'] as List<dynamic>? ?? [])
        .map((g) => g.toString().toLowerCase())
        .toSet();
    final tags = (item['Tags'] as List<dynamic>? ?? [])
        .map((t) => t.toString().toLowerCase())
        .toSet();
    final overview = (item['Overview'] as String? ?? '').toLowerCase();

    if (genres.contains('action') ||
        genres.contains('thriller') ||
        tags.contains('suspense') ||
        overview.contains('chase') ||
        overview.contains('danger')) {
      result.add(MoodCategory.edgeOfYourSeat);
    }
    if (genres.contains('comedy') ||
        genres.contains('family') ||
        genres.contains('animation') ||
        tags.contains('feel-good')) {
      result.add(MoodCategory.feelGood);
    }
    if (genres.contains('comedy')) {
      result.add(MoodCategory.funny);
    }
    if (genres.contains('horror') ||
        tags.contains('scary') ||
        tags.contains('creepy') ||
        overview.contains('demon') ||
        overview.contains('ghost')) {
      result.add(MoodCategory.scary);
    }
    if (genres.contains('mystery') ||
        genres.contains('crime') ||
        tags.contains('detective') ||
        tags.contains('twist')) {
      result.add(MoodCategory.mindBending);
    }
    if (genres.contains('documentary') ||
        genres.contains('drama') ||
        tags.contains('philosophical')) {
      result.add(MoodCategory.thoughtProvoking);
    }
    if (genres.contains('adventure') ||
        genres.contains('fantasy') ||
        genres.contains('science fiction') ||
        genres.contains('sci-fi') ||
        tags.contains('epic')) {
      result.add(MoodCategory.epic);
    }
    if (genres.contains('romance') || tags.contains('love')) {
      result.add(MoodCategory.romantic);
    }

    if (result.isEmpty) {
      result.add(MoodCategory.feelGood);
    }
    return result;
  }

  /// Normalizes map values to 0.0 - 1.0 based on maximum score, pruning negatives.
  static Map<String, double> _normalizeMap(
    Map<String, double> source, {
    int maxEntries = 50,
  }) {
    if (source.isEmpty) return {};
    final positive = <String, double>{};
    for (final entry in source.entries) {
      if (entry.value > 0) {
        positive[entry.key] = entry.value;
      }
    }
    if (positive.isEmpty) return {};

    final maxVal = positive.values.reduce(math.max);
    if (maxVal <= 0) return {};

    final sortedEntries = positive.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final limited = sortedEntries.take(maxEntries);
    final result = <String, double>{};
    for (final entry in limited) {
      result[entry.key] = double.parse((entry.value / maxVal).toStringAsFixed(3));
    }
    return result;
  }
}
