import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:server_core/server_core.dart';

import '../../../preference/user_preferences.dart';
import '../../models/aggregated_item.dart';
import '../../repositories/multi_server_repository.dart';
import 'taste_cold_start_service.dart';
import '../../models/taste_profile/taste_profile_models.dart';
import 'taste_recommendation_engine.dart';
import 'taste_server_context.dart';

/// Which parts of the profile shape a candidate query.
///
/// A row asks for the signals that match its intent rather than getting one
/// broad pool: "Genre Deep Cuts" wants genres only, "Career Milestones" wants
/// people only. Each signal that is switched on contributes its own server
/// query, so asking for fewer is both cheaper and sharper.
enum TasteSignal { genres, people, studios, era }

/// Describes the candidates one row needs.
class TasteCandidateSpec {
  /// Jellyfin item types, e.g. `['Movie']` or `['Series']`. When empty the
  /// profile's own format preference decides.
  final List<String> itemTypes;

  /// How many candidates to return after merging and filtering. The engine
  /// scores this pool down to a row, so it wants headroom: roughly three
  /// times the final row length is a sensible ask.
  final int limit;

  /// Profile signals to build queries from. Empty means an unfiltered
  /// popularity query, which is what the award and "something different"
  /// rows want.
  final Set<TasteSignal> signals;

  /// Extra genres to query alongside (or instead of) the profile's own.
  final List<String> extraGenres;

  /// Genres to drop after fetching, on top of the profile's negative signals.
  final Set<String> excludeGenres;

  /// Only items added to the library after this instant. Drives the
  /// "New & Matches Your Taste" row.
  final DateTime? addedAfter;

  final String sortBy;
  final String sortOrder;

  /// Item ids to drop — the seed of a "because you watched" row, or titles a
  /// sibling row has already claimed.
  final Set<String> excludeIds;

  const TasteCandidateSpec({
    this.itemTypes = const [],
    this.limit = 60,
    this.signals = const {TasteSignal.genres},
    this.extraGenres = const [],
    this.excludeGenres = const {},
    this.addedAfter,
    this.sortBy = 'CommunityRating,ProductionYear',
    this.sortOrder = 'Descending',
    this.excludeIds = const {},
  });
}

/// A candidate paired with how many profile signals it matched.
class TasteCandidate {
  final AggregatedItem item;

  /// Every logged-in server that also holds this title, the item's own server
  /// first. Playback uses the first entry; the rest are failovers.
  final List<String> availableServerIds;

  /// Number of distinct signal queries that returned this item. An item found
  /// under two favourite genres and a favourite director is a better bet than
  /// one that surfaced once, and the engine has no way to know that after the
  /// fact — the query that produced each item is gone by then.
  final int signalHits;

  const TasteCandidate({
    required this.item,
    required this.signalHits,
    this.availableServerIds = const [],
  });
}

/// Turns a taste profile into server-side queries.
///
/// This is the piece that was missing. The sync page used to download the top
/// 150 movies and top 150 series by community rating and treat those 300 items
/// as "the library" for every user on the server — so two people with opposite
/// taste scored recommendations out of an identical pool, and the profile only
/// ever acted as a filter on someone else's shortlist.
///
/// Here the profile *is* the query: affinities become `genres`, `studios`,
/// `personIds` and `minPremiereDate`, and the server returns a pool that is
/// already relevant. Only the handful of constraints the API cannot express
/// are applied afterwards.
class TasteCandidateService {
  TasteCandidateService(this._serverContext, {TasteColdStartService? coldStart})
      : _coldStart = coldStart ?? TasteColdStartService();

  final TasteServerContext _serverContext;
  final TasteColdStartService _coldStart;

  /// Resolved person ids, keyed by `serverId|lower-cased name`. Names come
  /// from the profile's actor/director affinities; ids are what `getItems`
  /// wants. The server id is part of the key because person ids are local to
  /// a server -- reusing one across servers would silently query for the
  /// wrong person, or for nobody at all. A miss is cached as null so a person
  /// a server does not know is not looked up again every rebuild.
  final Map<String, String?> _personIdCache = {};


  /// How many values a single signal contributes. Each one costs a request,
  /// so the top few carry nearly all the weight anyway.
  static const _maxGenreQueries = 3;
  static const _maxPersonQueries = 2;
  static const _maxStudioQueries = 2;

