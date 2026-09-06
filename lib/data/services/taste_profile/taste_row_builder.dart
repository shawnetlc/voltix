import 'package:flutter/foundation.dart';

import '../../models/aggregated_item.dart';
import '../../models/taste_profile/taste_profile_models.dart';
import '../../utils/bounded_concurrency.dart';
import 'taste_awards_index.dart';
import 'taste_candidate_service.dart';
import 'taste_recommendation_engine.dart';
import 'taste_seed_registry.dart';
import 'taste_server_context.dart';

/// Builds one personalization home row end to end: profile in, ranked
/// [RecommendationItem]s out.
///
/// This is the producer that was missing. `loadTasteProfileSingleRow` read a
/// cache under `taste_profile_{serverId}_{rowKey}` while the only writer used
/// `sinceYouWatched{n}` — different namespaces, so the lookup could never hit
/// and every taste row resolved to an empty list. Writer and reader now live
/// in the same place, which is what makes the key correct by construction
/// rather than by coincidence.
///
/// The scoring itself is untouched: [TasteRecommendationEngine] already owns
/// it, including the disliked-item, negative-signal, already-watched and
/// language filters. This class decides which candidates each row asks for and
/// which engine entry point scores them.
class TasteRowBuilder {
  TasteRowBuilder(
    this._candidates,
    this._seeds,
    this._serverContext,
    this._awards,
  );

  final TasteCandidateService _candidates;
  final TasteSeedRegistry _seeds;
  final TasteServerContext _serverContext;
  final TasteAwardsIndex _awards;

  /// Built rows, keyed exactly as the loader reads them.
  final Map<String, _CachedRow> _cache = {};

  /// Rows go stale on signal (playback finished, feedback recorded) rather
  /// than only on a clock, but a ceiling stops a quiet session from serving
  /// yesterday's row forever.
  static const _ttl = Duration(hours: 6);

  /// Candidate headroom. The engine scores this pool down to [rowLimit], so a
  /// pool roughly three times the row gives it something to choose between.
  static const _candidateLimit = 60;
  static const _rowLimit = 20;

  /// Rows shown on the home screen at once.
  static const defaultMaxHomeRows = 6;

  /// Rows built simultaneously. Each one issues several server queries, so
  /// this is the real throttle on a cold home screen.
  static const _buildConcurrency = 3;

  /// Items averaged into a row's score — roughly a screenful.
  static const _scoreSampleSize = 5;

  /// The cache key. Public because the loader in RowDataSource writes its
  /// compatibility mirror under the same string — one definition, one place
  /// to change it.
  static String cacheKey(String serverId, PersonalizationRowType rowType) =>
      'taste_profile_${serverId}_${rowType.key}';

  /// Rows whose generators are not written yet. They return empty rather than
  /// throwing, so the home screen simply omits them.
  /// Rows that need real awards data. They resolve to empty when no awards
  /// source is configured, rather than falling back to guessing from a
  /// title's overview text.
  static const _needsAwards = <PersonalizationRowType>{
    PersonalizationRowType.oscarWinners,
    PersonalizationRowType.fromNomineeToWinner,
    PersonalizationRowType.awardSeasonEssentials,
  };

  /// Builds [rowType] for [profile], or serves a fresh cached copy.
  ///
  /// Never throws: a row that cannot be built is a row the home screen leaves
  /// out, which is the correct degradation.
  Future<List<RecommendationItem>> buildRow({
    required TasteProfile profile,
    required PersonalizationRowType rowType,
    String? serverId,
    bool forceRefresh = false,
  }) async {
    final targetServerId = serverId ?? profile.serverId;
    final key = cacheKey(targetServerId, rowType);

    if (!forceRefresh) {
      final cached = _cache[key];
      if (cached != null && !cached.isStale(_ttl)) return cached.items;
    }

    try {
      if (rowType == PersonalizationRowType.becauseYouWatched) {
        return _buildSeededRow(
          profile: profile,
          serverId: targetServerId,
          key: key,
        );
      }

      final candidates = await _candidates.fetchCandidates(
        profile: profile,
        spec: _specFor(rowType, profile),
        serverId: targetServerId,
      );
      if (candidates.isEmpty) return const [];

      var library = candidates.map((c) => c.item).toList(growable: false);

      if (_needsAwards.contains(rowType)) {
        library = await _filterByAwards(rowType, library);
        if (library.isEmpty) return const [];
      }

      final scored = _score(rowType, library, profile);

      final row = TasteRecommendationEngine.diversifyRecommendations(
        scored,
        limit: profile.maxItemsPerRow > 0 ? profile.maxItemsPerRow : _rowLimit,
      );

      final withServers = _stampCrossServer(row, candidates);
      _cache[key] = _CachedRow(withServers, DateTime.now());
      return withServers;
    } catch (e) {
      debugPrint('[TasteRowBuilder] ${rowType.key} failed: $e');
      return const [];
    }
  }

