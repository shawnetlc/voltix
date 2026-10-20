import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';

import '../../models/taste_profile/taste_profile_models.dart';
import '../../repositories/taste_profile_repository.dart';
import '../voltix_watch_registry_service.dart';
import 'taste_history_analyzer.dart';

/// Learns the viewer's taste from what they actually watch.
///
/// Every film / episode Voltix plays is recorded in the watch registry (local
/// + Azure, per profile) with its genres, cast, directors, studios, year and
/// how much was watched. A short while after the registry changes, this
/// service turns that whole history into the profile's inferred scores
/// (genre / actor / director / studio / era / mood affinities, binge and
/// rewatch tendency, abandoned-genre signals) using the same weighting as the
/// history analyzer: finished > half-watched, recent > old, rewatched and
/// favourites count more, a title stopped under 25 % counts against its
/// genres. The updated profile is saved locally and to Azure, the taste rows
/// are rebuilt and the home screen is told to refresh its taste and genre rows.
///
/// Works from Voltix's own records, so it does not depend on the media server
/// reporting played state (supersilo does not sort/filter reliably).
class TasteLearningService {
  TasteLearningService._();
  static final TasteLearningService instance = TasteLearningService._();

  /// Bumped after each learning pass that changed the profile; the home screen
  /// listens and refreshes its taste / genre rows.
  static final ValueNotifier<int> profileLearned = ValueNotifier<int>(0);

  static const _debounce = Duration(seconds: 45);

  Timer? _timer;
  bool _started = false;
  String _lastSignature = '';

  /// Starts listening to the watch registry (idempotent).
  void start() {
    if (_started) return;
    if (!GetIt.instance.isRegistered<VoltixWatchRegistryService>()) return;
    _started = true;
    GetIt.instance<VoltixWatchRegistryService>().addListener(_onRegistryChanged);
    VoltixWatchRegistryService.restoreTick.addListener(_onRegistryChanged);
    // First pass shortly after start-up (history may have changed on another
    // device and come back from Azure).
    _schedule(const Duration(seconds: 20));
  }

  void _onRegistryChanged() => _schedule(_debounce);

  void _schedule(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(learnNow()));
  }

  /// Recomputes the inferred taste from the full watch history and saves it.
  Future<bool> learnNow() async {
    try {
      final getIt = GetIt.instance;
      if (!getIt.isRegistered<TasteProfileRepository>() ||
          !getIt.isRegistered<VoltixWatchRegistryService>()) {
        return false;
      }
      final repo = getIt<TasteProfileRepository>();
      final profile = repo.currentProfile;
      if (profile == null || profile.status != TasteProfileStatus.completed) {
        return false;
      }
      final entries = getIt<VoltixWatchRegistryService>().allEntries;
      if (entries.isEmpty) return false;

      // Only recompute when the history actually moved (new title, more
      // watched, finished, rewatched).
      final signature = entries
          .map((e) =>
              '${e.contentKey}:${e.progressPercent.round() ~/ 10}:${e.isPlayed}:${e.playCount}')
          .join('|');
      if (signature == _lastSignature) return false;

      final played = <Map<String, dynamic>>[];
      final resume = <Map<String, dynamic>>[];
      for (final e in entries) {
        final raw = _toItem(e);
        if (e.isPlayed || e.progressPercent >= 5) played.add(raw);
        if (!e.isPlayed && e.progressPercent > 0) resume.add(raw);
      }
      if (played.isEmpty) {
        _lastSignature = signature;
        return false;
      }

      final learned = TasteHistoryAnalyzer.computeInferredProfile(
        playedItems: played,
        favoriteItems: const [],
        resumeItems: resume,
        halfLifeDays: 180,
      );
      final merged = _blend(profile.inferred, learned);
      await repo.saveProfile(profile.copyWith(
        inferred: merged,
        // Taste profile always roams with the account (reinstall / new device).
        azureBackupEnabled: true,
      ));
      _lastSignature = signature;
      try {
        repo.rowBuilder.invalidate();
      } catch (_) {}
      profileLearned.value++;
      debugPrint('[TasteLearning] Profile updated from ${played.length} watched titles');
      return true;
    } catch (e) {
      debugPrint('[TasteLearning] skipped: $e');
      return false;
    }
  }

  /// Watch record -> the item shape the history analyzer reads.
  static Map<String, dynamic> _toItem(WatchRegistryEntry e) => {
        'Id': e.itemId,
        'Name': e.name,
        'Type': e.type,
        'SeriesId': e.seriesId,
        'ProductionYear': e.year,
        'Genres': e.genres,
        'Studios': [for (final s in e.studios) {'Name': s}],
        'People': [
          // Top-billed cast carries the signal; long tails are noise.
          for (final a in e.actors.take(8)) {'Name': a, 'Type': 'Actor'},
          for (final d in e.directors) {'Name': d, 'Type': 'Director'},
        ],
        'UserData': {
          'Played': e.isPlayed,
          'PlayCount': e.playCount < 1 ? 1 : e.playCount,
          'PlayedPercentage': e.isPlayed ? 100.0 : e.progressPercent,
          'LastPlayedDate': e.lastWatchedAt.toUtc().toIso8601String(),
        },
      };

  /// What the viewer watches leads (70 %); what the server history / earlier
  /// analysis found keeps a share (30 %) so a single film doesn't swing it.
  static InferredTasteProfile _blend(
    InferredTasteProfile old,
    InferredTasteProfile learned,
  ) {
    Map<String, double> mix(Map<String, double> a, Map<String, double> b,
        {int max = 60}) {
      final out = <String, double>{};
      for (final k in {...a.keys, ...b.keys}) {
        out[k] = (a[k] ?? 0) * 0.3 + (b[k] ?? 0) * 0.7;
      }
      final top = out.entries.toList()
        ..sort((x, y) => y.value.compareTo(x.value));
      return {for (final e in top.take(max)) e.key: e.value};
    }

    return InferredTasteProfile(
      genreAffinities: mix(old.genreAffinities, learned.genreAffinities),
      actorAffinities: mix(old.actorAffinities, learned.actorAffinities, max: 60),
      directorAffinities:
          mix(old.directorAffinities, learned.directorAffinities, max: 30),
      studioAffinities: mix(old.studioAffinities, learned.studioAffinities, max: 30),
      moodAffinities: mix(old.moodAffinities, learned.moodAffinities),
      eraAffinities: mix(old.eraAffinities, learned.eraAffinities),
      bingeScore: old.bingeScore * 0.3 + learned.bingeScore * 0.7,
      rewatchScore: old.rewatchScore * 0.3 + learned.rewatchScore * 0.7,
      negativeGenreSignals: learned.negativeGenreSignals,
      negativePeopleSignals: learned.negativePeopleSignals,
      computedAt: DateTime.now(),
    );
  }
}