  /// Fields the recommendation engine actually reads. MediaStreams is the
  /// expensive one and only matters when language filtering is on, so it is
  /// requested conditionally rather than on every call.
  static const _baseFields =
      'Genres,Tags,Studios,People,Overview,CommunityRating,VoteCount,'
      'CriticRating,ProductionYear,OfficialRating,RunTimeTicks,UserData,'
      'ImageTags,PrimaryImageAspectRatio,CollectionId,SeriesId,ProviderIds';
  static const _languageFields =
      ',OriginalLanguage,SpokenLanguages,MediaStreams';

  /// Candidates for one row, ranked by how many profile signals matched.
  ///
  /// Never throws: a row with no candidates renders as no row, which is the
  /// correct degradation. Individual query failures are isolated so one bad
  /// genre does not empty the pool.
  Future<List<TasteCandidate>> fetchCandidates({
    required TasteProfile profile,
    TasteCandidateSpec spec = const TasteCandidateSpec(),
    String? serverId,
  }) async {
    final primaryServerId = serverId ?? profile.serverId;
    final sessions = await _resolveSessions(primaryServerId);
    if (sessions.isEmpty) return const [];

    final itemTypes = spec.itemTypes.isNotEmpty
        ? spec.itemTypes
        : _itemTypesFor(profile);

    // Queries are built per server, not once and reused. Genres and studios
    // are names and would travel, but person ids do not: they are local to
    // the server that issued them, so each server resolves its own.
    final perServer = await Future.wait(
      sessions.map((session) async {
        final queries = await _buildQueries(
          client: session.client,
          serverId: session.serverId,
          profile: profile,
          spec: spec,
        );
        return Future.wait(
          queries.map(
            (q) => _runQuery(
              client: session.client,
              serverId: session.serverId,
              profile: profile,
              spec: spec,
              itemTypes: itemTypes,
              query: q,
            ),
          ),
        );
      }),
    );

    final results = perServer.expand((lists) => lists).toList();
    return _mergeAndRank(results, spec, primaryServerId);
  }

  /// The servers to draw candidates from.
  ///
  /// Mirrors how Continue Watching already behaves: with multi-server
  /// libraries on, every logged-in session contributes; otherwise it is the
  /// one server the profile belongs to. The primary is always first so it
  /// wins ties during deduplication and ends up as the playback target.
  Future<List<_CandidateSession>> _resolveSessions(String primaryServerId) async {
    final primaryClient = _serverContext.getPrimaryClient(primaryServerId);
    final primary = primaryClient == null
        ? null
        : _CandidateSession(primaryServerId, primaryClient);

    if (!_multiServerEnabled || !GetIt.instance.isRegistered<MultiServerRepository>()) {
      return primary == null ? const [] : [primary];
    }

    try {
      final logged = await GetIt.instance<MultiServerRepository>()
          .getLoggedInServers();
      final sessions = <_CandidateSession>[?primary];
      for (final s in logged) {
        if (s.server.id == primaryServerId) continue;
        sessions.add(_CandidateSession(s.server.id, s.client));
      }
      return sessions;
    } catch (e) {
      // A failure to enumerate is not a reason to show no rows at all.
      debugPrint('[TasteCandidateService] server enumeration failed: $e');
      return primary == null ? const [] : [primary];
    }
  }

  bool get _multiServerEnabled {
    try {
      if (!GetIt.instance.isRegistered<UserPreferences>()) return false;
      return GetIt.instance<UserPreferences>()
          .get(UserPreferences.enableMultiServerLibraries);
    } catch (_) {
      return false;
    }
  }

