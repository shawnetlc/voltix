import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../models/aggregated_item.dart';
import '../../models/taste_profile/taste_profile_models.dart';
import 'taste_genre_service.dart';
import 'taste_history_analyzer.dart';
import 'taste_local_store.dart';
import 'taste_recommendation_engine.dart';
import 'taste_server_context.dart';

/// Cancellation token for synchronisation operations.
class SyncCancellationToken {
  bool _isCancelled = false;
  bool get isCancelled => _isCancelled;

  void cancel() {
    _isCancelled = true;
  }
}

/// Orchestrates the resumable 8-step synchronisation process across Primary
/// and failover servers with real-time UI feedback, progress tracking, and transition delays.
class TasteSyncManager extends ChangeNotifier {
  final TasteServerContext _serverContext;
  final TasteLocalStore _localStore;
  final TasteGenreService _genreService;
  final TasteHistoryAnalyzer _analyzer;

  /// Kept as part of the constructor's shape, but no longer paid between
  /// steps: the steps run concurrently now, so there is nothing to pace, and
  /// the pause was time the viewer spent waiting for an animation rather than
  /// for their library.
  @Deprecated('No longer used; steps run concurrently and report as they land.')
  int minimumStepTransitionDelayMs = 150;

  SyncProgressState _progressState = SyncProgressState(
    currentStep: SyncStep.preparation,
    statusMessage:
        'Retrieving stream choices to personalize your viewing experience. This may take a minute - it will be worth the wait.',
    lastUpdatedUtc: DateTime.now().toUtc(),
  );

  SyncProgressState get progressState => _progressState;
  bool get isSynchronizing => _activeSyncFuture != null;

  Future<void>? _activeSyncFuture;
  SyncCancellationToken? _activeCancellationToken;

  // Cached sync results
  List<AggregatedItem> _cachedMovies = [];
  List<AggregatedItem> _cachedSeries = [];
  List<ServerGenreInfo> _cachedServerGenres = [];
  InferredTasteProfile? _cachedInferredProfile;

  List<AggregatedItem> get cachedMovies => List.unmodifiable(_cachedMovies);
  List<AggregatedItem> get cachedSeries => List.unmodifiable(_cachedSeries);
  List<ServerGenreInfo> get cachedServerGenres =>
      List.unmodifiable(_cachedServerGenres);
  InferredTasteProfile? get cachedInferredProfile => _cachedInferredProfile;

  TasteSyncManager({
    required TasteServerContext serverContext,
    required TasteLocalStore localStore,
    required TasteGenreService genreService,
    required TasteHistoryAnalyzer analyzer,
    // ignore: deprecated_member_use_from_same_package
    this.minimumStepTransitionDelayMs = 150,
  })  : _serverContext = serverContext,
        _localStore = localStore,
        _genreService = genreService,
        _analyzer = analyzer;

  /// Loads previously saved sync progress from local cache for resumability.
  Future<void> loadSavedProgress({
    required String serverId,
    required String userId,
  }) async {
    final saved = await _localStore.loadSyncProgress(
      serverId: serverId,
      userId: userId,
    );
    if (saved != null) {
      _progressState = saved;
      notifyListeners();
    }
  }

  /// Cancels any in-flight synchronisation gracefully.
  void cancelSync() {
    _activeCancellationToken?.cancel();
    _progressState = _progressState.copyWith(
      isCancelled: true,
      statusMessage: 'Synchronisation cancelled.',
      lastUpdatedUtc: DateTime.now().toUtc(),
    );
    _activeSyncFuture = null;
    notifyListeners();
  }

