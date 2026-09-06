import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';

import '../../../auth/store/voltix_session_store.dart';
import '../../../preference/user_preferences.dart';
import '../../models/aggregated_item.dart';
import '../voltix_api_service.dart';

/// What a title won, reduced to the few numbers the award rows actually ask.
class AwardRecord {
  final String imdbId;
  final int oscarWins;
  final int oscarNominations;
  final int wins;
  final int nominations;

  /// The source string, kept so a row can quote it ("Won 4 Oscars") rather
  /// than reconstructing prose from the counts.
  final String summary;

  const AwardRecord({
    required this.imdbId,
    this.oscarWins = 0,
    this.oscarNominations = 0,
    this.wins = 0,
    this.nominations = 0,
    this.summary = '',
  });

  bool get wonOscar => oscarWins > 0;
  bool get nominatedForOscar => oscarNominations > 0;
  bool get hasAnyAward => wins > 0 || oscarWins > 0;

  /// True for titles that belong in an "award season" row: a real contender,
  /// not a film with two festival wins.
  bool get isAwardSeasonContender =>
      oscarWins > 0 || oscarNominations > 0 || wins >= 5;

  Map<String, dynamic> toJson() => {
        'imdbId': imdbId,
        'oscarWins': oscarWins,
        'oscarNominations': oscarNominations,
        'wins': wins,
        'nominations': nominations,
        'summary': summary,
      };

  factory AwardRecord.fromJson(Map<String, dynamic> json) => AwardRecord(
        imdbId: json['imdbId']?.toString() ?? '',
        oscarWins: (json['oscarWins'] as num?)?.toInt() ?? 0,
        oscarNominations: (json['oscarNominations'] as num?)?.toInt() ?? 0,
        wins: (json['wins'] as num?)?.toInt() ?? 0,
        nominations: (json['nominations'] as num?)?.toInt() ?? 0,
        summary: json['summary']?.toString() ?? '',
      );

  /// Parses OMDb's single `Awards` string, which is prose rather than data:
  ///
  ///   "Won 4 Oscars. 34 wins & 92 nominations total"
  ///   "Nominated for 3 Oscars. 12 wins & 40 nominations total"
  ///   "2 wins & 5 nominations"
  ///   "N/A"
  static AwardRecord parse(String imdbId, String? awards) {
    final text = (awards ?? '').trim();
    if (text.isEmpty || text == 'N/A') {
      return AwardRecord(imdbId: imdbId);
    }

    int match(RegExp re) {
      final m = re.firstMatch(text);
      return m == null ? 0 : (int.tryParse(m.group(1) ?? '') ?? 0);
    }

    // "Won 4 Oscars" / "Won 1 Oscar"
    final oscarWins = match(RegExp(r'Won (\d+) Oscar', caseSensitive: false));
    // "Nominated for 3 Oscars"
    final oscarNoms =
        match(RegExp(r'Nominated for (\d+) Oscar', caseSensitive: false));
    final wins = match(RegExp(r'(\d+) wins?', caseSensitive: false));
    final noms = match(RegExp(r'(\d+) nominations?', caseSensitive: false));

    return AwardRecord(
      imdbId: imdbId,
      oscarWins: oscarWins,
      oscarNominations: oscarNoms,
      // A film that won an Oscar and nothing else reads as "Won 1 Oscar." with
      // no wins count, so the Oscar is folded in rather than lost.
      wins: wins > 0 ? wins : oscarWins,
      nominations: noms > 0 ? noms : oscarNoms,
      summary: text,
    );
  }
}

