import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:path_provider/path_provider.dart';
import 'package:server_core/server_core.dart';

import 'package:playback_core/playback_core.dart';

import '../../util/platform_detection.dart';
import '../models/aggregated_item.dart';
import 'taste_profile/foreign_content_filter.dart';
import 'voltix_api_service.dart';

/// One list inside the Vault.
class VaultListDef {
  final String key;
  final String title;
  final String asset;
  final String type; // 'Movie' | 'Series'
  final bool newestFromServer;

  const VaultListDef(
    this.key,
    this.title,
    this.asset,
    this.type, {
    this.newestFromServer = false,
  });
}

/// The Vault: 22 curated lists (trending, newest, popular per streaming
/// service, best of all time), each holding up to 30 titles that are ON THE
/// USER'S SERVER and can be streamed.
///
/// Trending / per-service / best-of lists come from the Voltix backend as
/// ranked TMDB candidates. Every candidate is looked up on the server (TMDB id
/// first, then title + year); titles the server doesn't have are skipped and
/// the next candidate is tried until the list has 30. "Newest" lists come from
/// the server itself (premiere date).
///
/// Shared per media server through the Voltix backend: the finished lists are
/// downloaded (fast) instead of every app matching on its own. Once a week, at
/// night (backend decides: 00:00-06:00 local), ONE idle app gets a lease, does
/// the matching and uploads the result for everyone on that server. The
/// backend itself never signs in to the media server. A copy is also kept on
/// the device so Streamverse opens instantly, even offline.
class VaultService extends ChangeNotifier {
  VaultService._();
  static final VaultService instance = VaultService._();

  static const int itemsPerList = 30;
  static const Duration refreshEvery = Duration(days: 7);
  static const String _p = 'assets/vault_posters';

  static const List<VaultListDef> lists = [
    VaultListDef('trending_movies', 'Trending Movies', '$_p/1_trending_movies.jpg', 'Movie'),
    VaultListDef('trending_shows', 'Trending TV Series', '$_p/2_trending_shows.jpg', 'Series'),
    VaultListDef('newest_movies', 'Newest Movies', '$_p/3_newest_movies.jpg', 'Movie', newestFromServer: true),
    VaultListDef('newest_shows', 'Newest TV Series', '$_p/4_newest_shows.jpg', 'Series', newestFromServer: true),
    VaultListDef('netflix_movies', 'Popular Netflix Movies', '$_p/5_popular_netflix_movies.jpg', 'Movie'),
    VaultListDef('netflix_shows', 'Popular Netflix TV Series', '$_p/6_popular_netflix_shows.jpg', 'Series'),
    VaultListDef('prime_video_movies', 'Popular Prime Video Movies', '$_p/7_popular_prime_video_movies.jpg', 'Movie'),
    VaultListDef('prime_video_shows', 'Popular Prime Video TV Series', '$_p/8_popular_prime_video_shows.jpg', 'Series'),
    VaultListDef('hulu_movies', 'Popular Hulu Movies', '$_p/9_popular_hulu_movies.jpg', 'Movie'),
    VaultListDef('hulu_shows', 'Popular Hulu TV Series', '$_p/10_popular_hulu_shows.jpg', 'Series'),
    VaultListDef('paramount_movies', 'Popular Paramount Movies', '$_p/11_popular_paramount_movies.jpg', 'Movie'),
    VaultListDef('paramount_shows', 'Popular Paramount TV Series', '$_p/12_popular_paramount_shows.jpg', 'Series'),
    VaultListDef('hbo_max_movies', 'Popular HBO Max Movies', '$_p/13_popular_hbo_max_movies.jpg', 'Movie'),
    VaultListDef('hbo_max_shows', 'Popular HBO Max TV Series', '$_p/14_popular_hbo_max_shows.jpg', 'Series'),
    VaultListDef('disney_movies', 'Popular Disney+ Movies', '$_p/15_popular_disney_movies.jpg', 'Movie'),
    VaultListDef('disney_shows', 'Popular Disney+ TV Series', '$_p/16_popular_disney_shows.jpg', 'Series'),
    VaultListDef('peacock_movies', 'Popular Peacock Movies', '$_p/17_popular_peacock_movies.jpg', 'Movie'),
    VaultListDef('peacock_shows', 'Popular Peacock TV Series', '$_p/18_popular_peacock_shows.jpg', 'Series'),
    VaultListDef('apple_tv_movies', 'Popular AppleTV+ Movies', '$_p/19_popular_apple_tv_movies.jpg', 'Movie'),
    VaultListDef('apple_tv_shows', 'Popular AppleTV+ TV Series', '$_p/20_popular_apple_tv_shows.jpg', 'Series'),
    VaultListDef('best_movies', 'Best Movies of All Time', '$_p/21_best_movies_of_all_time.jpg', 'Movie'),
    VaultListDef('best_shows', 'Best TV Series of All Time', '$_p/22_best_shows_of_all_time.jpg', 'Series'),
  ];

