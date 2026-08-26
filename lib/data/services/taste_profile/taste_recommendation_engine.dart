import 'dart:math' as math;
import '../../models/aggregated_item.dart';
import '../../models/taste_profile/taste_profile_models.dart';
import 'taste_genre_service.dart';
import 'taste_server_context.dart';

/// Client-side deterministic scoring, recognizable title discovery, and recommendation engine.
///
/// Fully offline-capable, transparent, and grounded in primary server metadata.
class TasteRecommendationEngine {
  static const double defaultMeanRating = 6.8;
  static const int minMovieVotes = 2000;
  static const int minSeriesVotes = 1000;

  // ──────────────────────────────────────────────────────────────────────────
  // Foreign Content Filtering (Part 6)
  // ──────────────────────────────────────────────────────────────────────────

  /// Checks if an item passes the user's language and foreign content settings.
  static bool isLanguageAllowed({
    required AggregatedItem item,
    required LanguageSettings languageSettings,
    bool isOnboarding = false,
  }) {
    if (!languageSettings.excludeForeignContent) {
      return true;
    }

    final raw = item.rawData;

    // 1. Extract original language
    final originalLang = (raw['OriginalLanguage'] as String? ??
            raw['OriginalTitleLanguage'] as String?)
        ?.trim()
        .toLowerCase();

    // 2. Extract audio languages from MediaStreams
    final audioLanguages = <String>{};
    final streams = raw['MediaStreams'] as List<dynamic>? ?? [];
    for (final s in streams) {
      if (s is Map && s['Type']?.toString().toLowerCase() == 'audio') {
        final lang = s['Language']?.toString().trim().toLowerCase();
        if (lang != null && lang.isNotEmpty) {
          audioLanguages.add(lang);
        }
      }
    }

    // 3. Spoken languages
    final spokenLangs = (raw['SpokenLanguages'] as List<dynamic>? ?? [])
        .map((l) => l.toString().trim().toLowerCase())
        .toSet();

    final allowedOriginal = languageSettings.allowedOriginalLanguages
        .map((l) => l.toLowerCase())
        .toSet();
    final allowedAudio = languageSettings.allowedAudioLanguages
        .map((l) => l.toLowerCase())
        .toSet();

    // Standard English language alias matching (e.g. 'en', 'eng', 'english')
    bool isAllowedCode(String? code, Set<String> allowedSet) {
      if (code == null || code.isEmpty) return false;
      if (allowedSet.contains(code)) return true;
      if ((code == 'en' || code == 'eng' || code == 'english') &&
          (allowedSet.contains('en') ||
              allowedSet.contains('eng') ||
              allowedSet.contains('english'))) {
        return true;
      }
      return false;
    }

    // Check original language match
    if (originalLang != null && originalLang.isNotEmpty) {
      if (isAllowedCode(originalLang, allowedOriginal)) {
        return true;
      }
      // If original language is foreign, but English audio track exists and allowed
      if (audioLanguages.any((a) => isAllowedCode(a, allowedAudio))) {
        return true;
      }
      return false;
    }

    // If original language is missing, check audio languages
    if (audioLanguages.isNotEmpty) {
      if (audioLanguages.any((a) => isAllowedCode(a, allowedAudio))) {
        return true;
      }
      return false;
    }

    // Check spoken languages
    if (spokenLangs.isNotEmpty) {
      if (spokenLangs.any((s) => isAllowedCode(s, allowedOriginal))) {
        return true;
      }
      return false;
    }

    // Missing language metadata fallback
    if (languageSettings.allowUnknownLanguage) {
      return true;
    }

    // For onboarding title selection, strictly exclude missing language by default
    return !isOnboarding && languageSettings.allowForeignFallback;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Well-Known Title Algorithm (Part 5)
  // ──────────────────────────────────────────────────────────────────────────

  /// Calculates deterministic WellKnownScore for library items:
  /// WellKnownScore = 0.35*Pop + 0.30*RatingConf + 0.20*Completion + 0.10*Franchise + 0.05*Metadata
  static WellKnownScoreBreakdown computeWellKnownScore({
    required AggregatedItem item,
    double libraryMeanRating = defaultMeanRating,
    bool isSeries = false,
  }) {
    final raw = item.rawData;

    // 1. PopularityScore (0.0 - 1.0)
    final playCount = (item.userData?['PlayCount'] as num?)?.toDouble() ?? 0.0;
    final voteCount = (raw['VoteCount'] as num?)?.toDouble() ?? 0.0;
    final isFav = item.userData?['IsFavorite'] == true;
    final popRaw = math.min(1.0, (playCount * 0.2) + (voteCount / 25000.0) + (isFav ? 0.3 : 0.0));
    final popularityScore = popRaw.clamp(0.0, 1.0);

    // 2. RatingConfidenceScore (0.0 - 1.0)
    final rawRating = (raw['CommunityRating'] as num?)?.toDouble() ?? 6.0;
    final isMovie = !isSeries && (item.type ?? '').toLowerCase() == 'movie';
    final minVotes = isMovie ? minMovieVotes : minSeriesVotes;
    final bayesian = computeBayesianRating(
      votes: voteCount,
      minVotes: minVotes.toDouble(),
      rating: rawRating,
      meanRating: libraryMeanRating,
    );
    final ratingConfidenceScore = (bayesian / 10.0).clamp(0.0, 1.0);

    // 3. CompletionOrWatchScore (0.0 - 1.0)
    final playedPercent =
        ((item.userData?['PlayedPercentage'] as num?)?.toDouble() ?? 0.0) / 100.0;
    final isPlayed = item.isPlayed;
    final completionScore = (isPlayed ? 1.0 : playedPercent).clamp(0.0, 1.0);

    // 4. FranchiseOrCollectionScore (0.0 - 1.0)
    final hasCollection = (raw['CollectionId'] != null ||
        raw['CollectionName'] != null ||
        raw['SeriesId'] != null);
    final franchiseScore = hasCollection ? 1.0 : 0.0;

    // 5. MetadataCompletenessScore (0.0 - 1.0)
    int metaPoints = 0;
    if (item.primaryImageTag != null || raw['ImageTags'] is Map) metaPoints++;
    if (raw['ProductionYear'] != null) metaPoints++;
    if (raw['Genres'] is List && (raw['Genres'] as List).isNotEmpty) metaPoints++;
    if (raw['People'] is List && (raw['People'] as List).isNotEmpty) metaPoints++;
    if (raw['Overview'] != null && (raw['Overview'] as String).isNotEmpty) metaPoints++;
    final metadataCompletenessScore = (metaPoints / 5.0).clamp(0.0, 1.0);

    final totalScore = (0.35 * popularityScore +
            0.30 * ratingConfidenceScore +
            0.20 * completionScore +
            0.10 * franchiseScore +
            0.05 * metadataCompletenessScore) *
        100.0;

    return WellKnownScoreBreakdown(
      popularityScore: double.parse((popularityScore * 35.0).toStringAsFixed(2)),
      ratingConfidenceScore:
          double.parse((ratingConfidenceScore * 30.0).toStringAsFixed(2)),
      completionOrWatchScore:
          double.parse((completionScore * 20.0).toStringAsFixed(2)),
      franchiseScore: double.parse((franchiseScore * 10.0).toStringAsFixed(2)),
      metadataCompletenessScore:
          double.parse((metadataCompletenessScore * 5.0).toStringAsFixed(2)),
      totalScore: double.parse(totalScore.toStringAsFixed(2)),
    );
  }

  /// Whether an item represents non-entertainment (e.g. documentaries, cooking, earth/planets).
  static bool isExcludedNonEntertainmentItem(AggregatedItem item) {
    final genres = item.genres.map((g) => g.toLowerCase()).toList();
    for (final g in genres) {
      if (TasteGenreService.isExcludedGenreKey(g)) {
        return true;
      }
    }

    final name = item.name.toLowerCase();
    final overview = (item.rawData['Overview']?.toString() ?? '').toLowerCase();

    const excludedTerms = [
      'documentary',
      'documentaries',
      'planet earth',
      'blue planet',
      'frozen planet',
      'our planet',
      'life on earth',
      'cooking show',
      'cooking shows',
      'great british bake',
      'masterchef',
      'hell\'s kitchen',
      'iron chef',
      'chef\'s table',
      'culinary',
      'cookery',
      'food network',
      'top chef',
    ];

    for (final term in excludedTerms) {
      if (name.contains(term) || (name.length < 30 && overview.contains(term))) {
        return true;
      }
    }

    return false;
  }

  /// Selects 24–40 well-known candidate titles for onboarding based on rating confidence and randomized diversity.
  static List<AggregatedItem> selectOnboardingTitles({
    required List<AggregatedItem> libraryItems,
    LanguageSettings languageSettings = const LanguageSettings(),
    int targetCount = 36,
    bool randomize = true,
  }) {
    // 1. Filter out foreign content (unless allowed), missing posters, and documentaries/cooking shows
    final eligible = libraryItems.where((item) {
      if (!isLanguageAllowed(
        item: item,
        languageSettings: languageSettings,
        isOnboarding: true,
      )) {
        return false;
      }
      if (isExcludedNonEntertainmentItem(item)) {
        return false;
      }
      return item.primaryImageTag != null ||
          (item.rawData['ImageTags'] as Map?)?.containsKey('Primary') == true;
    }).toList();

    // 2. Compute well-known score for all eligible items
    final scoredItems = eligible.map((item) {
      final breakdown = computeWellKnownScore(item: item);
      return MapEntry(item, breakdown.totalScore);
    }).toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // 3. Deduplicate editions & cap franchises (max 2 per collection)
    final deduplicated = <AggregatedItem>[];
    final seenTitles = <String>{};
    final franchiseCount = <String, int>{};

    for (final entry in scoredItems) {
      final item = entry.key;
      final cleanTitle = item.name
          .toLowerCase()
          .replaceAll(RegExp(r'\s*\(.*?\)\s*'), '')
          .replaceAll(RegExp(r'\s*\[.*?\]\s*'), '')
          .trim();

      if (seenTitles.contains(cleanTitle)) continue;

      final collectionId = item.rawData['CollectionId']?.toString() ??
          item.rawData['SeriesId']?.toString() ??
          cleanTitle;

      final countInFranchise = franchiseCount[collectionId] ?? 0;
      if (countInFranchise >= 2) continue;

      deduplicated.add(item);
      seenTitles.add(cleanTitle);
      franchiseCount[collectionId] = countInFranchise + 1;
    }

    // 4. Randomize selection from the highest-rated candidate pool if requested
    if (randomize && deduplicated.length > targetCount) {
      final poolSize = math.min(deduplicated.length, targetCount * 2);
      final candidateSlice = deduplicated.sublist(0, poolSize)..shuffle();
      return candidateSlice.take(targetCount).toList();
    }

    return deduplicated.take(targetCount).toList();
  }

  /// Selects 24–40 series candidate titles for onboarding with diverse formats:
  /// limited series, 1-season, multi-season, long-running, completed, in-progress, bingeable.
  static List<AggregatedItem> selectOnboardingSeriesCandidates({
    required List<AggregatedItem> librarySeries,
    LanguageSettings languageSettings = const LanguageSettings(),
    int targetCount = 36,
    bool randomize = true,
  }) {
    // 1. Filter out foreign content, missing posters, and documentaries/cooking shows
    final eligible = librarySeries.where((item) {
      if (!isLanguageAllowed(
        item: item,
        languageSettings: languageSettings,
        isOnboarding: true,
      )) {
        return false;
      }
      if (isExcludedNonEntertainmentItem(item)) {
        return false;
      }
      return item.primaryImageTag != null ||
          (item.rawData['ImageTags'] as Map?)?.containsKey('Primary') == true;
    }).toList();

    // 2. Compute well-known score with series balance
    final scoredItems = eligible.map((item) {
      final breakdown = computeWellKnownScore(item: item, isSeries: true);
      return MapEntry(item, breakdown.totalScore);
    }).toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // 3. Deduplicate
    final deduplicated = <AggregatedItem>[];
    final seenTitles = <String>{};

    for (final entry in scoredItems) {
      final item = entry.key;
      final cleanTitle = item.name.toLowerCase().trim();
      if (seenTitles.add(cleanTitle)) {
        deduplicated.add(item);
      }
    }

    // 4. Randomize top pool
    if (randomize && deduplicated.length > targetCount) {
      final poolSize = math.min(deduplicated.length, targetCount * 2);
      final candidateSlice = deduplicated.sublist(0, poolSize)..shuffle();
      return candidateSlice.take(targetCount).toList();
    }

    return deduplicated.take(targetCount).toList();
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Recommendation Scoring (Part 7)
  // ──────────────────────────────────────────────────────────────────────────

  /// Scores candidate library items against the user's taste profile.
  static List<RecommendationItem> scoreItems({
    required List<AggregatedItem> candidates,
    required TasteProfile profile,
    int limit = 20,
    double libraryMeanRating = defaultMeanRating,
    bool allowWatched = false,
  }) {
    final scoredList = <RecommendationItem>[];
    final scoringContext = TasteScoringContext.fromProfile(profile);
    final negativeIds = scoringContext.negativeIds;
    final explicitTitles = scoringContext.normalizedTitleRatings;
    final langSettings = profile.languageSettings;

    // Filter out disliked items, negative signals, and foreign language content
    final validCandidates = candidates.where((item) {
      if (negativeIds.contains(item.id)) return false;
      if (explicitTitles[item.id] == TasteRating.dislike) return false;
      if (!allowWatched && item.isPlayed) return false;
      if (!isLanguageAllowed(item: item, languageSettings: langSettings)) {
        return false;
      }
      return true;
    }).toList();

    for (final item in validCandidates) {
      final breakdown = computeScoreBreakdown(
        item: item,
        profile: profile,
        scoringContext: scoringContext,
        libraryMeanRating: libraryMeanRating,
      );

      final totalScore = breakdown.values.fold(0.0, (a, b) => a + b);
      final reason = generateExplainabilityReason(item, profile, breakdown);
      final crossKey = TasteServerContext.computeCrossServerKey(
        rawData: item.rawData,
        title: item.name,
        year: item.productionYear,
        mediaType: item.type,
      );

      scoredList.add(
        RecommendationItem(
          item: item,
          score: double.parse(totalScore.clamp(0.0, 100.0).toStringAsFixed(2)),
          reason: reason,
          breakdown: breakdown,
          crossServerKey: crossKey,
          selectedServerId: item.serverId,
          jellyfinItemId: item.id,
          availableServerIds: [item.serverId],
          metadataSourceServerId: item.serverId,
          groundedExplanation: reason,
        ),
      );
    }

    // Sort by score descending
    scoredList.sort((a, b) => b.score.compareTo(a.score));

    // Apply diversification (max 2 items per franchise/series)
    return diversifyRecommendations(scoredList, limit: limit);
  }

  /// Evaluates individual score components for an item (returns weighted subscores summing to ~100.0).
  static Map<String, double> computeScoreBreakdown({
    required AggregatedItem item,
    required TasteProfile profile,
    TasteScoringContext? scoringContext,
    double libraryMeanRating = defaultMeanRating,
  }) {
    final explicit = profile.explicit;
    final inferred = profile.inferred;
    final ctx = scoringContext ?? TasteScoringContext.fromProfile(profile);

    // 1. Genre & Mood Match (35%)
    double genreMoodScore = 0.0;
    final itemGenres = (item.rawData['Genres'] as List<dynamic>? ?? [])
        .map((g) => g.toString().toLowerCase().trim())
        .toList();

    if (itemGenres.isNotEmpty) {
      double matchSum = 0.0;
      for (final g in itemGenres) {
        // Fast O(1) map lookup
        final explicitRating = ctx.normalizedGenreRatings[g] ?? TasteRating.neutral;

        if (explicitRating == TasteRating.love) {
          matchSum += 1.0;
        } else if (explicitRating == TasteRating.like) {
          matchSum += 0.75;
        } else if (explicitRating == TasteRating.dislike) {
          matchSum -= 1.0;
        } else {
          // Fast O(1) inferred lookup
          final inferredVal = ctx.normalizedGenreAffinities[g] ?? 0.0;
          matchSum += inferredVal;
        }
      }
      genreMoodScore = (matchSum / itemGenres.length).clamp(0.0, 1.0);
    }

    // Mood boost (supports both legacy MoodCategory and extended 200 vibes)
    final tags = (item.rawData['Tags'] as List<dynamic>? ?? [])
        .map((t) => t.toString().toLowerCase())
        .toSet();
    final overviewLower = (item.rawData['Overview'] as String? ?? '').toLowerCase();

    if (ctx.moodKeywords.isNotEmpty || ctx.activeMoodDefinitions.isNotEmpty) {
      bool moodFound = false;
      if (ctx.moodKeywords.isNotEmpty) {
        for (final kw in ctx.moodKeywords) {
          if (itemGenres.contains(kw) || tags.contains(kw)) {
            genreMoodScore = math.min(1.0, genreMoodScore + 0.20);
            moodFound = true;
            break;
          }
        }
      }
      if (!moodFound && ctx.activeMoodDefinitions.isNotEmpty) {
        for (final def in ctx.activeMoodDefinitions) {
          final genreHit = def.relatedJellyfinGenres.any(
            (rg) => itemGenres.contains(rg.toLowerCase()),
          );
          final tagHit = def.relatedJellyfinTags.any(
            (rt) => tags.contains(rt.toLowerCase()),
          );
          final kwHit = def.relatedOverviewKeywords.any(
            (kw) => overviewLower.contains(kw.toLowerCase()),
          );
          if (genreHit || tagHit || kwHit) {
            genreMoodScore = math.min(1.0, genreMoodScore + 0.20);
            break;
          }
        }
      }
    }

    // 2. People Affinity (20%)
    double peopleScore = 0.0;
    final people = item.rawData['People'] as List<dynamic>? ?? [];
    if (people.isNotEmpty) {
      double peopleSum = 0.0;
      int checkedCount = 0;
      for (final p in people.take(6)) {
        if (p is! Map) continue;
        final name = p['Name']?.toString().toLowerCase().trim() ?? '';
        final type = p['Type']?.toString().toLowerCase().trim() ?? '';
        checkedCount++;

        if (type == 'director') {
          final dirAff = ctx.normalizedDirectorAffinities[name] ?? 0.0;
          peopleSum += dirAff * 1.5;
        } else if (type == 'actor') {
          final actAff = ctx.normalizedActorAffinities[name] ?? 0.0;
          peopleSum += actAff;
        }
      }
      if (checkedCount > 0) {
        peopleScore = (peopleSum / checkedCount).clamp(0.0, 1.0);
      }
    }

    // 3. Title Quality Score (Bayesian Weighted Rating) (15%)
    final rawRating = (item.rawData['CommunityRating'] as num?)?.toDouble() ?? 6.0;
    final isMovie = (item.type ?? '').toLowerCase() == 'movie';
    final minVotes = isMovie ? minMovieVotes : minSeriesVotes;
    final voteCount = (item.rawData['VoteCount'] as num?)?.toDouble() ?? 500.0;
    final bayesianRating = computeBayesianRating(
      votes: voteCount,
      minVotes: minVotes.toDouble(),
      rating: rawRating,
      meanRating: libraryMeanRating,
    );
    final qualityScore = (bayesianRating / 10.0).clamp(0.0, 1.0);

    // 4. Similar Title / History Seed Match (10%)
    double similarTitleScore = 0.5;
    final studio = item.rawData['Studios'] is List && (item.rawData['Studios'] as List).isNotEmpty
        ? (item.rawData['Studios'] as List).first['Name']?.toString().trim()
        : null;
    if (studio != null && inferred.studioAffinities.containsKey(studio)) {
      similarTitleScore = math.min(1.0, 0.5 + inferred.studioAffinities[studio]! * 0.5);
    }

    // 5. Era, Runtime, Format & Preferences Fit (10%)
    double fitScore = 1.0;
    final year = (item.rawData['ProductionYear'] as num?)?.toInt() ?? 2020;
    final viewing = explicit.viewingPreferences;
    final prefIds = viewing.selectedPreferenceIds;

    // Legacy and extended Era checks
    if (viewing.preferredEra == 'classic' && year >= 1980) fitScore -= 0.3;
    if (viewing.preferredEra == 'modern' && (year < 1980 || year > 2010)) fitScore -= 0.2;
    if (viewing.preferredEra == 'recent' && year < 2010) fitScore -= 0.3;

    if (prefIds.contains('era_silent_era') && year >= 1930) fitScore -= 0.3;
    if (prefIds.contains('era_classic_hollywood') && (year < 1930 || year > 1949)) fitScore -= 0.3;
    if (prefIds.contains('era_1950s') && (year < 1950 || year > 1959)) fitScore -= 0.25;
    if (prefIds.contains('era_1960s') && (year < 1960 || year > 1969)) fitScore -= 0.25;
    if (prefIds.contains('era_1970s') && (year < 1970 || year > 1979)) fitScore -= 0.25;
    if (prefIds.contains('era_1980s') && (year < 1980 || year > 1989)) fitScore -= 0.25;
    if (prefIds.contains('era_1990s') && (year < 1990 || year > 1999)) fitScore -= 0.25;
    if (prefIds.contains('era_2000s') && (year < 2000 || year > 2009)) fitScore -= 0.25;
    if (prefIds.contains('era_2010s') && (year < 2010 || year > 2019)) fitScore -= 0.25;
    if (prefIds.contains('era_2020s') && year < 2020) fitScore -= 0.25;
    if (prefIds.contains('era_mostly_classic') && year >= 1980) fitScore -= 0.3;
    if (prefIds.contains('era_mostly_modern') && year < 2000) fitScore -= 0.2;
    if (prefIds.contains('era_recent_only') && year < 2022) fitScore -= 0.3;

    // Runtime ticks & format checks
    final runtimeTicks = item.runTimeTicks;
    final runtimeMinutes = runtimeTicks != null
        ? (runtimeTicks ~/ (10000000 * 60))
        : 0;
    if (viewing.maxMovieLengthMinutes > 0 &&
        runtimeMinutes > viewing.maxMovieLengthMinutes) {
      fitScore -= 0.4;
    }
    if (prefIds.contains('fmt_runtime_under_90') && runtimeMinutes > 90) fitScore -= 0.3;
    if (prefIds.contains('fmt_runtime_90_120') && (runtimeMinutes < 90 || runtimeMinutes > 120)) fitScore -= 0.2;
    if (prefIds.contains('fmt_runtime_over_120') && runtimeMinutes > 0 && runtimeMinutes < 120) fitScore -= 0.3;

    if (prefIds.contains('fmt_movies_only') && !isMovie) fitScore -= 0.4;
    if (prefIds.contains('fmt_series_only') && isMovie) fitScore -= 0.4;

    fitScore = fitScore.clamp(0.0, 1.0);

    // 6. Novelty and Diversity Bonus (10%)
    final playCount = (item.userData?['PlayCount'] as num?)?.toInt() ?? 0;
    double noveltyScore = (!item.isPlayed && playCount == 0) ? 1.0 : 0.4;
    if (prefIds.contains('disc_hidden_gems') || prefIds.contains('disc_underrated')) {
      if (rawRating >= 7.2 && voteCount < 5000) {
        noveltyScore = math.min(1.0, noveltyScore + 0.3);
      }
    }
    if (prefIds.contains('disc_surprise_me') || prefIds.contains('disc_maximum_variety')) {
      noveltyScore = 1.0;
    }

    return {
      'genreMood': genreMoodScore * 35.0,
      'people': peopleScore * 20.0,
      'quality': qualityScore * 15.0,
      'similarTitle': similarTitleScore * 10.0,
      'fit': fitScore * 10.0,
      'novelty': noveltyScore * 10.0,
    };
  }

  /// Calculates Bayesian weighted rating: (v / (v + m)) * R + (m / (v + m)) * C
  static double computeBayesianRating({
    required double votes,
    required double minVotes,
    required double rating,
    required double meanRating,
  }) {
    if (votes + minVotes == 0) return rating;
    final weighted = (votes / (votes + minVotes)) * rating +
        (minVotes / (votes + minVotes)) * meanRating;
    return double.parse(weighted.toStringAsFixed(2));
  }

  /// Grounded reason generator ensuring reasons are 100% derived from actual signals.
  static String generateExplainabilityReason(
    AggregatedItem item,
    TasteProfile profile,
    Map<String, double> breakdown,
  ) {
    // 1. Award metadata / milestone tags first
    final overview = (item.rawData['Overview'] as String? ?? '').toLowerCase();
    final tags = (item.rawData['Tags'] as List<dynamic>? ?? [])
        .map((t) => t.toString().toLowerCase())
        .toList();

    if (overview.contains('oscar') ||
        overview.contains('academy award') ||
        tags.contains('oscar winner') ||
        tags.contains('best picture') ||
        tags.contains('award winner')) {
      return 'Academy Award-Winning Title';
    }

    // 2. Top director / actor match
    final people = item.rawData['People'] as List<dynamic>? ?? [];
    for (final p in people.take(4)) {
      if (p is! Map) continue;
      final name = p['Name']?.toString().trim() ?? '';
      if (profile.inferred.directorAffinities.containsKey(name)) {
        return 'From director $name';
      }
      if (profile.inferred.actorAffinities.containsKey(name)) {
        return 'Starring $name';
      }
    }

    // 3. Explicit genre preference
    final genres = (item.rawData['Genres'] as List<dynamic>? ?? [])
        .map((g) => g.toString().trim())
        .toList();
    for (final g in genres) {
      final rating = profile.explicit.genreRatings[g];
      if (rating == TasteRating.love || rating == TasteRating.like) {
        return 'Matches your love for $g';
      }
    }

    // 4. Extended or legacy mood match
    if (profile.explicit.selectedMoodIds.isNotEmpty) {
      final firstMoodId = profile.explicit.selectedMoodIds.first;
      final def = TasteMoodRegistry.getById(firstMoodId);
      if (def != null) {
        return 'Selected for your "${def.displayName}" vibe';
      }
    }
    if (profile.explicit.selectedMoods.isNotEmpty) {
      final mood = profile.explicit.selectedMoods.first;
      return 'Selected for your ${mood.label} mood';
    }

    // 5. Rating / High quality fallback
    final rating = (item.rawData['CommunityRating'] as num?)?.toDouble();
    if (rating != null && rating >= 7.8) {
      return 'Critically acclaimed ($rating/10)';
    }

    return 'Curated based on your watch history';
  }

  /// Filters candidates so no single franchise / collection dominates a row.
  static List<RecommendationItem> diversifyRecommendations(
    List<RecommendationItem> scoredItems, {
    int limit = 20,
    int maxPerCollection = 2,
  }) {
    final result = <RecommendationItem>[];
    final collectionCount = <String, int>{};

    for (final rec in scoredItems) {
      final item = rec.item;
      final collectionId = item.rawData['CollectionId']?.toString() ??
          item.rawData['SeriesId']?.toString() ??
          item.id;

      final current = collectionCount[collectionId] ?? 0;
      if (current < maxPerCollection) {
        result.add(rec);
        collectionCount[collectionId] = current + 1;
      }
      if (result.length >= limit) break;
    }

    return result;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Curated Algorithmic Collections (Part 8)
  // ──────────────────────────────────────────────────────────────────────────

  /// Generates the "Oscar-Winning Performances" curated collection.
  static List<RecommendationItem> generateOscarWinners({
    required List<AggregatedItem> libraryItems,
    required TasteProfile profile,
    int limit = 20,
  }) {
    final matched = libraryItems.where((item) {
      final overview = (item.rawData['Overview'] as String? ?? '').toLowerCase();
      final tags = (item.rawData['Tags'] as List<dynamic>? ?? [])
          .map((t) => t.toString().toLowerCase())
          .toSet();
      return overview.contains('oscar') ||
          overview.contains('academy award') ||
          tags.contains('oscar winner') ||
          tags.contains('best picture') ||
          tags.contains('best actor');
    }).toList();

    return scoreItems(
      candidates: matched,
      profile: profile,
      limit: limit,
      allowWatched: true,
    );
  }

  /// Generates the "From Nominee to Winner" curated collection.
  static List<RecommendationItem> generateFromNomineeToWinner({
    required List<AggregatedItem> libraryItems,
    required TasteProfile profile,
    int limit = 20,
  }) {
    final topActors = profile.inferred.actorAffinities.keys.take(6).toSet();
    final matched = libraryItems.where((item) {
      final people = (item.rawData['People'] as List<dynamic>? ?? [])
          .map((p) => p is Map ? p['Name']?.toString().trim() ?? '' : '')
          .toSet();
      return people.any(topActors.contains);
    }).toList();

    final scored = scoreItems(
      candidates: matched,
      profile: profile,
      limit: limit,
      allowWatched: true,
    );

    return scored.map((rec) {
      final overview = (rec.item.rawData['Overview'] as String? ?? '').toLowerCase();
      final isWinner = overview.contains('won') || overview.contains('winner');
      final badge = isWinner ? 'Winner' : 'Nominee';
      return RecommendationItem(
        item: rec.item,
        score: rec.score,
        reason: '$badge · ${rec.reason}',
        badgeText: badge,
        breakdown: rec.breakdown,
      );
    }).toList();
  }

  /// Generates the "Career Milestones" curated collection.
  static List<RecommendationItem> generateCareerMilestones({
    required List<AggregatedItem> libraryItems,
    required TasteProfile profile,
    int limit = 20,
  }) {
    final topActors = profile.inferred.actorAffinities.keys.take(5).toSet();
    final matched = libraryItems.where((item) {
      final people = (item.rawData['People'] as List<dynamic>? ?? [])
          .map((p) => p is Map ? p['Name']?.toString().trim() ?? '' : '')
          .toSet();
      return people.any(topActors.contains);
    }).toList();

    final scored = scoreItems(
      candidates: matched,
      profile: profile,
      limit: limit,
      allowWatched: true,
    );

    return scored.map((rec) {
      final year = (rec.item.rawData['ProductionYear'] as num?)?.toInt() ?? 2000;
      String milestone = 'Career Milestone';
      if (year < 1995) {
        milestone = 'Breakthrough Role';
      } else if (year < 2012) {
        milestone = 'Critical Peak';
      } else {
        milestone = 'Recent Renaissance';
      }
      return RecommendationItem(
        item: rec.item,
        score: rec.score,
        reason: '$milestone · ${rec.reason}',
        badgeText: milestone,
        breakdown: rec.breakdown,
      );
    }).toList();
  }

  /// Generates "Well-Known Titles You May Have Missed" row.
  static List<RecommendationItem> generateWellKnownMissed({
    required List<AggregatedItem> libraryItems,
    required TasteProfile profile,
    int limit = 20,
  }) {
    final unplayed = libraryItems.where((i) => !i.isPlayed).toList();
    final wellKnownScored = unplayed.map((item) {
      final bk = computeWellKnownScore(item: item);
      return MapEntry(item, bk.totalScore);
    }).toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final topWellKnown = wellKnownScored.take(limit * 2).map((e) => e.key).toList();

    return scoreItems(
      candidates: topWellKnown,
      profile: profile,
      limit: limit,
      allowWatched: false,
    );
  }

  /// Generates the "Genre Deep Cuts" collection: high Bayesian rating with lower overall popularity.
  static List<RecommendationItem> generateGenreDeepCuts({
    required List<AggregatedItem> libraryItems,
    required TasteProfile profile,
    int limit = 20,
  }) {
    final topGenres = profile.inferred.genreAffinities.keys.take(3).toSet();
    final candidates = libraryItems.where((item) {
      final genres = (item.rawData['Genres'] as List<dynamic>? ?? [])
          .map((g) => g.toString().trim())
          .toSet();
      final rating = (item.rawData['CommunityRating'] as num?)?.toDouble() ?? 0.0;
      final votes = (item.rawData['VoteCount'] as num?)?.toInt() ?? 0;
      return genres.any(topGenres.contains) && rating >= 7.2 && (votes == 0 || votes < 10000);
    }).toList();

    return scoreItems(
      candidates: candidates,
      profile: profile,
      limit: limit,
      allowWatched: false,
    );
  }

  /// Generates the "Something Different" (anti-filter-bubble) collection.
  static List<RecommendationItem> generateSomethingDifferent({
    required List<AggregatedItem> libraryItems,
    required TasteProfile profile,
    int limit = 20,
  }) {
    final frequentGenres = profile.inferred.genreAffinities.keys.take(4).toSet();
    final candidates = libraryItems.where((item) {
      final genres = (item.rawData['Genres'] as List<dynamic>? ?? [])
          .map((g) => g.toString().trim())
          .toSet();
      final rating = (item.rawData['CommunityRating'] as num?)?.toDouble() ?? 0.0;
      return !genres.any(frequentGenres.contains) && rating >= 7.5;
    }).toList();

    return scoreItems(
      candidates: candidates,
      profile: profile,
      limit: limit,
      allowWatched: false,
    );
  }
}

/// Pre-indexed lookup context enabling O(1) scoring calculations during bulk recommendation passes.
class TasteScoringContext {
  final Map<String, TasteRating> normalizedGenreRatings;
  final Map<String, double> normalizedGenreAffinities;
  final Map<String, double> normalizedDirectorAffinities;
  final Map<String, double> normalizedActorAffinities;
  final Map<String, TasteRating> normalizedTitleRatings;
  final Set<String> negativeIds;
  final Set<String> moodKeywords;
  final List<TasteMoodDefinition> activeMoodDefinitions;

  TasteScoringContext.fromProfile(TasteProfile profile)
      : normalizedGenreRatings = profile.explicit.genreRatings.map(
          (k, v) => MapEntry(k.toLowerCase().trim(), v),
        ),
        normalizedGenreAffinities = profile.inferred.genreAffinities.map(
          (k, v) => MapEntry(k.toLowerCase().trim(), v),
        ),
        normalizedDirectorAffinities = profile.inferred.directorAffinities.map(
          (k, v) => MapEntry(k.toLowerCase().trim(), v),
        ),
        normalizedActorAffinities = profile.inferred.actorAffinities.map(
          (k, v) => MapEntry(k.toLowerCase().trim(), v),
        ),
        normalizedTitleRatings = profile.explicit.titleRatings.map(
          (k, v) => MapEntry(k.toLowerCase().trim(), v),
        ),
        negativeIds = profile.negativeSignals.map((n) => n.id).toSet(),
        moodKeywords = profile.explicit.selectedMoods
            .expand((m) => m.keywords.split(','))
            .map((k) => k.toLowerCase().trim())
            .where((k) => k.isNotEmpty)
            .toSet(),
        activeMoodDefinitions = profile.explicit.selectedMoodIds
            .map(TasteMoodRegistry.getById)
            .whereType<TasteMoodDefinition>()
            .toList();
}