  /// Narrows a candidate pool to titles that actually won or were nominated.
  ///
  /// This replaces what the award rows used to do, which was search a title's
  /// overview text for the word "oscar". That found films *about* the Academy
  /// Awards and missed almost every film that won one -- a guess wearing the
  /// costume of data. Returning empty when no awards source is configured is
  /// deliberate: an empty row is honest, a heuristic row is not.
  Future<List<AggregatedItem>> _filterByAwards(
    PersonalizationRowType rowType,
    List<AggregatedItem> library,
  ) async {
    final records = await _awards.recordsFor(library);
    if (records.isEmpty) return const [];

    bool qualifies(AwardRecord r) => switch (rowType) {
      PersonalizationRowType.oscarWinners => r.wonOscar,
      PersonalizationRowType.fromNomineeToWinner => r.nominatedForOscar,
      PersonalizationRowType.awardSeasonEssentials => r.isAwardSeasonContender,
      _ => r.hasAnyAward,
    };

    return library
        .where((item) {
          final record = records[item.id];
          return record != null && qualifies(record);
        })
        .toList(growable: false);
  }

  /// "Because you watched X": neighbours of one recently finished title,
  /// re-ranked against the profile.
  ///
  /// The difference from the Voltix Recommends row it sits beside is the
  /// ranking, not the source. That row answers "what is like this"; this one
  /// answers "what would you like, given you watched this" -- the same
  /// neighbours, ordered by taste rather than by similarity. Both draw seeds
  /// through [TasteSeedRegistry], which is what stops them landing on the
  /// same title.
  Future<List<RecommendationItem>> _buildSeededRow({
    required TasteProfile profile,
    required String serverId,
    required String key,
  }) async {
    final client = _serverContext.getPrimaryClient(serverId);
    if (client == null) return const [];

    final seed = await _seeds.claimSeed(client: client, serverId: serverId);
    if (seed == null) return const [];

    try {
      final res = await client.itemsApi.getSimilarItems(
        seed.id,
        limit: _candidateLimit,
      );
      final raw = (res['Items'] as List? ?? []).whereType<Map<String, dynamic>>();

      final neighbours = <AggregatedItem>[];
      for (final r in raw) {
        final id = r['Id']?.toString() ?? '';
        if (id.isEmpty || id == seed.id) continue;
        neighbours.add(
          AggregatedItem(id: id, serverId: serverId, rawData: r),
        );
      }
      if (neighbours.isEmpty) {
        // Nothing to show, so give the seed back rather than holding a claim
        // that produced no row.
        _seeds.release(seed.id);
        return const [];
      }

      final scored = TasteRecommendationEngine.scoreItems(
        candidates: neighbours,
        profile: profile,
      );
      final row = TasteRecommendationEngine.diversifyRecommendations(
        scored,
        limit: profile.maxItemsPerRow > 0 ? profile.maxItemsPerRow : _rowLimit,
      );
      if (row.isEmpty) {
        _seeds.release(seed.id);
        return const [];
      }

      _cache[key] = _CachedRow(
        row,
        DateTime.now(),
        title: 'Because you watched ${seed.name}',
      );
      return row;
    } catch (e) {
      debugPrint('[TasteRowBuilder] seeded row failed: $e');
      _seeds.release(seed.id);
      return const [];
    }
  }

  /// Records which servers hold each recommended title.
  ///
  /// The scorer builds RecommendationItems before anything knows the title is
  /// also on another server, so availability is stamped on afterwards. Without
  /// this the cross-server fields would always read "only my own server", and
  /// playback would have no failover to fall back to even when one exists.
  List<RecommendationItem> _stampCrossServer(
    List<RecommendationItem> row,
    List<TasteCandidate> candidates,
  ) {
    if (row.isEmpty) return row;

    final serversByItemId = <String, List<String>>{};
    for (final c in candidates) {
      if (c.availableServerIds.length > 1) {
        serversByItemId[c.item.id] = c.availableServerIds;
      }
    }
    if (serversByItemId.isEmpty) return row;

    return row.map((rec) {
      final servers = serversByItemId[rec.item.id];
      if (servers == null) return rec;
      return rec.copyWith(
        availableServerIds: servers,
        selectedServerId: servers.first,
      );
    }).toList(growable: false);
  }