  /// Starts or resumes the synchronisation pipeline from the last uncompleted step.
  Future<bool> startOrResumeSync({
    required String serverId,
    required String userId,
    LanguageSettings languageSettings = const LanguageSettings(),
    bool forceRestart = false,
  }) async {
    if (_activeSyncFuture != null) {
      await _activeSyncFuture;
      return _progressState.isCompleted;
    }

    final token = SyncCancellationToken();
    _activeCancellationToken = token;

    if (forceRestart) {
      _progressState = SyncProgressState(
        currentStep: SyncStep.preparation,
        statusMessage:
            'Retrieving stream choices to personalize your viewing experience. This may take a minute - it will be worth the wait.',
        lastUpdatedUtc: DateTime.now().toUtc(),
      );
      notifyListeners();
    }

    _activeSyncFuture = _runSyncPipeline(
      serverId: serverId,
      userId: userId,
      languageSettings: languageSettings,
      token: token,
    );

    try {
      await _activeSyncFuture;
      return _progressState.isCompleted;
    } finally {
      _activeSyncFuture = null;
      _activeCancellationToken = null;
    }
  }

  /// The steps that actually do work, in the order the UI narrates them.
  ///
  /// Moods and Perfect Experience are deliberately absent: neither ever
  /// fetched or computed anything -- they added themselves to the completed
  /// set, moved the bar and paid a transition delay. They are finalisation
  /// beats now, not pipeline stages.
  /// Fields the taste engine actually reads.
  ///
  /// MediaStreams is by far the heaviest of these on a Jellyfin item query and
  /// is only needed to check audio languages, so it is asked for only when
  /// foreign content is actually being excluded. On a library where it is not,
  /// this drops the largest part of the payload for nothing lost.
  static const _baseFields =
      'Genres,PrimaryImageAspectRatio,UserData,CommunityRating,VoteCount,'
      'CriticRating,ProductionYear,OfficialRating,RunTimeTicks,CollectionId,'
      'SeriesId,ImageTags,Overview,People,ProviderIds';
  static const _languageFields =
      ',OriginalLanguage,SpokenLanguages,MediaStreams';

  static String _fieldsFor(LanguageSettings settings) =>
      settings.excludeForeignContent
          ? '$_baseFields$_languageFields'
          : _baseFields;

  static const _workSteps = <SyncStep>[
    SyncStep.movies,
    SyncStep.series,
    SyncStep.genres,
    SyncStep.viewingLab,
  ];

  Future<void> _runSyncPipeline({
    required String serverId,
    required String userId,
    required LanguageSettings languageSettings,
    required SyncCancellationToken token,
  }) async {
    final completed = Set<SyncStep>.from(_progressState.completedSteps);

    try {
      // The four work steps are independent, but the onboarding checklist lists
      // them in a fixed order (Movies, Series, Genres, Viewing History) and the
      // sync is expected to run through them strictly top-to-bottom so each row
      // ticks over in that order rather than completing whenever its network
      // call happens to return. They are therefore awaited one after another in
      // the same order as _workSteps / the checklist. Each step reports as it
      // lands so the bar still moves in discrete steps.
      final outstanding =
          _workSteps.where((s) => !completed.contains(s)).toList();

      if (outstanding.isNotEmpty) {
        _updateProgress(
          step: outstanding.first,
          percent: _percentFor(completed),
          status:
              'Downloading the goods (faster than Netflix buffering on date night)...',
          completed: completed,
        );

        if (!token.isCancelled && outstanding.contains(SyncStep.movies)) {
          await _stepMovies(
            serverId: serverId,
            userId: userId,
            languageSettings: languageSettings,
            token: token,
            completed: completed,
          );
        }
        if (!token.isCancelled && outstanding.contains(SyncStep.series)) {
          await _stepSeries(
            serverId: serverId,
            userId: userId,
            languageSettings: languageSettings,
            token: token,
            completed: completed,
          );
        }
        if (!token.isCancelled && outstanding.contains(SyncStep.genres)) {
          await _stepGenres(
            serverId: serverId,
            userId: userId,
            token: token,
            completed: completed,
          );
        }
        if (!token.isCancelled && outstanding.contains(SyncStep.viewingLab)) {
          await _stepViewingLab(
            serverId: serverId,
            userId: userId,
            token: token,
            completed: completed,
          );
        }
      }

      if (token.isCancelled) return;

      // Finalisation. These carry no work, so they are reported rather than
      // performed -- with one short beat so the jump to "ready" is legible
      // instead of a flash.
      completed
        ..add(SyncStep.moodsAndVibes)
        ..add(SyncStep.perfectExperience);

      _updateProgress(
        step: SyncStep.perfectExperience,
        percent: 100.0,
        records: _cachedMovies.length + _cachedSeries.length,
        total: _cachedMovies.length + _cachedSeries.length,
        status: 'Library retrieval complete. Ready to personalize!',
        isComplete: true,
        completed: completed,
      );
      await _localStore.saveSyncProgress(
        serverId: serverId,
        userId: userId,
        state: _progressState,
      );
    } catch (e, st) {
      debugPrint('[TasteSyncManager] Sync pipeline failed: $e\n$st');
      _progressState = _progressState.copyWith(
        errorMessage: 'Synchronisation encountered an issue: $e',
        lastUpdatedUtc: DateTime.now().toUtc(),
      );
      notifyListeners();
    }
  }