  /// Id / collection type of the Vault tile on the My Media row.
  static const String tileId = 'voltix-vault';
  static const String tileCollectionType = 'voltixvault';

  /// The Vault tile for the My Media row (artwork comes from the 'vault'
  /// entry in voltix_library_branding).
  static AggregatedItem tile(String serverId) => AggregatedItem(
        id: tileId,
        serverId: serverId,
        rawData: const {
          'Id': tileId,
          'Name': 'Vault',
          'CollectionType': tileCollectionType,
          'Type': 'CollectionFolder',
        },
      );

  static VaultListDef? defFor(String key) {
    for (final d in lists) {
      if (d.key == key) return d;
    }
    return null;
  }

  static const _fields =
      'PrimaryImageAspectRatio,ProviderIds,ProductionYear,PremiereDate,ImageTags,'
      'UserData,CommunityRating,CriticRating,OfficialRating,RunTimeTicks,Genres,'
      'ProductionLocations';

  // ── State ────────────────────────────────────────────────────────────────
  final Map<String, List<Map<String, dynamic>>> _items = {};
  // "Movie:12345" -> server item id ('' = not on the server). Reused between
  // weekly rebuilds so known titles need no new lookup.
  final Map<String, String> _matches = {};
  // Items re-checked in bulk for the list being built (id -> item).
  final Map<String, Map<String, dynamic>> _verified = {};
  DateTime? _builtAt;
  String? _week;
  String? _cacheKey;
  Timer? _timer;
  bool _building = false;
  bool _loaded = false;
  String? _buildingKey;
  Future<void>? _ensureFuture;

  bool get isBuilding => _building;
  String? get buildingListKey => _buildingKey;
  DateTime? get builtAt => _builtAt;

  /// Server items for [key] (ready to show; serverId = the server's address).
  List<AggregatedItem> itemsFor(String key) {
    final client = _client();
    final serverId = client?.baseUrl ?? '';
    return (_items[key] ?? const [])
        .map((raw) => AggregatedItem(
              id: raw['Id']?.toString() ?? '',
              serverId: serverId,
              rawData: raw,
            ))
        .where((i) => i.id.isNotEmpty)
        .toList(growable: false);
  }

  int countFor(String key) => _items[key]?.length ?? 0;

  MediaServerClient? _client() {
    try {
      return GetIt.instance<MediaServerClient>();
    } catch (_) {
      return null;
    }
  }

  String _keyNow() {
    final c = _client();
    return '${c?.baseUrl ?? ''}|${c?.userId ?? ''}';
  }

  String _apiBase() {
    try {
      return GetIt.instance<VoltixApiService>().baseUrl;
    } catch (_) {
      return VoltixApiService.defaultBaseUrl;
    }
  }

