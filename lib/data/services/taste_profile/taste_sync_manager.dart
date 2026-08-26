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

  int minimumStepTransitionDelayMs = 150;

  SyncProgressState _progressState = SyncProgressState(
    currentStep: SyncStep.preparation,
    statusMessage:
        'Retrieving stream choices to personalize your viewing experience. This may take a minute - it will be with the wait.',
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
            'Retrieving stream choices to personalize your viewing experience. This may take a minute - it will be with the wait.',
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

  Future<void> _runSyncPipeline({
    required String serverId,
    required String userId,
    required LanguageSettings languageSettings,
    required SyncCancellationToken token,
  }) async {
    final completed = Set<SyncStep>.from(_progressState.completedSteps);

    try {
      // ────────────────────────────────────────────────────────────────────────
      // Step 1 — Movies
      // ────────────────────────────────────────────────────────────────────────
      if (!completed.contains(SyncStep.movies)) {
        if (token.isCancelled) return;
        _updateProgress(
          step: SyncStep.movies,
          percent: 14.0,
          status:
              'Downloading the goods (faster than Netflix buffering on date night)...',
        );

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

        completed.add(SyncStep.movies);
        _updateProgress(
          step: SyncStep.movies,
          percent: 28.0,
          records: movies.length,
          total: movies.length,
          status: 'Movies indexed successfully.',
          completed: completed,
        );
        await _localStore.saveSyncProgress(
          serverId: serverId,
          userId: userId,
          state: _progressState,
        );
        await _stepTransitionDelay(token);
      }

      // ────────────────────────────────────────────────────────────────────────
      // Step 2 — Series
      // ────────────────────────────────────────────────────────────────────────
      if (!completed.contains(SyncStep.series)) {
        if (token.isCancelled) return;
        _updateProgress(
          step: SyncStep.series,
          percent: 28.0,
          status: "Scouting series that'll ruin your sleep schedule...",
          completed: completed,
        );

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

        completed.add(SyncStep.series);
        _updateProgress(
          step: SyncStep.series,
          percent: 42.0,
          records: series.length,
          total: series.length,
          status: 'Series indexed successfully.',
          completed: completed,
        );
        await _localStore.saveSyncProgress(
          serverId: serverId,
          userId: userId,
          state: _progressState,
        );
        await _stepTransitionDelay(token);
      }

      // ────────────────────────────────────────────────────────────────────────
      // Step 3 — Genres
      // ────────────────────────────────────────────────────────────────────────
      if (!completed.contains(SyncStep.genres)) {
        if (token.isCancelled) return;
        _updateProgress(
          step: SyncStep.genres,
          percent: 42.0,
          status:
              'Genre-bending like a showrunner on their third espresso...',
          completed: completed,
        );

        final genres = await _genreService.discoverServerGenres(
          userId: userId,
          forceRefresh: true,
        );

        if (token.isCancelled) return;
        _cachedServerGenres = genres;

        completed.add(SyncStep.genres);
        _updateProgress(
          step: SyncStep.genres,
          percent: 57.0,
          records: genres.length,
          total: genres.length,
          status: 'Server genres populated.',
          completed: completed,
        );
        await _localStore.saveSyncProgress(
          serverId: serverId,
          userId: userId,
          state: _progressState,
        );
        await _stepTransitionDelay(token);
      }

      // ────────────────────────────────────────────────────────────────────────
      // Step 4 — Viewing Experience Lab
      // ────────────────────────────────────────────────────────────────────────
      if (!completed.contains(SyncStep.viewingLab)) {
        if (token.isCancelled) return;
        _updateProgress(
          step: SyncStep.viewingLab,
          percent: 57.0,
          status: 'Preloading viewing history signals...',
          completed: completed,
        );

        // Preload inferred watch history signals
        final inferred = await _analyzer.analyzeHistory(userId: userId);
        if (token.isCancelled) return;
        _cachedInferredProfile = inferred;

        completed.add(SyncStep.viewingLab);
        _updateProgress(
          step: SyncStep.viewingLab,
          percent: 71.0,
          records: inferred.genreAffinities.length,
          total: inferred.genreAffinities.length,
          status: 'History signals analyzed.',
          completed: completed,
        );
        await _localStore.saveSyncProgress(
          serverId: serverId,
          userId: userId,
          state: _progressState,
        );
        await _stepTransitionDelay(token);
      }

      // ────────────────────────────────────────────────────────────────────────
      // Step 5 — Moods and Vibes
      // ────────────────────────────────────────────────────────────────────────
      if (!completed.contains(SyncStep.moodsAndVibes)) {
        if (token.isCancelled) return;
        _updateProgress(
          step: SyncStep.moodsAndVibes,
          percent: 71.0,
          status: 'Synchronizing mood and vibe taxonomy...',
          completed: completed,
        );

        completed.add(SyncStep.moodsAndVibes);
        _updateProgress(
          step: SyncStep.moodsAndVibes,
          percent: 85.0,
          records: TasteMoodRegistry.categories.length,
          total: 200,
          status: 'Vibe categories prepared.',
          completed: completed,
        );
        await _localStore.saveSyncProgress(
          serverId: serverId,
          userId: userId,
          state: _progressState,
        );
        await _stepTransitionDelay(token);
      }

      // ────────────────────────────────────────────────────────────────────────
      // Step 6 — Perfect Experience
      // ────────────────────────────────────────────────────────────────────────
      if (!completed.contains(SyncStep.perfectExperience)) {
        if (token.isCancelled) return;
        _updateProgress(
          step: SyncStep.perfectExperience,
          percent: 85.0,
          status: 'Finalizing stream retrieval...',
          completed: completed,
        );

        completed.add(SyncStep.perfectExperience);
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
      }
    } catch (e, st) {
      debugPrint('[TasteSyncManager] Sync pipeline failed: $e\n$st');
      _progressState = _progressState.copyWith(
        errorMessage: 'Synchronisation encountered an issue: $e',
        lastUpdatedUtc: DateTime.now().toUtc(),
      );
      notifyListeners();
    }
  }

  Future<void> _stepTransitionDelay(SyncCancellationToken token) async {
    if (token.isCancelled || minimumStepTransitionDelayMs <= 0) return;
    final delayMs = minimumStepTransitionDelayMs;
    const intervalMs = 100;
    int elapsed = 0;
    while (elapsed < delayMs) {
      if (token.isCancelled) return;
      await Future.delayed(const Duration(milliseconds: intervalMs));
      elapsed += intervalMs;
    }
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
              'Genres,PrimaryImageAspectRatio,UserData,CommunityRating,VoteCount,CriticRating,ProductionYear,OfficialRating,RunTimeTicks,OriginalLanguage,MediaStreams,SpokenLanguages,CollectionId,SeriesId,ImageTags,Overview,People,ProviderIds',
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
        _updateProgress(
          step: SyncStep.movies,
          percent: 20.0,
          status:
              'Downloading the goods (faster than Netflix buffering on date night)...',
          failover:
              'Primary server missed a title, checking the backup shelves...',
        );

        for (final failover in failovers) {
          if (token.isCancelled) break;
          final fClient = _serverContext.getClientForServer(failover.serverId);
          if (fClient == null) continue;

          try {
            final fRes = await fClient.itemsApi.getItems(
              recursive: true,
              includeItemTypes: const ['Movie'],
              sortBy: 'CommunityRating,ProductionYear',
              sortOrder: 'Descending',
              fields:
                  'Genres,PrimaryImageAspectRatio,UserData,CommunityRating,VoteCount,CriticRating,ProductionYear,OfficialRating,RunTimeTicks,OriginalLanguage,MediaStreams,SpokenLanguages,CollectionId,SeriesId,ImageTags,Overview,People,ProviderIds',
              limit: 50,
            );
            final fRaw = (fRes['Items'] as List? ?? [])
                .whereType<Map<String, dynamic>>();
            for (final r in fRaw) {
              final item = AggregatedItem(
                id: r['Id']?.toString() ?? '',
                serverId: failover.serverId,
                rawData: r,
              );
              if (item.id.isNotEmpty &&
                  !items.any((i) => i.id == item.id) &&
                  TasteRecommendationEngine.isLanguageAllowed(
                    item: item,
                    languageSettings: languageSettings,
                    isOnboarding: true,
                  )) {
                items.add(item);
              }
            }
          } catch (_) {}
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
              'Genres,PrimaryImageAspectRatio,UserData,CommunityRating,VoteCount,CriticRating,ProductionYear,OfficialRating,RunTimeTicks,OriginalLanguage,MediaStreams,SpokenLanguages,CollectionId,SeriesId,ImageTags,Overview,People,ProviderIds,Status,CumulativeRunTimeTicks',
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
          percent: 35.0,
          status: "Scouting series that'll ruin your sleep schedule...",
          failover:
              'Primary server missed a series, checking the backup shelves...',
        );

        for (final failover in failovers) {
          if (token.isCancelled) break;
          final fClient = _serverContext.getClientForServer(failover.serverId);
          if (fClient == null) continue;

          try {
            final fRes = await fClient.itemsApi.getItems(
              recursive: true,
              includeItemTypes: const ['Series'],
              sortBy: 'CommunityRating,ProductionYear',
              sortOrder: 'Descending',
              fields:
                  'Genres,PrimaryImageAspectRatio,UserData,CommunityRating,VoteCount,CriticRating,ProductionYear,OfficialRating,RunTimeTicks,OriginalLanguage,MediaStreams,SpokenLanguages,CollectionId,SeriesId,ImageTags,Overview,People,ProviderIds',
              limit: 50,
            );
            final fRaw = (fRes['Items'] as List? ?? [])
                .whereType<Map<String, dynamic>>();
            for (final r in fRaw) {
              final item = AggregatedItem(
                id: r['Id']?.toString() ?? '',
                serverId: failover.serverId,
                rawData: r,
              );
              if (item.id.isNotEmpty &&
                  !items.any((i) => i.id == item.id) &&
                  TasteRecommendationEngine.isLanguageAllowed(
                    item: item,
                    languageSettings: languageSettings,
                    isOnboarding: true,
                  )) {
                items.add(item);
              }
            }
          } catch (_) {}
        }
      }
    }

    return items;
  }
}