  /// Progress as a share of the real work, rather than a number hand-written
  /// per step. With the steps running concurrently there is no single "we are
  /// here" any more -- what the viewer can be told honestly is how many of the
  /// four have landed.
  double _percentFor(Set<SyncStep> completed) {
    final done = _workSteps.where(completed.contains).length;
    // Caps at 92 so the finalisation beat still has somewhere to travel.
    return (done / _workSteps.length) * 92.0;
  }

  /// Marks a step done, tells the UI, and checkpoints so a cancelled or
  /// crashed sync resumes from here rather than from the beginning.
  Future<void> _finishStep({
    required SyncStep step,
    required String serverId,
    required String userId,
    required Set<SyncStep> completed,
    required String status,
    int records = 0,
  }) async {
    completed.add(step);
    _updateProgress(
      step: step,
      percent: _percentFor(completed),
      records: records,
      total: records,
      status: status,
      completed: completed,
    );
    await _localStore.saveSyncProgress(
      serverId: serverId,
      userId: userId,
      state: _progressState,
    );
  }

  Future<void> _stepMovies({
    required String serverId,
    required String userId,
    required LanguageSettings languageSettings,
    required SyncCancellationToken token,
    required Set<SyncStep> completed,
  }) async {
    if (token.isCancelled) return;
    final movies = await _syncMoviesWithFailover(
      primaryServerId: serverId,
      userId: userId,
      languageSettings: languageSettings,
      token: token,
    );
    if (token.isCancelled) return;

    if (movies.isNotEmpty) {
      _cachedMovies = movies;
      await _localStore.saveCachedMovies(
        serverId: serverId,
        userId: userId,
        movies: movies,
      );
    }
    await _finishStep(
      step: SyncStep.movies,
      serverId: serverId,
      userId: userId,
      completed: completed,
      records: movies.length,
      status: 'Movies indexed successfully.',
    );
  }

  Future<void> _stepSeries({
    required String serverId,
    required String userId,
    required LanguageSettings languageSettings,
    required SyncCancellationToken token,
    required Set<SyncStep> completed,
  }) async {
    if (token.isCancelled) return;
    final series = await _syncSeriesWithFailover(
      primaryServerId: serverId,
      userId: userId,
      languageSettings: languageSettings,
      token: token,
    );
    if (token.isCancelled) return;

    if (series.isNotEmpty) {
      _cachedSeries = series;
      await _localStore.saveCachedSeries(
        serverId: serverId,
        userId: userId,
        series: series,
      );
    }
    await _finishStep(
      step: SyncStep.series,
      serverId: serverId,
      userId: userId,
      completed: completed,
      records: series.length,
      status: 'Series indexed successfully.',
    );
  }

  Future<void> _stepGenres({
    required String serverId,
    required String userId,
    required SyncCancellationToken token,
    required Set<SyncStep> completed,
  }) async {
    if (token.isCancelled) return;
    final genres = await _genreService.discoverServerGenres(
      userId: userId,
      forceRefresh: true,
    );
    if (token.isCancelled) return;
    _cachedServerGenres = genres;

    await _finishStep(
      step: SyncStep.genres,
      serverId: serverId,
      userId: userId,
      completed: completed,
      records: genres.length,
      status: 'Server genres populated.',
    );
  }