  /// Resolves a person name to a server person id, cached for the session.
  ///
  /// `getPersons` is a search, so the first result is not necessarily the
  /// person asked for — an exact name match is required before trusting it.
  Future<String?> resolvePersonId(
    MediaServerClient client,
    String serverId,
    String name,
  ) async {
    final trimmed = name.trim().toLowerCase();
    if (trimmed.isEmpty) return null;
    final key = '$serverId|$trimmed';
    if (_personIdCache.containsKey(key)) return _personIdCache[key];

    try {
      final res = await client.itemsApi.getPersons(
        searchTerm: name.trim(),
        limit: 5,
      );
      final items = (res['Items'] as List? ?? []).whereType<Map>();
      for (final person in items) {
        final personName = person['Name']?.toString().trim().toLowerCase();
        final id = person['Id']?.toString();
        if (personName == trimmed && id != null && id.isNotEmpty) {
          _personIdCache[key] = id;
          return id;
        }
      }
    } catch (e) {
      debugPrint('[TasteCandidateService] person lookup failed for $name: $e');
      // Not cached as a miss: a network failure is not evidence the person
      // is absent, and caching it would suppress the retry.
      return null;
    }

    _personIdCache[key] = null;
    return null;
  }

  void clearPersonCache() => _personIdCache.clear();

  // ───────────────────────────── query building ─────────────────────────────

  Future<List<_SignalQuery>> _buildQueries({
    required MediaServerClient client,
    required String serverId,
    required TasteProfile profile,
    required TasteCandidateSpec spec,
  }) async {
    final queries = <_SignalQuery>[];
    final inferred = profile.inferred;

    // Explicit genres always apply; the profile's own top genres join them
    // only when the genre signal is switched on.
    final genres = <String>{
      ...spec.extraGenres,
      if (spec.signals.contains(TasteSignal.genres))
        ..._topKeys(
          inferred.genreAffinities,
          _maxGenreQueries,
          exclude: inferred.negativeGenreSignals,
        ),
    };

    // Nothing to go on yet. A profile with no history would otherwise issue
    // one unfiltered popularity query, which is the same query for every user
    // on the server -- so a brand new account's "personalized" rows would look
    // identical to everyone else's. The backend's cold-start set names the
    // genres worth starting from; the titles behind it are TMDb entries and
    // are not used, only the names, which are then queried against this
    // viewer's own library.
    if (genres.isEmpty && spec.signals.contains(TasteSignal.genres)) {
      final seeds = await _coldStart.seedGenres();
      genres.addAll(seeds.take(_maxGenreQueries));
    }

    for (final genre in genres) {
      queries.add(_SignalQuery(signature: 'genre:$genre', genres: [genre]));
    }

    if (spec.signals.contains(TasteSignal.studios)) {
      for (final studio
          in _topKeys(inferred.studioAffinities, _maxStudioQueries)) {
        queries.add(
          _SignalQuery(signature: 'studio:$studio', studios: [studio]),
        );
      }
    }

    if (spec.signals.contains(TasteSignal.people)) {
      // Actors and directors share one budget: the strongest few signals
      // across both, not the top n of each.
      final people = <String, double>{
        ...inferred.actorAffinities,
        ...inferred.directorAffinities,
      };
      var names = _topKeys(
        people,
        _maxPersonQueries,
        exclude: inferred.negativePeopleSignals,
      );
      if (names.isEmpty) {
        final seeds = await _coldStart.seedActors();
        names = seeds.take(_maxPersonQueries).toList(growable: false);
      }
      for (final name in names) {
        final id = await resolvePersonId(client, serverId, name);
        if (id != null) {
          queries.add(_SignalQuery(signature: 'person:$name', personIds: [id]));
        }
      }
    }

    // A query with no signal at all is still valid — award rows and
    // "something different" want a broad popularity pool.
    if (queries.isEmpty) {
      queries.add(const _SignalQuery(signature: 'broad'));
    }

    return queries;
  }

  Future<_QueryResult> _runQuery({
    required MediaServerClient client,
    required String serverId,
    required TasteProfile profile,
    required TasteCandidateSpec spec,
    required List<String> itemTypes,
    required _SignalQuery query,
  }) async {
    final needsLanguageFields = profile.languageSettings.excludeForeignContent;
    final fields =
        needsLanguageFields ? '$_baseFields$_languageFields' : _baseFields;

    try {
      final res = await client.itemsApi.getItems(
        recursive: true,
        includeItemTypes: itemTypes,
        sortBy: spec.sortBy,
        sortOrder: spec.sortOrder,
        fields: fields,
        limit: spec.limit,
        genres: query.genres,
        studios: query.studios,
        personIds: query.personIds,
        minPremiereDate: _minPremiereDate(profile, spec),
        maxOfficialRating: _maxOfficialRating(profile),
      );

      final raw = (res['Items'] as List? ?? []).whereType<Map<String, dynamic>>();
      final items = <AggregatedItem>[];
      for (final r in raw) {
        final id = r['Id']?.toString() ?? '';
        if (id.isEmpty) continue;
        final item = AggregatedItem(id: id, serverId: serverId, rawData: r);
        if (_passesPostFilters(item, profile, spec)) items.add(item);
      }
      return _QueryResult(query.signature, items);
    } catch (e) {
      debugPrint('[TasteCandidateService] candidate query failed: $e');
      return _QueryResult(query.signature, const []);
    }
  }