  /// Every personalization row worth showing, strongest first.
  ///
  /// Rows are built with bounded concurrency rather than all at once: eleven
  /// rows firing five queries each would put fifty-odd requests on the server
  /// in one go, and the point of the per-row cache is that this cost is paid
  /// occasionally, not on every home load.
  Future<List<TasteHomeRow>> buildHomeRows({
    required TasteProfile profile,
    String? serverId,
    int maxRows = defaultMaxHomeRows,
    bool forceRefresh = false,
  }) async {
    if (profile.status != TasteProfileStatus.completed) return const [];

    final wanted = _enabledRows(profile);
    if (wanted.isEmpty) return const [];

    final built = await mapBounded<PersonalizationRowType, TasteHomeRow>(
      wanted,
      _buildConcurrency,
      (rowType) async {
        final items = await buildRow(
          profile: profile,
          rowType: rowType,
          serverId: serverId,
          forceRefresh: forceRefresh,
        );
        if (items.isEmpty) return null;
        return TasteHomeRow(
          rowType: rowType,
          items: items,
          score: _rowScore(items),
          titleOverride: _cache[cacheKey(serverId ?? profile.serverId, rowType)]
              ?.title,
        );
      },
    );

    final rows = built.whereType<TasteHomeRow>().toList();
    _applyOrder(rows, profile.rowOrder);
    return rows.take(maxRows).toList(growable: false);
  }

  /// How strongly a row matches this profile: the mean score of the few items
  /// the viewer actually sees before scrolling.
  ///
  /// Averaging the whole row would let a long tail of weak matches drag down a
  /// row with an excellent opening, which is the opposite of how a row is
  /// judged on screen.
  static double _rowScore(List<RecommendationItem> items) {
    if (items.isEmpty) return 0;
    final head = items.take(_scoreSampleSize);
    return head.map((i) => i.score).reduce((a, b) => a + b) / head.length;
  }

  /// Rows the profile has switched on, in enum order.
  ///
  /// Absent means disabled (false): rows only show when explicitly curated
  /// by AI during onboarding or enabled by the user in settings.
  List<PersonalizationRowType> _enabledRows(TasteProfile profile) {
    return PersonalizationRowType.values
        .where((r) => profile.enabledHomeRows[r.key] ?? false)
        .toList();
  }

  /// Score decides the running order, except where the viewer has said
  /// otherwise: any row named in [rowOrder] keeps the position they gave it,
  /// and the rest fall in behind by score. An explicit choice should not be
  /// overridden by a heuristic.
  static void _applyOrder(List<TasteHomeRow> rows, List<String> rowOrder) {
    rows.sort((a, b) {
      final ia = rowOrder.indexOf(a.rowType.key);
      final ib = rowOrder.indexOf(b.rowType.key);
      if (ia >= 0 && ib >= 0) return ia.compareTo(ib);
      if (ia >= 0) return -1;
      if (ib >= 0) return 1;
      return b.score.compareTo(a.score);
    });
  }

  /// Drops cached rows so the next build refetches.
  ///
  /// [rowTypes] narrows the invalidation: finishing an episode moves the binge
  /// and mood rows, not Oscar Winners, and rebuilding all fourteen on every
  /// playback would be a lot of server traffic for no change.
  void invalidate({
    String? serverId,
    Set<PersonalizationRowType>? rowTypes,
  }) {
    if (serverId == null && rowTypes == null) {
      _cache.clear();
      return;
    }
    _cache.removeWhere((key, _) {
      final matchesServer = serverId == null || key.contains(serverId);
      final matchesRow = rowTypes == null ||
          rowTypes.any((r) => key.endsWith('_${r.key}'));
      return matchesServer && matchesRow;
    });
  }

  // ─────────────────────────────── candidates ───────────────────────────────

