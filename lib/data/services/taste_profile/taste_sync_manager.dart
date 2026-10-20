import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../models/aggregated_item.dart';
import '../../models/taste_profile/taste_profile_models.dart';
import 'taste_genre_service.dart';
import 'taste_history_analyzer.dart';
import 'taste_local_store.dart';
import 'taste_recommendation_engine.dart';
import 'taste_server_context.dart';
import 'package:server_core/server_core.dart';
import 'foreign_content_filter.dart';

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

  /// True while a sync is actually running (not merely incomplete).
  bool get isSyncing => _activeSyncFuture != null;

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
      'SeriesId,ImageTags,Overview,ProviderIds,ProductionLocations'; // no People: very slow on big servers
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

        // All four fetches start NOW, together - movies, series, genres and
        // viewing history are independent server queries, and on a slow
        // Lumistream server each can take 10-20 s. Run one after another they
        // added up to over a minute, so "Continue to Movies" opened an empty
        // page. The checklist still ticks over top-to-bottom: each result is
        // recorded in order as soon as it (and everything above it) is in.
        final moviesFuture = outstanding.contains(SyncStep.movies)
            ? _syncMoviesWithFailover(
                primaryServerId: serverId,
                userId: userId,
                languageSettings: languageSettings,
                token: token,
              ).catchError((Object e) {
                debugPrint('[TasteSyncManager] Movies fetch failed: $e');
                return <AggregatedItem>[];
              })
            : null;
        final seriesFuture = outstanding.contains(SyncStep.series)
            ? _syncSeriesWithFailover(
                primaryServerId: serverId,
                userId: userId,
                languageSettings: languageSettings,
                token: token,
              ).catchError((Object e) {
                debugPrint('[TasteSyncManager] Series fetch failed: $e');
                return <AggregatedItem>[];
              })
            : null;
        final genresFuture = outstanding.contains(SyncStep.genres)
            ? _genreService
                .discoverServerGenres(userId: userId, forceRefresh: true)
                .catchError((Object e) {
                debugPrint('[TasteSyncManager] Genre discovery failed: $e');
                return _cachedServerGenres;
              })
            : null;
        final historyFuture = outstanding.contains(SyncStep.viewingLab)
            ? _analyzer.analyzeHistory(userId: userId)
            : null;

        if (!token.isCancelled && moviesFuture != null) {
          await _stepMovies(
            serverId: serverId,
            userId: userId,
            languageSettings: languageSettings,
            token: token,
            completed: completed,
            prefetched: moviesFuture,
          );
        }
        if (!token.isCancelled && seriesFuture != null) {
          await _stepSeries(
            serverId: serverId,
            userId: userId,
            languageSettings: languageSettings,
            token: token,
            completed: completed,
            prefetched: seriesFuture,
          );
        }
        if (!token.isCancelled && genresFuture != null) {
          await _stepGenres(
            serverId: serverId,
            userId: userId,
            token: token,
            completed: completed,
            prefetched: genresFuture,
          );
        }
        if (!token.isCancelled && historyFuture != null) {
          await _stepViewingLab(
            serverId: serverId,
            userId: userId,
            token: token,
            completed: completed,
            prefetched: historyFuture,
          );
        }
      }

      if (token.isCancelled) return;

      // Finalisation. These carry no work, so they are reported rather than
      // performed -- with one short beat so the jump to "ready" is legible
      // instead of a flash.
      // Only "complete" once both libraries actually arrived; otherwise the
      // saved state would stop every later visit from retrying.
      final librariesIn = completed.contains(SyncStep.movies) &&
          completed.contains(SyncStep.series);
      if (!librariesIn) {
        _updateProgress(
          step: completed.contains(SyncStep.movies)
              ? SyncStep.series
              : SyncStep.movies,
          percent: _percentFor(completed),
          status: 'Some titles could not be loaded yet - will retry.',
          completed: completed,
        );
        await _localStore.saveSyncProgress(
          serverId: serverId,
          userId: userId,
          state: _progressState,
        );
        return;
      }

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
    Future<List<AggregatedItem>>? prefetched,
  }) async {
    if (token.isCancelled) return;
    final movies = await (prefetched ??
        _syncMoviesWithFailover(
          primaryServerId: serverId,
          userId: userId,
          languageSettings: languageSettings,
          token: token,
        ));
    if (token.isCancelled) return;

    if (movies.isEmpty) {
      // Nothing came back (slow server timed out, or an error). Leave the
      // step outstanding so the next wizard visit fetches again -- marking it
      // done here saved an empty "completed" sync that the wizard then never
      // retried, which is why it showed no movies at all.
      _updateProgress(
        step: SyncStep.movies,
        percent: _percentFor(completed),
        status: 'No movies received yet - will retry.',
        completed: completed,
      );
      return;
    }
    _cachedMovies = movies;
    await _localStore.saveCachedMovies(
      serverId: serverId,
      userId: userId,
      movies: movies,
    );
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
    Future<List<AggregatedItem>>? prefetched,
  }) async {
    if (token.isCancelled) return;
    final series = await (prefetched ??
        _syncSeriesWithFailover(
          primaryServerId: serverId,
          userId: userId,
          languageSettings: languageSettings,
          token: token,
        ));
    if (token.isCancelled) return;

    if (series.isEmpty) {
      // See _stepMovies: an empty result must not be saved as completed.
      _updateProgress(
        step: SyncStep.series,
        percent: _percentFor(completed),
        status: 'No series received yet - will retry.',
        completed: completed,
      );
      return;
    }
    _cachedSeries = series;
    await _localStore.saveCachedSeries(
      serverId: serverId,
      userId: userId,
      series: series,
    );
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
    Future<List<ServerGenreInfo>>? prefetched,
  }) async {
    if (token.isCancelled) return;
    final genres = await (prefetched ??
        _genreService.discoverServerGenres(
          userId: userId,
          forceRefresh: true,
        ));
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
    Future<InferredTasteProfile>? prefetched,
  }) async {
    if (token.isCancelled) return;
    final inferred = await (prefetched ?? _analyzer.analyzeHistory(userId: userId));
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
      items.addAll(await _fetchItemsPerLibrary(
        client: client,
        serverId: primaryServerId,
        includeType: 'Movie',
        collectionType: 'movies',
        fields: _fieldsFor(languageSettings),
        languageSettings: languageSettings,
        token: token,
        totalLimit: 300,
      ));
    }

    // Check failover shelves if primary returned low candidates (< 24)
    if (items.length < 24) {
      final failovers = _serverContext.failoverSessions;
      if (failovers.isNotEmpty) {
        _updateProgress(
          step: SyncStep.movies,
          percent: _progressState.progressPercent,
          status:
              'Downloading the goods (faster than Netflix buffering on date night)...',
          failover:
              'Primary server missed a title, checking the backup shelves...',
        );

        final responses = await Future.wait(
          failovers.map((failover) async {
            if (token.isCancelled) return null;
            final fClient =
                _serverContext.getClientForServer(failover.serverId);
            if (fClient == null) return null;
            final list = await _fetchItemsPerLibrary(
              client: fClient,
              serverId: failover.serverId,
              includeType: 'Movie',
              collectionType: 'movies',
              fields: _fieldsFor(languageSettings),
              languageSettings: languageSettings,
              token: token,
              totalLimit: 50,
            );
            return (failover.serverId, list);
          }),
        );

        final seenIds = items.map((i) => i.id).toSet();
        for (final response in responses) {
          if (response == null) continue;
          final (_, list) = response;
          for (final item in list) {
            if (seenIds.add(item.id)) items.add(item);
          }
        }
      }
    }

    return items;
  }

  /// Fetches items of [includeType] by enumerating the user's libraries and
  /// querying each one scoped by `parentId`.
  ///
  /// Restrictive providers (e.g. a direct Lumistream connection) reject or
  /// return nothing for an unscoped recursive query, while a per-library query
  /// works -- so the taste sync always walks the libraries one by one. Falls
  /// back to querying every view when the server does not label collection
  /// types.
  /// Best-rated first, as the old server-side CommunityRating sort gave --
  /// but done here, because sorting a whole library by rating on the server
  /// timed out (90 s) and left the wizard empty.
  static List<AggregatedItem> _rankByRating(List<AggregatedItem> items) {
    double r(AggregatedItem i) =>
        (i.rawData['CommunityRating'] as num?)?.toDouble() ?? 0.0;
    return List<AggregatedItem>.from(items)..sort((a, b) => r(b).compareTo(r(a)));
  }

  Future<List<AggregatedItem>> _fetchItemsPerLibrary({
    required MediaServerClient client,
    required String serverId,
    required String includeType,
    required String collectionType,
    required String fields,
    required LanguageSettings languageSettings,
    required SyncCancellationToken token,
    required int totalLimit,
  }) async {
    final items = <AggregatedItem>[];
    final seen = <String>{};
    // Foreign-language libraries (e.g. "Movies International") never feed the
    // taste wizard; see ForeignContentFilter.
    // Library list only (one quick call); excluded libraries are simply not read.
    final foreign = await ForeignContentFilter.loadViews(client);

    void addAll(Iterable<Map<String, dynamic>> raw) {
      for (final r in raw) {
        r.putIfAbsent('ProductionLocations', () => const <String>[]);
        if (items.length >= totalLimit) break;
        final item = AggregatedItem(
          id: r['Id']?.toString() ?? '',
          serverId: serverId,
          rawData: r,
        );
        if (item.id.isNotEmpty &&
            !foreign.isForeign(item.id) &&
            !ForeignContentFilter.isExcludedItem(r) &&
            seen.add(item.id) &&
            TasteRecommendationEngine.isLanguageAllowed(
              item: item,
              languageSettings: languageSettings,
              isOnboarding: true,
            )) {
          items.add(item);
        }
      }
    }

    // One server-wide query first (a single request); libraries one by one
    // only when that returns nothing. With foreign libraries present, go
    // straight to the non-foreign libraries so the list isn't mostly dropped.
    if (!foreign.hasForeignLibraries) {
    try {
      final res = await client.itemsApi.getItems(
        recursive: true,
        includeItemTypes: [includeType],
        sortBy: 'DateCreated', // fast; ranked by rating on device (a library-wide rating sort stalls the wizard)
        sortOrder: 'Descending',
        fields: fields,
        limit: totalLimit,
      ).timeout(const Duration(seconds: 30));
      addAll((res['Items'] as List? ?? []).whereType<Map<String, dynamic>>());
      if (items.isNotEmpty) return _rankByRating(items);
    } catch (e) {
      debugPrint('[TasteSyncManager] server-wide $includeType query failed, trying per library: $e');
    }
    }

    final views = foreign.views;
    var targets = foreign.englishViews(collectionType);
    if (targets.isEmpty) {
      targets = views
          .where((v) =>
              !ForeignContentFilter.isForeignLibraryName(v['Name']?.toString()))
          .toList();
    }

    for (final view in targets) {
      if (token.isCancelled) break;
      if (items.length >= totalLimit) break;
      final parentId = view['Id']?.toString();
      if (parentId == null || parentId.isEmpty) continue;
      try {
        final res = await client.itemsApi.getItems(
          parentId: parentId,
          recursive: true,
          includeItemTypes: [includeType],
          sortBy: 'DateCreated', // fast; ranked by rating on device (a library-wide rating sort stalls the wizard)
          sortOrder: 'Descending',
          fields: fields,
          limit: totalLimit,
        ).timeout(const Duration(seconds: 30));
        final raw =
            (res['Items'] as List? ?? []).whereType<Map<String, dynamic>>();
        for (final r in raw) {
          r.putIfAbsent('ProductionLocations', () => const <String>[]);
          if (items.length >= totalLimit) break;
          final item = AggregatedItem(
            id: r['Id']?.toString() ?? '',
            serverId: serverId,
            rawData: r,
          );
          if (item.id.isNotEmpty &&
              !foreign.isForeign(item.id) &&
              !ForeignContentFilter.isExcludedItem(r) &&
              seen.add(item.id) &&
              TasteRecommendationEngine.isLanguageAllowed(
                item: item,
                languageSettings: languageSettings,
                isOnboarding: true,
              )) {
            items.add(item);
          }
        }
      } catch (e) {
        debugPrint(
            '[TasteSyncManager] per-library query failed ($includeType, parent=$parentId): $e');
      }
    }

    return _rankByRating(items);
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
    final seriesFields =
        '${_fieldsFor(languageSettings)},Status,CumulativeRunTimeTicks';

    if (client != null) {
      items.addAll(await _fetchItemsPerLibrary(
        client: client,
        serverId: primaryServerId,
        includeType: 'Series',
        collectionType: 'tvshows',
        fields: seriesFields,
        languageSettings: languageSettings,
        token: token,
        totalLimit: 300,
      ));
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

        final responses = await Future.wait(
          failovers.map((failover) async {
            if (token.isCancelled) return null;
            final fClient =
                _serverContext.getClientForServer(failover.serverId);
            if (fClient == null) return null;
            final list = await _fetchItemsPerLibrary(
              client: fClient,
              serverId: failover.serverId,
              includeType: 'Series',
              collectionType: 'tvshows',
              fields: seriesFields,
              languageSettings: languageSettings,
              token: token,
              totalLimit: 50,
            );
            return (failover.serverId, list);
          }),
        );

        final seenIds = items.map((i) => i.id).toSet();
        for (final response in responses) {
          if (response == null) continue;
          final (_, list) = response;
          for (final item in list) {
            if (seenIds.add(item.id)) items.add(item);
          }
        }
      }
    }

    return items;
  }

}