  // ────────────────────────────── post-filters ──────────────────────────────

  /// Only the constraints `getItems` cannot express.
  ///
  /// Deliberately does NOT re-apply the disliked-item, negative-signal,
  /// already-watched or language filters: [TasteRecommendationEngine.scoreItems]
  /// already owns those, and duplicating them here would give two copies of
  /// the same rule to drift apart.
  bool _passesPostFilters(
    AggregatedItem item,
    TasteProfile profile,
    TasteCandidateSpec spec,
  ) {
    if (spec.excludeIds.contains(item.id)) return false;
    if (TasteRecommendationEngine.isExcludedNonEntertainmentItem(item)) {
      return false;
    }

    // There is no exclude-genres parameter, so negative genres are dropped
    // after the fact.
    final blocked = <String>{
      ...profile.inferred.negativeGenreSignals.map((g) => g.toLowerCase()),
      ...spec.excludeGenres.map((g) => g.toLowerCase()),
    };
    if (blocked.isNotEmpty) {
      for (final genre in item.genres) {
        if (blocked.contains(genre.toLowerCase())) return false;
      }
    }

    final prefs = profile.explicit.viewingPreferences;

    // 'classic' is an upper bound on year; minPremiereDate can only express
    // a lower one, so it lands here.
    if (prefs.preferredEra == 'classic') {
      final year = item.productionYear;
      if (year != null && year >= 1980) return false;
    }

    if (prefs.maxMovieLengthMinutes > 0 && item.type == 'Movie') {
      final ticks = item.runTimeTicks;
      if (ticks != null && ticks > 0) {
        final minutes = ticks / 600000000; // 10,000 ticks per ms
        if (minutes > prefs.maxMovieLengthMinutes) return false;
      }
    }

    if (spec.addedAfter != null) {
      final created = DateTime.tryParse(
        item.rawData['DateCreated']?.toString() ?? '',
      );
      if (created == null || created.isBefore(spec.addedAfter!)) return false;
    }

    return true;
  }

  // ─────────────────────────────── merging ──────────────────────────────────

  List<TasteCandidate> _mergeAndRank(
    List<_QueryResult> results,
    TasteCandidateSpec spec,
    String primaryServerId,
  ) {
    // Keyed on content, not on item id: the same film on two servers has two
    // different ids, and showing it twice in one row is the bug this avoids.
    // Same key the aggregated Continue Watching row already dedupes on.
    final byKey = <String, AggregatedItem>{};
    final signaturesForKey = <String, Set<String>>{};
    final serversForKey = <String, List<String>>{};

    for (final result in results) {
      for (final item in result.items) {
        final key = MultiServerRepository.computeContentKey(item) ??
            '${item.serverId}_${item.id}';

        final servers = serversForKey.putIfAbsent(key, () => <String>[]);
        if (!servers.contains(item.serverId)) servers.add(item.serverId);

        // Distinct signals, not distinct responses. The same genre query run
        // against three servers is one signal; two different genre queries on
        // one server are two.
        signaturesForKey
            .putIfAbsent(key, () => <String>{})
            .add(result.signature);

        final existing = byKey[key];
        if (existing == null) {
          byKey[key] = item;
        } else if (existing.serverId != primaryServerId &&
            item.serverId == primaryServerId) {
          // The primary server's copy wins, so playback stays on the server
          // the viewer is actually signed in to, with the others as failovers.
          byKey[key] = item;
        }
      }
    }

    final merged = byKey.entries.map((entry) {
      final servers = serversForKey[entry.key] ?? [entry.value.serverId];
      // Primary first: it is the playback target.
      servers.sort((a, b) {
        if (a == primaryServerId) return -1;
        if (b == primaryServerId) return 1;
        return 0;
      });
      return TasteCandidate(
        item: entry.value,
        signalHits: signaturesForKey[entry.key]?.length ?? 1,
        availableServerIds: List.unmodifiable(servers),
      );
    }).toList();

    // Multi-signal matches first, then titles available on more servers (a
    // safer playback bet), then community rating so the pool handed to the
    // scorer is never in arbitrary map order.
    merged.sort((a, b) {
      final bySignal = b.signalHits.compareTo(a.signalHits);
      if (bySignal != 0) return bySignal;
      final byReach =
          b.availableServerIds.length.compareTo(a.availableServerIds.length);
      if (byReach != 0) return byReach;
      final ra = (a.item.rawData['CommunityRating'] as num?)?.toDouble() ?? 0;
      final rb = (b.item.rawData['CommunityRating'] as num?)?.toDouble() ?? 0;
      return rb.compareTo(ra);
    });

    return merged.take(spec.limit).toList(growable: false);
  }