  /// What each row asks the server for.
  ///
  /// The signals are chosen per row intent rather than handing every row the
  /// same pool: Genre Deep Cuts wants genres, Career Milestones wants people,
  /// and Something Different deliberately wants none so it can reach outside
  /// the profile's comfort zone.
  TasteCandidateSpec _specFor(
    PersonalizationRowType rowType,
    TasteProfile profile,
  ) {
    switch (rowType) {
      case PersonalizationRowType.recommendedForYou:
        return const TasteCandidateSpec(
          limit: _candidateLimit,
          signals: {
            TasteSignal.genres,
            TasteSignal.people,
            TasteSignal.studios,
          },
        );

      case PersonalizationRowType.seriesYouMightBinge:
        return const TasteCandidateSpec(
          itemTypes: ['Series'],
          limit: _candidateLimit,
          signals: {TasteSignal.genres},
        );

      case PersonalizationRowType.moodMatch:
        return TasteCandidateSpec(
          limit: _candidateLimit,
          signals: const {},
          extraGenres: _genresForMoods(profile.explicit.selectedMoods),
        );

      case PersonalizationRowType.hiddenGems:
      case PersonalizationRowType.genreDeepCuts:
        return const TasteCandidateSpec(
          limit: _candidateLimit,
          signals: {TasteSignal.genres},
        );

      case PersonalizationRowType.newInLibraryMatchesTaste:
        return TasteCandidateSpec(
          limit: _candidateLimit,
          signals: const {TasteSignal.genres},
          sortBy: 'DateCreated',
          addedAfter: DateTime.now().subtract(const Duration(days: 45)),
        );

      case PersonalizationRowType.fromNomineeToWinner:
      case PersonalizationRowType.careerMilestones:
        return const TasteCandidateSpec(
          limit: _candidateLimit,
          signals: {TasteSignal.people},
        );

      case PersonalizationRowType.wellKnownTitles:
      case PersonalizationRowType.oscarWinners:
        // Broad popularity pools: both rows are about titles that are widely
        // known, so narrowing by the profile first would work against them.
        return const TasteCandidateSpec(
          limit: _candidateLimit,
          signals: {},
        );

      case PersonalizationRowType.somethingDifferent:
        // Deliberately unfiltered by affinity — the row exists to leave the
        // profile's usual territory, and the generator handles the contrast.
        return const TasteCandidateSpec(
          limit: _candidateLimit,
          signals: {},
        );

      case PersonalizationRowType.beforeTheyWereFamous:
        // Their early work: the same people, oldest first.
        return const TasteCandidateSpec(
          limit: _candidateLimit,
          signals: {TasteSignal.people},
          sortBy: 'PremiereDate',
          sortOrder: 'Ascending',
        );

      case PersonalizationRowType.becauseYouWatched:
        // Candidates come from the seed's own neighbours, not from a profile
        // query -- see _buildSeededRow.
        return const TasteCandidateSpec(limit: _candidateLimit);

      case PersonalizationRowType.awardSeasonEssentials:
        // Broad pool, narrowed afterwards by the awards index. A wider net
        // matters here because contenders are a thin slice of any library.
        return const TasteCandidateSpec(
          limit: _candidateLimit * 2,
          signals: {},
        );
    }
  }

  // ──────────────────────────────── scoring ─────────────────────────────────

