import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import '../../../preference/user_preferences.dart';
import '../../models/aggregated_item.dart';
import '../../models/taste_profile/taste_profile_models.dart';
import '../../repositories/taste_profile_repository.dart';

/// Service interfacing with xAI Grok API, custom LLM proxy, or local deterministic engine for AI taste intelligence.
class GrokTasteAiService {
  final Dio _dio;
  String? _overrideApiKey;
  String? _overrideModel;
  String? _overrideEndpoint;

  static const String defaultEndpoint = 'https://api.x.ai/v1/chat/completions';
  static const String defaultModel = 'grok-2-latest';

  GrokTasteAiService({
    Dio? dio,
    String? apiKey,
    String? model,
    String? endpoint,
  })  : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
            )),
        _overrideApiKey = apiKey,
        _overrideModel = model,
        _overrideEndpoint = endpoint;

  /// Sets or updates the Grok API Key at runtime.
  void setApiKey(String? apiKey) {
    _overrideApiKey = apiKey;
  }

  /// Sets the selected Grok model (e.g. `grok-2-latest`, `grok-2`, `grok-beta`).
  void setModel(String? model) {
    _overrideModel = model;
  }

  /// Sets the API endpoint (e.g. `https://api.x.ai/v1/chat/completions` or custom server proxy).
  void setEndpoint(String? endpoint) {
    _overrideEndpoint = endpoint;
  }

  /// Resolves the API endpoint.
  String get endpoint {
    if (_overrideEndpoint != null && _overrideEndpoint!.isNotEmpty) {
      return _overrideEndpoint!;
    }
    const compileEnv = String.fromEnvironment('GROK_ENDPOINT');
    if (compileEnv.isNotEmpty) return compileEnv;

    const compileEnvXai = String.fromEnvironment('XAI_ENDPOINT');
    if (compileEnvXai.isNotEmpty) return compileEnvXai;

    try {
      if (GetIt.instance.isRegistered<UserPreferences>()) {
        final prefEndpoint = GetIt.instance<UserPreferences>().get(UserPreferences.grokEndpoint);
        if (prefEndpoint.isNotEmpty) return prefEndpoint;
      }
    } catch (_) {}

    try {
      for (final key in [
        'GROK_ENDPOINT',
        'XAI_ENDPOINT',
        'APPSETTING_GROK_ENDPOINT',
        'grok_endpoint',
      ]) {
        final val = Platform.environment[key];
        if (val != null && val.isNotEmpty) return val;
      }
    } catch (_) {}

    return defaultEndpoint;
  }

  /// Resolves the Grok model from runtime override, compile-time env (GROK_MODEL / XAI_MODEL),
  /// user preferences, system environment variable, or defaults to `grok-2-latest`.
  String get selectedModel {
    if (_overrideModel != null && _overrideModel!.isNotEmpty) {
      return _overrideModel!;
    }
    const compileEnv = String.fromEnvironment('GROK_MODEL');
    if (compileEnv.isNotEmpty) return compileEnv;

    const compileEnvXai = String.fromEnvironment('XAI_MODEL');
    if (compileEnvXai.isNotEmpty) return compileEnvXai;

    try {
      if (GetIt.instance.isRegistered<UserPreferences>()) {
        final prefModel = GetIt.instance<UserPreferences>().get(UserPreferences.grokModel);
        if (prefModel.isNotEmpty) return prefModel;
      }
    } catch (_) {}

    try {
      for (final key in [
        'GROK_MODEL',
        'XAI_MODEL',
        'APPSETTING_GROK_MODEL',
        'APPSETTING_XAI_MODEL',
        'grok_model',
        'xai_model',
      ]) {
        final val = Platform.environment[key];
        if (val != null && val.isNotEmpty) return val;
      }
    } catch (_) {}

    return defaultModel;
  }

  /// Resolves the Grok API Key from runtime override, compile-time env, user preferences, or system env.
  String get apiKey {
    if (_overrideApiKey != null && _overrideApiKey!.isNotEmpty) {
      return _overrideApiKey!;
    }
    const compileKeys = [
      String.fromEnvironment('GROK_API_KEY'),
      String.fromEnvironment('XAI_API_KEY'),
      String.fromEnvironment('GROK_KEY'),
      String.fromEnvironment('XAI_KEY'),
      String.fromEnvironment('APPSETTING_GROK_API_KEY'),
      String.fromEnvironment('APPSETTING_XAI_API_KEY'),
    ];
    for (final k in compileKeys) {
      if (k.isNotEmpty) return k;
    }

    try {
      if (GetIt.instance.isRegistered<UserPreferences>()) {
        final prefKey = GetIt.instance<UserPreferences>().get(UserPreferences.grokApiKey);
        if (prefKey.isNotEmpty) return prefKey;
      }
    } catch (_) {}

    try {
      for (final key in [
        'GROK_API_KEY',
        'XAI_API_KEY',
        'GROK_KEY',
        'XAI_KEY',
        'APPSETTING_GROK_API_KEY',
        'APPSETTING_XAI_API_KEY',
        'CUSTOMCONNSTR_GROK_API_KEY',
        'grok_api_key',
        'xai_api_key',
      ]) {
        final val = Platform.environment[key];
        if (val != null && val.isNotEmpty) return val;
      }
    } catch (_) {}

    return '';
  }

  /// Whether a valid Grok API key is configured.
  bool get isConfigured => apiKey.isNotEmpty;

  /// Resolves human-readable titles for loved or liked titles, avoiding raw IDs.
  List<String> _resolveLovedTitleNames(TasteProfile profile) {
    final lovedEntries = profile.explicit.titleRatings.entries
        .where((e) => e.value == TasteRating.love || e.value == TasteRating.like)
        .toList();

    final names = <String>[];
    final seen = <String>{};

    for (final entry in lovedEntries) {
      final id = entry.key;
      // 1. Check explicit titleNames map
      final mappedName = profile.explicit.titleNames[id]?.trim();
      if (mappedName != null && mappedName.isNotEmpty && !_isRawIdString(mappedName)) {
        if (seen.add(mappedName.toLowerCase())) {
          names.add(mappedName);
        }
        continue;
      }

      // 2. Check if the key itself is actually a human-readable title name (e.g. legacy name or explicit title)
      if (!_isRawIdString(id)) {
        if (seen.add(id.toLowerCase())) {
          names.add(id);
        }
        continue;
      }

      // 3. Try to resolve from sync manager / cached items if available in GetIt
      try {
        if (GetIt.instance.isRegistered<TasteProfileRepository>()) {
          final repo = GetIt.instance<TasteProfileRepository>();
          final movies = repo.syncManager.cachedMovies;
          final matchMovie = movies.where((m) => m.id == id).firstOrNull;
          if (matchMovie != null && matchMovie.name.isNotEmpty && !_isRawIdString(matchMovie.name)) {
            if (seen.add(matchMovie.name.toLowerCase())) {
              names.add(matchMovie.name);
            }
            continue;
          }
          final series = repo.syncManager.cachedSeries;
          final matchSeries = series.where((s) => s.id == id).firstOrNull;
          if (matchSeries != null && matchSeries.name.isNotEmpty && !_isRawIdString(matchSeries.name)) {
            if (seen.add(matchSeries.name.toLowerCase())) {
              names.add(matchSeries.name);
            }
            continue;
          }
        }
      } catch (_) {}
    }
    return names;
  }

  /// Determines if a string is a raw ID (hex UUID, numeric ID, or database hash) rather than a human-readable title.
  static bool _isRawIdString(String s) {
    final trimmed = s.trim();
    if (trimmed.isEmpty) return true;
    // Pure integer / numeric ID (e.g. "12345")
    if (RegExp(r'^\d+$').hasMatch(trimmed)) return true;
    // UUID with hyphens (e.g. "f89d3a77-2c91-4b1b-9e54-...")
    if (RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$').hasMatch(trimmed)) return true;
    // Long hex string (e.g. "f89d3a772c914b1b9e54a6210f...")
    if (RegExp(r'^[0-9a-fA-F]{16,}$').hasMatch(trimmed)) return true;
    // Prefixed IDs like "item_12345" or "iptv_98234"
    if (RegExp(r'^(item_|iptv_|tmdb_|imdb_|id_)\w+$', caseSensitive: false).hasMatch(trimmed)) return true;
    return false;
  }

  /// Generates a Grok Taste Persona analysis based on the user's explicit preferences and history.
  Future<String?> generateTastePersonaInsight(TasteProfile profile) async {
    // If configured with an API key, attempt live xAI Grok inference
    if (isConfigured) {
      debugPrint('[GrokTasteAiService] Initiating live AI inference call to endpoint: $endpoint using model: $selectedModel');
      final lovedTitles = _resolveLovedTitleNames(profile);

      final lovedGenres = profile.explicit.genreRatings.entries
          .where((e) => e.value == TasteRating.love || e.value == TasteRating.like)
          .map((e) => '${e.key} (${e.value.name})')
          .toList();

      final activeVibes = profile.explicit.selectedMoodIds
          .map((id) => TasteMoodRegistry.getById(id)?.displayName ?? id)
          .toList();

      final activePrefs = profile.explicit.viewingPreferences.selectedPreferenceIds
          .map((id) => TastePreferenceRegistry.getById(id)?.displayName ?? id)
          .toList();

      final systemPrompt =
          'You are Grok, a witty, sophisticated, and deeply cinephilic AI film and television recommender '
          'integrated into the Voltix media streaming platform. Analyze the user’s taste profile, favorite genres, '
          'cinematic vibes, and narrative preferences. Provide a sharp, engaging, and personalized 2-paragraph analysis '
          'of their cinematic identity, highlighting their distinct taste DNA and what makes their watching habits unique. '
          'Do not use generic buzzwords. Be perceptive, nuanced, and direct.';

      final userContent = StringBuffer();
      userContent.writeln('Here is my Taste Profile:');
      if (lovedTitles.isNotEmpty) {
        userContent.writeln('- Loved Titles: ${lovedTitles.take(10).join(', ')}');
      }
      if (lovedGenres.isNotEmpty) {
        userContent.writeln('- Preferred Genres: ${lovedGenres.join(', ')}');
      }
      if (activeVibes.isNotEmpty) {
        userContent.writeln('- Preferred Moods & Vibes: ${activeVibes.take(12).join(', ')}');
      }
      if (activePrefs.isNotEmpty) {
        userContent.writeln('- Viewing Preferences: ${activePrefs.take(10).join(', ')}');
      }
      userContent.writeln('- Format Preference: ${profile.explicit.viewingPreferences.formatPreference}');
      userContent.writeln('- Era Preference: ${profile.explicit.viewingPreferences.preferredEra}');

      try {
        final response = await _dio.post<Map<String, dynamic>>(
          endpoint,
          data: {
            'model': selectedModel,
            'messages': [
              {'role': 'system', 'content': systemPrompt},
              {'role': 'user', 'content': userContent.toString()},
            ],
            'temperature': 0.7,
            'max_tokens': 600,
          },
          options: Options(
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
          ),
        );

        if (response.statusCode == 200 && response.data != null) {
          final choices = response.data!['choices'] as List?;
          if (choices != null && choices.isNotEmpty) {
            final msg = choices.first['message'];
            if (msg != null && msg['content'] != null) {
              final text = (msg['content'] as String).trim();
              if (text.isNotEmpty) {
                debugPrint('[GrokTasteAiService] Live AI call succeeded. Persona insight generated.');
                return text;
              }
            }
          }
        }
      } catch (e) {
        debugPrint('[GrokTasteAiService] Live AI call to $endpoint failed ($e), falling back to calibrated deterministic synthesis.');
      }
    } else {
      debugPrint('[GrokTasteAiService] No external API key configured. Executing offline deterministic persona synthesis.');
    }

    // High-quality deterministic cinephilic persona synthesis fallback
    return generateLocalPersonaInsight(profile);
  }

  /// Generates a rich, nuanced, and personalized cinematic persona insight based on the profile data.
  String generateLocalPersonaInsight(TasteProfile profile) {
    final lovedTitles = _resolveLovedTitleNames(profile);

    final lovedGenres = profile.explicit.genreRatings.entries
        .where((e) => e.value == TasteRating.love || e.value == TasteRating.like)
        .map((e) => e.key)
        .toList();

    final activeVibes = profile.explicit.selectedMoodIds
        .map((id) => TasteMoodRegistry.getById(id)?.displayName ?? id)
        .toList();

    final era = profile.explicit.viewingPreferences.preferredEra;
    final format = profile.explicit.viewingPreferences.formatPreference;

    final primaryGenre = lovedGenres.isNotEmpty ? lovedGenres.first : 'Cinema';
    final secondaryGenre = lovedGenres.length > 1 ? lovedGenres[1] : '';

    final genreDescriptor = secondaryGenre.isNotEmpty
        ? '$primaryGenre and $secondaryGenre'
        : primaryGenre;

    final titleMention = lovedTitles.isNotEmpty
        ? ' Anchored by strong affinities for titles like ${lovedTitles.take(3).join(", ")},'
        : '';

    final vibeMention = activeVibes.isNotEmpty
        ? 'drawn toward ${activeVibes.take(3).join(", ")} atmospheric aesthetics'
        : 'focused on rich character development, distinctive world-building, and dynamic pacing';

    final eraMention = era != 'all' && era.isNotEmpty
        ? ' with a distinct appreciation for the $era storytelling style'
        : '';

    final p1 = 'Your cinematic DNA reflects a refined appetite for compelling $genreDescriptor storytelling.$titleMention you consistently favor productions that balance narrative depth with memorable character arcs.';
    final p2 = 'You are especially $vibeMention$eraMention. Whether diving into ${format == 'series' ? 'immersive episodic seasons' : format == 'movies' ? 'feature-length cinematic experiences' : 'gripping features and series'}, your taste profile highlights nuanced storytelling and authentic directorial vision.';

    return '$p1\n\n$p2';
  }

  /// Generates a natural-language Grok recommendation reason for a specific candidate title.
  Future<String?> generateGrokRecommendationReason({
    required AggregatedItem item,
    required TasteProfile profile,
  }) async {
    if (isConfigured) {
      final title = item.name;
      final genres = item.genres.join(', ');
      try {
        final response = await _dio.post<Map<String, dynamic>>(
          endpoint,
          data: {
            'model': selectedModel,
            'messages': [
              {
                'role': 'system',
                'content': 'You are Grok. Provide a single punchy 1-sentence reason why this movie/series fits the user.',
              },
              {
                'role': 'user',
                'content': 'Title: $title ($genres). Recommend it briefly.',
              }
            ],
            'max_tokens': 60,
          },
          options: Options(
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
          ),
        );
        if (response.statusCode == 200 && response.data != null) {
          final choices = response.data!['choices'] as List?;
          if (choices != null && choices.isNotEmpty) {
            final msg = choices.first['message'];
            if (msg != null && msg['content'] != null) {
              return (msg['content'] as String).trim();
            }
          }
        }
      } catch (_) {}
    }

    final genres = item.genres.take(2).join(' & ');
    if (genres.isNotEmpty) {
      return 'Matches your high affinity for $genres and consistent viewing preferences.';
    }
    return 'Recommended based on your calibrated cinematic taste profile.';
  }

  /// Analyzes a user's completed taste profile picks and suggests the top 3-5
  /// home rows and curated collections to enable by default.
  Future<List<PersonalizationRowType>> suggestTopHomeRows(TasteProfile profile) async {
    if (isConfigured) {
      try {
        final lovedTitles = _resolveLovedTitleNames(profile);
        final lovedGenres = profile.explicit.genreRatings.entries
            .where((e) => e.value == TasteRating.love || e.value == TasteRating.like)
            .map((e) => e.key)
            .toList();
        final activeVibes = profile.explicit.selectedMoodIds
            .map((id) => TasteMoodRegistry.getById(id)?.displayName ?? id)
            .toList();

        final availableKeys = PersonalizationRowType.values.map((r) => r.key).toList();

        final prompt = 'Given this user profile:\n'
            '- Loved Titles: ${lovedTitles.take(8).join(", ")}\n'
            '- Loved Genres: ${lovedGenres.take(6).join(", ")}\n'
            '- Moods/Vibes: ${activeVibes.take(6).join(", ")}\n'
            '- Format Preference: ${profile.explicit.viewingPreferences.formatPreference}\n'
            '- Era Preference: ${profile.explicit.viewingPreferences.preferredEra}\n\n'
            'Choose between 3 and 5 of the most fitting recommendation rows/curated collections from this exact list:\n'
            '${availableKeys.join(", ")}\n\n'
            'Respond ONLY with a comma-separated list of the chosen keys, e.g.:\n'
            'recommendedForYou, moodMatch, oscarWinners';

        final response = await _dio.post<Map<String, dynamic>>(
          endpoint,
          data: {
            'model': selectedModel,
            'messages': [
              {
                'role': 'system',
                'content': 'You are a cinephile recommendation AI curator for Voltix. Select 3-5 row keys from the provided list only.',
              },
              {'role': 'user', 'content': prompt},
            ],
            'max_tokens': 100,
            'temperature': 0.3,
          },
          options: Options(
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            sendTimeout: const Duration(seconds: 5),
            receiveTimeout: const Duration(seconds: 5),
          ),
        );

        if (response.statusCode == 200 && response.data != null) {
          final choices = response.data!['choices'] as List?;
          if (choices != null && choices.isNotEmpty) {
            final msg = choices.first['message'];
            if (msg != null && msg['content'] != null) {
              final text = (msg['content'] as String).trim();
              final parsedKeys = text
                  .split(RegExp(r'[,;\n]'))
                  .map((s) => s.trim().replaceAll(RegExp(r'[^a-zA-Z0-9]'), ''))
                  .where((s) => s.isNotEmpty)
                  .toList();
              final matches = <PersonalizationRowType>[];
              for (final k in parsedKeys) {
                final match = PersonalizationRowType.values
                    .where((r) => r.key.toLowerCase() == k.toLowerCase())
                    .firstOrNull;
                if (match != null && !matches.contains(match)) {
                  matches.add(match);
                }
              }
              if (matches.length >= 2) {
                return matches.take(5).toList();
              }
            }
          }
        }
      } catch (e) {
        debugPrint('[GrokTasteAiService] Live AI row suggestion failed: $e. Using local heuristic.');
      }
    }

    return suggestLocalTopHomeRows(profile);
  }

  /// High quality deterministic cinephilic row selection heuristic based on user picks.
  List<PersonalizationRowType> suggestLocalTopHomeRows(TasteProfile profile) {
    final scores = <PersonalizationRowType, double>{
      for (final r in PersonalizationRowType.values) r: 0.0,
    };

    // Baseline recommendation row
    scores[PersonalizationRowType.recommendedForYou] = (scores[PersonalizationRowType.recommendedForYou] ?? 0) + 4.0;
    scores[PersonalizationRowType.newInLibraryMatchesTaste] = (scores[PersonalizationRowType.newInLibraryMatchesTaste] ?? 0) + 2.5;

    final lovedGenres = profile.explicit.genreRatings.entries
        .where((e) => e.value == TasteRating.love || e.value == TasteRating.like)
        .map((e) => e.key.toLowerCase())
        .toList();

    // Prestige / Award genres
    final prestigeGenres = {'drama', 'history', 'biography', 'war', 'crime'};
    if (lovedGenres.any((g) => prestigeGenres.contains(g))) {
      scores[PersonalizationRowType.oscarWinners] = (scores[PersonalizationRowType.oscarWinners] ?? 0) + 5.0;
      scores[PersonalizationRowType.awardSeasonEssentials] = (scores[PersonalizationRowType.awardSeasonEssentials] ?? 0) + 4.0;
      scores[PersonalizationRowType.fromNomineeToWinner] = (scores[PersonalizationRowType.fromNomineeToWinner] ?? 0) + 3.0;
    }

    // Niche / Genre Deep Cuts
    final nicheGenres = {'sci-fi', 'science fiction', 'horror', 'mystery', 'fantasy', 'animation', 'documentary'};
    if (lovedGenres.any((g) => nicheGenres.contains(g))) {
      scores[PersonalizationRowType.genreDeepCuts] = (scores[PersonalizationRowType.genreDeepCuts] ?? 0) + 5.0;
      scores[PersonalizationRowType.hiddenGems] = (scores[PersonalizationRowType.hiddenGems] ?? 0) + 4.0;
    }

    // Popular / Mainstream
    final popGenres = {'action', 'adventure', 'comedy', 'thriller'};
    if (lovedGenres.any((g) => popGenres.contains(g))) {
      scores[PersonalizationRowType.wellKnownTitles] = (scores[PersonalizationRowType.wellKnownTitles] ?? 0) + 3.5;
    }

    // Mood / Atmosphere
    if (profile.explicit.selectedMoods.isNotEmpty || profile.explicit.selectedMoodIds.isNotEmpty) {
      scores[PersonalizationRowType.moodMatch] = (scores[PersonalizationRowType.moodMatch] ?? 0) + 5.5;
    }

    // Format
    final format = profile.explicit.viewingPreferences.formatPreference.toLowerCase();
    final seriesCount = profile.explicit.titleRatings.keys.where((k) => k.startsWith('series_')).length;
    if (format == 'series' || format == 'tv' || seriesCount >= 3) {
      scores[PersonalizationRowType.seriesYouMightBinge] = (scores[PersonalizationRowType.seriesYouMightBinge] ?? 0) + 6.0;
    }

    // Era
    final era = profile.explicit.viewingPreferences.preferredEra.toLowerCase();
    if (era.contains('70') || era.contains('80') || era.contains('90') || era.contains('classic')) {
      scores[PersonalizationRowType.careerMilestones] = (scores[PersonalizationRowType.careerMilestones] ?? 0) + 4.5;
      scores[PersonalizationRowType.beforeTheyWereFamous] = (scores[PersonalizationRowType.beforeTheyWereFamous] ?? 0) + 4.0;
    }

    // Diversity
    if (lovedGenres.length >= 4) {
      scores[PersonalizationRowType.somethingDifferent] = (scores[PersonalizationRowType.somethingDifferent] ?? 0) + 3.0;
    }

    // Sort by score descending
    final ranked = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // Return the top 4 matching rows
    final top = ranked.take(4).map((e) => e.key).toList();
    if (!top.contains(PersonalizationRowType.recommendedForYou) && top.isNotEmpty) {
      top[top.length - 1] = PersonalizationRowType.recommendedForYou;
    }
    return top;
  }
}