/// Resolves what a title won, so the award rows have something real to filter
/// on.
///
/// Until now those rows filtered on whether the word "oscar" appeared in a
/// title's overview text, which is a guess dressed as data. This is the real
/// source.
///
/// Two lookup paths, tried in order:
///
///  1. **The Voltix backend.** Preferred, and the reason this class exists as
///     an abstraction rather than an OMDb client. Awards data is static — a
///     film's Oscar record changes once a year at most — so it wants resolving
///     once globally, not once per user per device. That also keeps the API
///     key server-side instead of shipping it in the binary.
///  2. **OMDb directly.** The fallback while the backend endpoint does not
///     exist. It works, but the free tier allows 1,000 requests a day counted
///     against the *key*, not the user, so every install shares one budget.
///     Hence the aggressive cache and the per-session ceiling below: this path
///     is designed to degrade quietly as more people use it, rather than burn
///     the quota in an afternoon and leave the rows empty for everyone.
///
/// Switching to path 1 is a backend deployment, not a client rewrite.
class TasteAwardsIndex {
  TasteAwardsIndex(this._prefs, {Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 10),
            ));

  final PreferenceStore _prefs;
  final Dio _dio;

  static const _cacheKey = 'voltix_awards_index';
  static const _omdbBase = 'https://www.omdbapi.com/';

  /// Awards do not change between ceremonies, so a long life costs nothing and
  /// saves the quota.
  static const _entryTtl = Duration(days: 90);

  /// Cap on direct OMDb lookups per app session. Four award rows at sixty
  /// candidates each would otherwise spend most of a shared daily budget on
  /// one home screen. Titles beyond the cap simply resolve as unknown and drop
  /// out of the rows, which is a thinner row rather than a broken one.
  static const _sessionLookupBudget = 40;

  final Map<String, AwardRecord> _memory = {};
  final Map<String, DateTime> _fetchedAt = {};
  final Set<String> _misses = {};
  int _lookupsThisSession = 0;
  bool _loaded = false;

  /// Build-time override, for shipping a different key per flavour without
  /// touching source: `--dart-define=OMDB_API_KEY=...`.
  static const _envKey = String.fromEnvironment('OMDB_API_KEY');

  /// The key that ships with the app.
  ///
  /// Bundled so the award rows work out of the box rather than asking every
  /// viewer to register at omdbapi.com for a row they did not ask for. Two
  /// things follow from that and are worth knowing: a key in the binary can
  /// be extracted from it, and the free tier's 1,000 lookups a day are
  /// counted against the key rather than the person, so every install shares
  /// this one budget. The caching and the per-session ceiling below exist to
  /// stretch it; a viewer who supplies their own key in Settings gets their
  /// own budget instead, which is why that takes priority.
  static const _bundledKey = 'c123a40e';

  /// True when any key is available. With none, and no backend endpoint, the
  /// award rows have no source and stay empty.
  bool get hasDirectKey => _apiKey.isNotEmpty;

  /// The viewer's own key first, then a build-time override, then the bundled
  /// one. Supplying a key is how someone opts out of the shared quota.
  String get _apiKey {
    try {
      if (GetIt.instance.isRegistered<UserPreferences>()) {
        final own = GetIt.instance<UserPreferences>()
            .get(UserPreferences.omdbApiKey)
            .trim();
        if (own.isNotEmpty) return own;
      }
    } catch (_) {
      // Fall through to the built-in keys.
    }
    return _envKey.isNotEmpty ? _envKey : _bundledKey;
  }

  /// Award records for [items], keyed by item id. Titles with no IMDb id, or
  /// that could not be resolved, are absent rather than present-and-empty, so
  /// a caller can tell "no awards" from "not looked up".
  Future<Map<String, AwardRecord>> recordsFor(List<AggregatedItem> items) async {
    await _ensureLoaded();

    final result = <String, AwardRecord>{};
    final toFetch = <String, String>{}; // imdbId -> itemId

    for (final item in items) {
      final imdb = item.imdbId?.trim();
      if (imdb == null || imdb.isEmpty) continue;

      final cached = _memory[imdb];
      final at = _fetchedAt[imdb];
      if (cached != null && at != null && !_isStale(at)) {
        result[item.id] = cached;
        continue;
      }
      if (_misses.contains(imdb)) continue;
      toFetch[imdb] = item.id;
    }

    if (toFetch.isEmpty) return result;

    final fetched = await _resolve(toFetch.keys.toList());
    var dirty = false;
    for (final entry in fetched.entries) {
      _memory[entry.key] = entry.value;
      _fetchedAt[entry.key] = DateTime.now();
      dirty = true;
      final itemId = toFetch[entry.key];
      if (itemId != null) result[itemId] = entry.value;
    }
    if (dirty) await _persist();

    return result;
  }

  /// Backend first, OMDb second.
  Future<Map<String, AwardRecord>> _resolve(List<String> imdbIds) async {
    final viaBackend = await _fetchFromBackend(imdbIds);
    if (viaBackend.isNotEmpty) return viaBackend;

    if (!hasDirectKey) return const {};

    final resolved = <String, AwardRecord>{};
    for (final imdbId in imdbIds) {
      if (_lookupsThisSession >= _sessionLookupBudget) {
        debugPrint(
          '[TasteAwardsIndex] session lookup budget reached; '
          'remaining titles resolve as unknown',
        );
        break;
      }
      _lookupsThisSession++;
      final record = await _fetchFromOmdb(imdbId);
      if (record != null) {
        resolved[imdbId] = record;
      } else {
        // Remembered for this session so a title OMDb does not know is not
        // retried on every row build.
        _misses.add(imdbId);
      }
    }
    return resolved;
  }

  /// Batch lookup against the Voltix backend, which resolves each title once
  /// for everyone and keeps the OMDb key server-side.
  ///
  /// Returns empty rather than throwing when it cannot answer -- not signed
  /// in, endpoint not deployed yet, backend down. That is deliberately quiet
  /// because the OMDb path behind it is a working fallback, not an error.
  Future<Map<String, AwardRecord>> _fetchFromBackend(List<String> imdbIds) async {
    try {
      if (!GetIt.instance.isRegistered<VoltixApiService>() ||
          !GetIt.instance.isRegistered<VoltixSessionStore>()) {
        return const {};
      }
      final token = GetIt.instance<VoltixSessionStore>().sessionToken;
      if (token == null || token.isEmpty) return const {};

      final api = GetIt.instance<VoltixApiService>();
      final data = await api.restGet(
        '/api/voltix/awards',
        query: {'imdbIds': imdbIds.join(',')},
        sessionToken: token,
      );
      final items = (data is Map ? data['items'] : null) as List? ?? const [];
      final out = <String, AwardRecord>{};
      for (final raw in items.whereType<Map<String, dynamic>>()) {
        final record = AwardRecord.fromJson(raw);
        if (record.imdbId.isNotEmpty) out[record.imdbId] = record;
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  Future<AwardRecord?> _fetchFromOmdb(String imdbId) async {
    try {
      final res = await _dio.get<dynamic>(
        _omdbBase,
        queryParameters: {'apikey': _apiKey, 'i': imdbId},
      );
      final body = res.data;
      if (body is! Map) return null;
      if (body['Response']?.toString().toLowerCase() != 'true') return null;
      return AwardRecord.parse(imdbId, body['Awards']?.toString());
    } catch (e) {
      debugPrint('[TasteAwardsIndex] OMDb lookup failed for $imdbId: $e');
      return null;
    }
  }

  bool _isStale(DateTime at) => DateTime.now().difference(at) > _entryTtl;

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = _prefs.getString(_cacheKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final entries = decoded['entries'];
      if (entries is! List) return;
      for (final e in entries.whereType<Map<String, dynamic>>()) {
        final record = AwardRecord.fromJson(e);
        if (record.imdbId.isEmpty) continue;
        final at = DateTime.tryParse(e['fetchedAt']?.toString() ?? '');
        if (at == null || _isStale(at)) continue;
        _memory[record.imdbId] = record;
        _fetchedAt[record.imdbId] = at;
      }
    } catch (e) {
      debugPrint('[TasteAwardsIndex] cache load failed: $e');
    }
  }

  Future<void> _persist() async {
    try {
      final entries = _memory.entries.map((e) {
        final at = _fetchedAt[e.key] ?? DateTime.now();
        return {...e.value.toJson(), 'fetchedAt': at.toIso8601String()};
      }).toList();
      await _prefs.setString(_cacheKey, jsonEncode({'entries': entries}));
    } catch (e) {
      debugPrint('[TasteAwardsIndex] cache write failed: $e');
    }
  }

  /// Drops everything cached, including "not found" verdicts.
  ///
  /// Called when the API key changes: misses recorded while no key was set
  /// would otherwise persist and keep the award rows empty after one is
  /// finally added.
  void clear() {
    _memory.clear();
    _fetchedAt.clear();
    _misses.clear();
    _lookupsThisSession = 0;
    _loaded = false;
  }
}