  List<RecommendationItem> _score(
    PersonalizationRowType rowType,
    List<AggregatedItem> library,
    TasteProfile profile,
  ) {
    switch (rowType) {
      // Oscar Winners and From Nominee to Winner are already filtered to real
      // winners and nominees by _filterByAwards, so they go through the
      // general scorer. TasteRecommendationEngine's generateOscarWinners and
      // generateFromNomineeToWinner are left in place for other callers, but
      // their overview-text matching is exactly what the awards index
      // replaces -- running it again here would throw away the real data.
      case PersonalizationRowType.oscarWinners:
      case PersonalizationRowType.fromNomineeToWinner:
      case PersonalizationRowType.awardSeasonEssentials:
        return TasteRecommendationEngine.scoreItems(
          candidates: library,
          profile: profile,
          allowWatched: true,
        );

      // Career Milestones needs no awards data: it is about the notable work
      // of people you already like, and the generator's own era badges
      // ("Breakthrough Role", "Critical Peak") are the point of the row.
      case PersonalizationRowType.careerMilestones:
        return TasteRecommendationEngine.generateCareerMilestones(
          libraryItems: library,
          profile: profile,
        );

      case PersonalizationRowType.wellKnownTitles:
        return TasteRecommendationEngine.generateWellKnownMissed(
          libraryItems: library,
          profile: profile,
        );

      case PersonalizationRowType.genreDeepCuts:
        return TasteRecommendationEngine.generateGenreDeepCuts(
          libraryItems: library,
          profile: profile,
        );

      case PersonalizationRowType.somethingDifferent:
        return TasteRecommendationEngine.generateSomethingDifferent(
          libraryItems: library,
          profile: profile,
        );

      case PersonalizationRowType.hiddenGems:
        {
          // A gem is well-rated but under-seen. VoteCount is not a server-side
          // filter, so the thinning happens here before scoring. If nothing
          // clears the bar the unthinned pool is used, because a thin row
          // beats an empty one.
          final gems = library.where((item) {
            final votes = (item.rawData['VoteCount'] as num?)?.toInt() ?? 0;
            final rating =
                (item.rawData['CommunityRating'] as num?)?.toDouble() ?? 0.0;
            return rating >= 7.0 &&
                votes > 0 &&
                votes < TasteRecommendationEngine.minMovieVotes;
          }).toList(growable: false);
          return TasteRecommendationEngine.scoreItems(
            candidates: gems.isEmpty ? library : gems,
            profile: profile,
          );
        }

      // Everything else is the general scorer over a differently-shaped pool.
      // That is the point of putting the intent in the candidate spec: the
      // rows differ by what they ask the server for, not by bespoke scoring.
      case PersonalizationRowType.recommendedForYou:
      case PersonalizationRowType.seriesYouMightBinge:
      case PersonalizationRowType.moodMatch:
      case PersonalizationRowType.newInLibraryMatchesTaste:
      case PersonalizationRowType.becauseYouWatched:
      case PersonalizationRowType.beforeTheyWereFamous:
        return TasteRecommendationEngine.scoreItems(
          candidates: library,
          profile: profile,
        );
    }
  }

  // ───────────────────────────────── moods ──────────────────────────────────

  /// Genres that stand for each mood.
  ///
  /// Inverted from the history analyzer's own genre-to-mood inference so the
  /// two agree: a title the analyzer would read as "Feel-Good" is a title this
  /// row will go looking for. Keeping them in step matters — if they drift,
  /// the mood a user picks stops matching the mood their history implies.
  static const _moodGenres = <MoodCategory, List<String>>{
    MoodCategory.edgeOfYourSeat: ['Action', 'Thriller'],
    MoodCategory.feelGood: ['Comedy', 'Family', 'Animation'],
    MoodCategory.funny: ['Comedy'],
    MoodCategory.scary: ['Horror'],
    MoodCategory.mindBending: ['Mystery', 'Crime'],
    MoodCategory.thoughtProvoking: ['Documentary', 'Drama'],
    MoodCategory.epic: ['Adventure', 'Fantasy', 'Science Fiction'],
    MoodCategory.romantic: ['Romance'],
  };

  List<String> _genresForMoods(Set<MoodCategory> moods) {
    if (moods.isEmpty) return const [];
    final genres = <String>{};
    for (final mood in moods) {
      genres.addAll(_moodGenres[mood] ?? const []);
    }
    // Each genre costs a request, so a user who picked every mood does not get
    // a dozen of them.
    return genres.take(4).toList(growable: false);
  }
}

/// A built personalization row, ready for the home screen.
class TasteHomeRow {
  final PersonalizationRowType rowType;
  final List<RecommendationItem> items;

  /// Mean score of the row's opening items. Decides running order.
  final double score;

  /// Heading for rows whose title depends on their content, such as
  /// "Because you watched Dune". Null for rows whose type names them.
  final String? titleOverride;

  const TasteHomeRow({
    required this.rowType,
    required this.items,
    required this.score,
    this.titleOverride,
  });

  String get title => titleOverride ?? rowType.defaultTitle;

  /// Stable across rebuilds so the home screen can replace a row in place
  /// instead of appending a second copy.
  String get rowId => 'taste_${rowType.key}';

  List<AggregatedItem> get mediaItems =>
      items.map((r) => r.item).toList(growable: false);
}

class _CachedRow {
  final List<RecommendationItem> items;
  final DateTime builtAt;

  /// Set only where the heading depends on the content — a seeded row names
  /// the title it was built from, which the row type alone cannot know.
  final String? title;

  const _CachedRow(this.items, this.builtAt, {this.title});

  bool isStale(Duration ttl) => DateTime.now().difference(builtAt) > ttl;
}