  Dio _dio({Duration receive = const Duration(seconds: 20)}) => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: receive,
      ));

  /// Something is playing on this device (don't add load while streaming).
  bool _playing() {
    try {
      return GetIt.instance<PlaybackManager>().currentResolution != null;
    } catch (_) {
      return false;
    }
  }

  /// Shows the device copy, then picks up the server's shared copy and, when
  /// the backend asks for this week's build, does it. Safe to call often.
  /// [force] is accepted for compatibility; builds are scheduled by the backend.
  Future<void> ensure({bool force = false}) {
    // TVs often sit on the home screen overnight: check every 30 minutes so
    // the night-time build and new weeks are picked up.
    _timer ??= Timer.periodic(const Duration(minutes: 30), (_) => ensure());
    if (_ensureFuture != null && !force) return _ensureFuture!;
    final f = _ensure(force: force);
    _ensureFuture = f;
    f.whenComplete(() {
      if (identical(_ensureFuture, f)) _ensureFuture = null;
    });
    return f;
  }

  Future<void> _ensure({bool force = false}) async {
    final key = _keyNow();
    if (_cacheKey != key) {
      _items.clear();
      _matches.clear();
      _builtAt = null;
      _week = null;
      _loaded = false;
      _cacheKey = key;
    }
    if (!_loaded) {
      _loaded = true;
      await _loadLocal(key);
      notifyListeners();
    }
    await _syncShared(key);
  }

  /// Downloads the server's shared lists; claims and runs the weekly build
  /// when the backend says it is due and allowed now.
  Future<void> _syncShared(String key) async {
    final client = _client();
    if (client == null || (client.userId ?? '').isEmpty || _building) return;
    Map? status;
    try {
      final res = await _dio().get('${_apiBase()}/api/voltix/streamverse',
          queryParameters: {'server': client.baseUrl});
      status = res.data is Map ? res.data as Map : null;
    } catch (e) {
      debugPrint('[Vault] Shared lists unavailable: $e');
      return;
    }
    if (status == null || _keyNow() != key) return;

    final sharedBuilt = DateTime.tryParse(status['builtAt']?.toString() ?? '');
    final lists = status['lists'];
    if (sharedBuilt != null &&
        lists is Map &&
        (_builtAt == null || sharedBuilt.isAfter(_builtAt!))) {
      _items
        ..clear()
        ..addAll({
          for (final e in lists.entries)
            if (e.value is List)
              e.key.toString(): [
                for (final r in e.value as List)
                  if (r is Map) Map<String, dynamic>.from(r),
              ],
        });
      _builtAt = sharedBuilt;
      _week = status['week']?.toString();
      await _saveLocal();
      notifyListeners();
      debugPrint('[Vault] Using shared lists for week $_week');
    }

    if (status['due'] == true && status['buildAllowed'] == true && !_playing()) {
      unawaited(_claimAndBuild(client.baseUrl, key));
    }
  }

  Future<void> _claimAndBuild(String server, String key) async {
    Map? claim;
    try {
      final res = await _dio().post('${_apiBase()}/api/voltix/streamverse/claim',
          data: {'server': server});
      claim = res.data is Map ? res.data as Map : null;
    } catch (_) {
      return;
    }
    if (claim == null || claim['granted'] != true || _keyNow() != key) return;
    final leaseId = claim['leaseId'].toString();
    final m = claim['matches'];
    if (m is Map) {
      for (final e in m.entries) {
        _matches.putIfAbsent(e.key.toString(), () => e.value?.toString() ?? '');
      }
    }
    debugPrint('[Vault] Building week ${claim['week']} for everyone on $server');
    final ok = await _build();
    if (!ok || _keyNow() != key) return;
    try {
      await _dio(receive: const Duration(seconds: 60)).post(
        '${_apiBase()}/api/voltix/streamverse/result',
        data: {
          'server': server,
          'leaseId': leaseId,
          'lists': {
            for (final e in _items.entries)
              e.key: [for (final r in e.value) Map.of(r)..remove('UserData')],
          },
          'matches': _matches,
        },
      );
      _week = claim['week']?.toString();
      await _saveLocal();
      debugPrint('[Vault] Shared lists uploaded');
    } catch (e) {
      debugPrint('[Vault] Upload failed: $e');
    }
  }

  // ── Persistence ─────────────────────────────────────────────────────────
  Future<File> _file() async {
    final dir = PlatformDetection.isAppleTV
        ? await getApplicationCacheDirectory()
        : await getApplicationSupportDirectory();
    return File('${dir.path}/vault_cache.json');
  }

  Map<String, dynamic> _toJson() => {
        'key': _cacheKey,
        'builtAt': _builtAt?.toIso8601String(),
        'week': _week,
        'lists': _items,
        'matches': _matches,
      };

  bool _apply(Map<String, dynamic> data, String key) {
    if (data['key'] != key) return false;
    final lists = data['lists'];
    if (lists is! Map) return false;
    _items
      ..clear()
      ..addAll({
        for (final e in lists.entries)
          if (e.value is List)
            e.key.toString(): [
              for (final r in e.value as List)
                if (r is Map) Map<String, dynamic>.from(r),
            ],
      });
    final m = data['matches'];
    if (m is Map) {
      _matches
        ..clear()
        ..addAll({for (final e in m.entries) e.key.toString(): e.value?.toString() ?? ''});
    }
    _builtAt = DateTime.tryParse(data['builtAt']?.toString() ?? '');
    _week = data['week']?.toString();
    return true;
  }

  Future<bool> _loadLocal(String key) async {
    try {
      final f = await _file();
      if (!f.existsSync()) return false;
      final data = jsonDecode(await f.readAsString());
      return data is Map<String, dynamic> && _apply(data, key);
    } catch (_) {
      return false;
    }
  }

  Future<void> _saveLocal() async {
    try {
      await (await _file()).writeAsString(jsonEncode(_toJson()), flush: true);
    } catch (_) {}
  }

  // ── Build ───────────────────────────────────────────────────────────────
  /// Matches every list on this device. True when it finished.
  Future<bool> _build() async {
    if (_building) return false;
    final client = _client();
    if (client == null || (client.userId ?? '').isEmpty) return false;
    _building = true;
    notifyListeners();
    final started = DateTime.now();
    // Titles the server didn't have last week are looked up again (it may
    // have added them); within this build a title is only looked up once.
    _matches.removeWhere((_, v) => v.isEmpty);
    try {
      final candidates = await _fetchCandidates();
      for (final def in lists) {
        if (_keyNow() != _cacheKey) return false; // user/server changed meanwhile
        // Pause while this device is streaming.
        while (_playing()) {
          await Future<void>.delayed(const Duration(seconds: 30));
        }
        _buildingKey = def.key;
        notifyListeners();
        List<Map<String, dynamic>> found;
        try {
          found = def.newestFromServer
              ? await _newest(client, def.type)
              : await _matchList(client, def.type, candidates[def.key] ?? const []);
        } catch (e) {
          debugPrint('[Vault] ${def.key} failed: $e');
          continue; // keep last week's copy of this list
        }
        // Never replace a good list with an empty one (e.g. backend down).
        if (found.isNotEmpty || (_items[def.key]?.isEmpty ?? true)) {
          _items[def.key] = found;
        }
        notifyListeners();
        unawaited(_saveLocal());
      }
      _builtAt = DateTime.now();
      await _saveLocal();
      debugPrint('[Vault] Built in ${DateTime.now().difference(started).inSeconds}s: '
          '${lists.map((d) => '${d.key}=${countFor(d.key)}').join(', ')}');
      _diag({
        'result': 'built',
        'secs': '${DateTime.now().difference(started).inSeconds}',
        'counts': lists.map((d) => '${d.key}:${countFor(d.key)}').join(','),
      });
      return true;
    } catch (e) {
      debugPrint('[Vault] Build failed: $e');
      _diag({'result': 'failed', 'error': '$e'.substring(0, '$e'.length.clamp(0, 160))});
      return false;
    } finally {
      _building = false;
      _buildingKey = null;
      notifyListeners();
    }
  }

  void _diag(Map<String, String> data) {
    try {
      if (GetIt.instance.isRegistered<VoltixApiService>()) {
        GetIt.instance<VoltixApiService>().directStreamingDiag('vault', data);
      }
    } catch (_) {}
  }

  /// The week's ranked TMDB candidates per list, from the Voltix backend.
  Future<Map<String, List<Map<String, dynamic>>>> _fetchCandidates() async {
    final res = await _dio(receive: const Duration(seconds: 90))
        .get('${_apiBase()}/api/voltix/vault-lists');
    final out = <String, List<Map<String, dynamic>>>{};
    final data = res.data;
    if (data is Map && data['lists'] is List) {
      for (final l in data['lists'] as List) {
        if (l is! Map) continue;
        out[l['key'].toString()] = [
          for (final c in (l['candidates'] as List? ?? const []))
            if (c is Map) Map<String, dynamic>.from(c),
        ];
      }
    }
    return out;
  }

  /// Keep what a list item needs (smaller device / shared copy).
  static Map<String, dynamic> _slim(Map<String, dynamic> r) => {
        for (final k in const [
          'Id', 'Name', 'Type', 'ProductionYear', 'PremiereDate', 'ImageTags',
          'PrimaryImageAspectRatio', 'CommunityRating', 'CriticRating',
          'OfficialRating', 'RunTimeTicks', 'UserData', 'ProviderIds',
        ])
          if (r[k] != null) k: r[k],
      };

  /// Newest on the server by premiere date (released already, with a poster,
  /// no foreign / sport titles - same rules as the rest of Voltix).
  Future<List<Map<String, dynamic>>> _newest(MediaServerClient client, String type) async {
    final res = await client.itemsApi.getItems(
      includeItemTypes: [type],
      recursive: true,
      sortBy: 'PremiereDate',
      sortOrder: 'Descending',
      limit: 150,
      fields: _fields,
      enableTotalRecordCount: false,
      enableImageTypes: 'Primary',
      imageTypeLimit: 1,
    ).timeout(const Duration(seconds: 30));
    final now = DateTime.now();
    final out = <Map<String, dynamic>>[];
    for (final r in (res['Items'] as List? ?? const []).whereType<Map<String, dynamic>>()) {
      final d = DateTime.tryParse(r['PremiereDate']?.toString() ?? '');
      if (d == null || d.isAfter(now)) continue;
      if (ForeignContentFilter.isExcludedItem(r)) continue;
      out.add(_slim(r));
      if (out.length >= itemsPerList) break;
    }
    return out;
  }

  /// Walks the ranked candidates, keeps those the server has (in TMDB order),
  /// stops at [itemsPerList]. Looks up 4 titles at a time.
  Future<List<Map<String, dynamic>>> _matchList(
    MediaServerClient client,
    String type,
    List<Map<String, dynamic>> candidates,
  ) async {
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    const batch = 4;
    // Titles found last week: re-check them in a few bulk calls instead of
    // one search each.
    final knownIds = <String>[
      for (final c in candidates)
        if ((_matches['$type:${c['tmdbId']}'] ?? '').isNotEmpty)
          _matches['$type:${c['tmdbId']}']!,
    ];
    _verified.clear();
    for (var i = 0; i < knownIds.length; i += 50) {
      try {
        final res = await client.itemsApi.getItems(
          ids: knownIds.sublist(i, (i + 50).clamp(0, knownIds.length)),
          fields: _fields,
          enableTotalRecordCount: false,
          enableImageTypes: 'Primary',
          imageTypeLimit: 1,
        ).timeout(const Duration(seconds: 30));
        for (final r in (res['Items'] as List? ?? const []).whereType<Map<String, dynamic>>()) {
          final id = r['Id']?.toString();
          if (id != null) _verified[id] = r;
        }
      } catch (_) {}
    }
    for (var i = 0; i < candidates.length && out.length < itemsPerList; i += batch) {
      final slice = candidates.sublist(i, (i + batch).clamp(0, candidates.length));
      final results = await Future.wait(slice.map((c) => _find(client, type, c)));
      for (final r in results) {
        if (r == null) continue;
        final id = r['Id']?.toString() ?? '';
        if (id.isEmpty || !seen.add(id)) continue;
        out.add(r);
        if (out.length >= itemsPerList) break;
      }
    }
    return out;
  }

  static String _norm(String s) => s
      .toLowerCase()
      .replaceAll('&', 'and')
      .replaceAll(RegExp(r"[^a-z0-9]+"), ' ')
      .trim();

  /// The server item for a TMDB candidate, or null when the server doesn't
  /// have it. Matches the TMDB id first; title + year (±1) as a fallback for
  /// items without provider ids.
  Future<Map<String, dynamic>?> _find(
    MediaServerClient client,
    String type,
    Map<String, dynamic> c,
  ) async {
    final tmdbId = c['tmdbId']?.toString() ?? '';
    final memoKey = '$type:$tmdbId';
    final known = _matches[memoKey];
    if (known != null && known.isEmpty) return null; // known miss
    if (known != null && _verified.containsKey(known)) return _slim(_verified[known]!);
    final titles = <String>{
      c['title']?.toString() ?? '',
      c['originalTitle']?.toString() ?? '',
    }..removeWhere((t) => t.trim().isEmpty);
    final year = (c['year'] as num?)?.toInt();

    for (final title in titles) {
      Map<String, dynamic> res;
      try {
        res = await client.itemsApi.getItems(
          searchTerm: title,
          includeItemTypes: [type],
          recursive: true,
          limit: 15,
          fields: _fields,
          enableTotalRecordCount: false,
          enableImageTypes: 'Primary',
          imageTypeLimit: 1,
        ).timeout(const Duration(seconds: 20));
      } catch (_) {
        return null; // lookup failed: try again next week, don't record a miss
      }
      final items = (res['Items'] as List? ?? const []).whereType<Map<String, dynamic>>().toList();
      Map<String, dynamic>? hit;
      // 1. Same TMDB id.
      for (final r in items) {
        final ids = r['ProviderIds'];
        if (ids is Map && tmdbId.isNotEmpty) {
          final t = (ids['Tmdb'] ?? ids['tmdb'] ?? ids['TMDB'])?.toString();
          if (t == tmdbId) {
            hit = r;
            break;
          }
        }
      }
      // 2. Same title and year (±1).
      if (hit == null) {
        final want = _norm(title);
        for (final r in items) {
          if (_norm(r['Name']?.toString() ?? '') != want) continue;
          final y = (r['ProductionYear'] as num?)?.toInt();
          if (year == null || y == null || (y - year).abs() <= 1) {
            hit = r;
            break;
          }
        }
      }
      if (hit != null) {
        _matches[memoKey] = hit['Id']?.toString() ?? '';
        return _slim(hit);
      }
    }
    _matches[memoKey] = '';
    return null;
  }
}