  // ──────────────────────────── profile mapping ─────────────────────────────

  List<String> _itemTypesFor(TasteProfile profile) {
    switch (profile.explicit.viewingPreferences.formatPreference) {
      case 'movies':
        return const ['Movie'];
      case 'series':
        return const ['Series'];
      default:
        return const ['Movie', 'Series'];
    }
  }

  /// Lower year bound, from whichever of the two era vocabularies applies.
  ///
  /// The explicit wizard answer uses 'all' / 'classic' / 'modern' / 'recent';
  /// the inferred affinities use the analyzer's own buckets ('classic',
  /// 'eighties_nineties', 'two_thousands', 'modern'). They are different
  /// vocabularies over the same axis, so both are handled here rather than
  /// leaving a caller to guess which one it holds.
  DateTime? _minPremiereDate(TasteProfile profile, TasteCandidateSpec spec) {
    final explicitEra = profile.explicit.viewingPreferences.preferredEra;
    int? year = switch (explicitEra) {
      'modern' => 1980,
      'recent' => 2010,
      _ => null,
    };

    if (year == null && spec.signals.contains(TasteSignal.era)) {
      final top = _topKeys(profile.inferred.eraAffinities, 1);
      if (top.isNotEmpty) {
        year = switch (top.first) {
          'eighties_nineties' => 1980,
          'two_thousands' => 2000,
          'modern' => 2015,
          _ => null, // 'classic' is an upper bound, handled post-fetch
        };
      }
    }

    return year == null ? null : DateTime(year);
  }

  String? _maxOfficialRating(TasteProfile profile) {
    final ceiling = profile.explicit.viewingPreferences.maturityCeiling;
    if (ceiling.isEmpty || ceiling == 'Any') return null;
    return ceiling;
  }

  /// The [count] highest-weighted keys, skipping anything in [exclude].
  List<String> _topKeys(
    Map<String, double> affinities,
    int count, {
    Set<String> exclude = const {},
  }) {
    if (affinities.isEmpty || count <= 0) return const [];
    final blocked = exclude.map((e) => e.toLowerCase()).toSet();
    final entries = affinities.entries
        .where((e) =>
            e.key.trim().isNotEmpty &&
            e.value > 0 &&
            !blocked.contains(e.key.toLowerCase()))
        .toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return entries.take(count).map((e) => e.key).toList(growable: false);
  }
}

/// A server this service can draw candidates from.
class _CandidateSession {
  final String serverId;
  final MediaServerClient client;

  const _CandidateSession(this.serverId, this.client);
}

/// One server query built from a single profile signal.
class _SignalQuery {
  final List<String>? genres;
  final List<String>? studios;
  final List<String>? personIds;

  /// Identifies the signal, not the request: 'person:Tilda Swinton' is the
  /// same signal on every server even though each server resolves it to a
  /// different person id. Counting distinct signatures is what makes
  /// signalHits mean "matched N things the profile likes" rather than
  /// "appears on N servers".
  final String signature;

  const _SignalQuery({
    required this.signature,
    this.genres,
    this.studios,
    this.personIds,
  });
}

/// One signal's results from one server.
class _QueryResult {
  final String signature;
  final List<AggregatedItem> items;

  const _QueryResult(this.signature, this.items);
}