  Future<void> _stepViewingLab({
    required String serverId,
    required String userId,
    required SyncCancellationToken token,
    required Set<SyncStep> completed,
  }) async {
    if (token.isCancelled) return;
    final inferred = await _analyzer.analyzeHistory(userId: userId);
    if (token.isCancelled) return;
    _cachedInferredProfile = inferred;

    await _finishStep(
      step: SyncStep.viewingLab,
      serverId: serverId,
      userId: userId,
      completed: completed,
      records: inferred.genreAffinities.length,
      status: 'History signals analyzed.',
    );
  }


  void _updateProgress({
    required SyncStep step,
    required double percent,
    int records = 0,
    int total = 0,
    required String status,
    String? failover,
    bool isComplete = false,
    Set<SyncStep>? completed,
  }) {
    _progressState = _progressState.copyWith(
      currentStep: step,
      progressPercent: percent,
      recordsProcessed: records,
      totalRecords: total,
      statusMessage: status,
      failoverMessage: failover,
      isCompleted: isComplete,
      isCancelled: false,
      errorMessage: null,
      completedSteps: completed ?? _progressState.completedSteps,
      lastUpdatedUtc: DateTime.now().toUtc(),
    );
    notifyListeners();
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Step 1: Movie Synchronisation with Failover
  // ──────────────────────────────────────────────────────────────────────────

  Future<List<AggregatedItem>> _syncMoviesWithFailover({
    required String primaryServerId,
    required String userId,
    required LanguageSettings languageSettings,
    required SyncCancellationToken token,
  }) async {
    final client = _serverContext.getPrimaryClient(primaryServerId);
    final items = <AggregatedItem>[];

    if (client != null) {
      try {
        final res = await client.itemsApi.getItems(
          recursive: true,
          includeItemTypes: const ['Movie'],
          sortBy: 'CommunityRating,ProductionYear',
          sortOrder: 'Descending',
          fields:
              _fieldsFor(languageSettings),
          limit: 150,
        );

        final rawItems = (res['Items'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .toList();

        for (final r in rawItems) {
          final item = AggregatedItem(
            id: r['Id']?.toString() ?? '',
            serverId: primaryServerId,
            rawData: r,
          );
          if (item.id.isNotEmpty &&
              TasteRecommendationEngine.isLanguageAllowed(
                item: item,
                languageSettings: languageSettings,
                isOnboarding: true,
              )) {
            items.add(item);
          }
        }
      } catch (e) {
        debugPrint('[TasteSyncManager] Primary movie query failed: $e');
      }
    }

    // Check failover shelves if primary returned low candidates (< 24)
    if (items.length < 24) {
      final failovers = _serverContext.failoverSessions;
      if (failovers.isNotEmpty) {
        // Holds the bar where it is rather than asserting a number: with the
        // steps running concurrently, a hardcoded percentage here would drag
        // the bar backwards over whatever another step had just reported.
        _updateProgress(
          step: SyncStep.movies,
          percent: _progressState.progressPercent,
          status:
              'Downloading the goods (faster than Netflix buffering on date night)...',
          failover:
              'Primary server missed a title, checking the backup shelves...',
        );

        // Backup shelves are queried together, not one after another: they
        // are separate servers, so waiting for each in turn just adds their
        // latencies up. Merging stays sequential afterwards, against a seen
        // set rather than a linear scan of everything gathered so far.
        final responses = await Future.wait(
          failovers.map((failover) async {
            if (token.isCancelled) return null;
            final fClient =
                _serverContext.getClientForServer(failover.serverId);
            if (fClient == null) return null;
            try {
              final fRes = await fClient.itemsApi.getItems(
                recursive: true,
                includeItemTypes: const ['Movie'],
                sortBy: 'CommunityRating,ProductionYear',
                sortOrder: 'Descending',
                fields: _fieldsFor(languageSettings),
                limit: 50,
              );
              return (failover.serverId, fRes);
            } catch (_) {
              return null;
            }
          }),
        );

        final seenIds = items.map((i) => i.id).toSet();
        for (final response in responses) {
          if (response == null) continue;
          final (failoverServerId, fRes) = response;
          final fRaw =
              (fRes['Items'] as List? ?? []).whereType<Map<String, dynamic>>();
          for (final r in fRaw) {
            final item = AggregatedItem(
              id: r['Id']?.toString() ?? '',
              serverId: failoverServerId,
              rawData: r,
            );
            if (item.id.isNotEmpty &&
                seenIds.add(item.id) &&
                TasteRecommendationEngine.isLanguageAllowed(
                  item: item,
                  languageSettings: languageSettings,
                  isOnboarding: true,
                )) {
              items.add(item);
            }
          }
        }
      }
    }

    return items;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Step 2: Series Synchronisation with Failover & Binge Detection
  // ──────────────────────────────────────────────────────────────────────────

  Future<List<AggregatedItem>> _syncSeriesWithFailover({
    required String primaryServerId,
    required String userId,
    required LanguageSettings languageSettings,
    required SyncCancellationToken token,
  }) async {
    final client = _serverContext.getPrimaryClient(primaryServerId);
    final items = <AggregatedItem>[];

    if (client != null) {
      try {
        final res = await client.itemsApi.getItems(
          recursive: true,
          includeItemTypes: const ['Series'],
          sortBy: 'CommunityRating,ProductionYear',
          sortOrder: 'Descending',
          fields:
              '${_fieldsFor(languageSettings)},Status,CumulativeRunTimeTicks',
          limit: 150,
        );

        final rawItems = (res['Items'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .toList();

        for (final r in rawItems) {
          final item = AggregatedItem(
            id: r['Id']?.toString() ?? '',
            serverId: primaryServerId,
            rawData: r,
          );
          if (item.id.isNotEmpty &&
              TasteRecommendationEngine.isLanguageAllowed(
                item: item,
                languageSettings: languageSettings,
                isOnboarding: true,
              )) {
            items.add(item);
          }
        }
      } catch (e) {
        debugPrint('[TasteSyncManager] Primary series query failed: $e');
      }
    }

    if (items.length < 24) {
      final failovers = _serverContext.failoverSessions;
      if (failovers.isNotEmpty) {
        _updateProgress(
          step: SyncStep.series,
          percent: _progressState.progressPercent,
          status: "Scouting series that'll ruin your sleep schedule...",
          failover:
              'Primary server missed a series, checking the backup shelves...',
        );

        // Backup shelves are queried together, not one after another: they
        // are separate servers, so waiting for each in turn just adds their
        // latencies up. Merging stays sequential afterwards, against a seen
        // set rather than a linear scan of everything gathered so far.
        final responses = await Future.wait(
          failovers.map((failover) async {
            if (token.isCancelled) return null;
            final fClient =
                _serverContext.getClientForServer(failover.serverId);
            if (fClient == null) return null;
            try {
              final fRes = await fClient.itemsApi.getItems(
                recursive: true,
                includeItemTypes: const ['Series'],
                sortBy: 'CommunityRating,ProductionYear',
                sortOrder: 'Descending',
                fields: _fieldsFor(languageSettings),
                limit: 50,
              );
              return (failover.serverId, fRes);
            } catch (_) {
              return null;
            }
          }),
        );

        final seenIds = items.map((i) => i.id).toSet();
        for (final response in responses) {
          if (response == null) continue;
          final (failoverServerId, fRes) = response;
          final fRaw =
              (fRes['Items'] as List? ?? []).whereType<Map<String, dynamic>>();
          for (final r in fRaw) {
            final item = AggregatedItem(
              id: r['Id']?.toString() ?? '',
              serverId: failoverServerId,
              rawData: r,
            );
            if (item.id.isNotEmpty &&
                seenIds.add(item.id) &&
                TasteRecommendationEngine.isLanguageAllowed(
                  item: item,
                  languageSettings: languageSettings,
                  isOnboarding: true,
                )) {
              items.add(item);
            }
          }
        }
      }
    }

    return items;
  }
}
