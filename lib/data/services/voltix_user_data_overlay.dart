import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';

import '../models/aggregated_item.dart';
import '../repositories/multi_server_repository.dart';
import 'voltix_favorites_registry_service.dart';
import 'voltix_api_service.dart';
import 'voltix_watch_registry_service.dart';
import '../../util/voltix_query_mode.dart';

/// Makes a shared Jellyfin account behave as if it belonged to the signed-in
/// Voltix user (and profile).
///
/// Every Voltix streaming server is one Jellyfin login shared by all Voltix
/// users, so the server's own favorites, Continue Watching, Next Up and
/// watched flags are everybody's. This interceptor sits on every media-server
/// connection and answers those from the user's own registries instead:
///
///  * Favorite / watched toggles are recorded in the user's registries and
///    never reach the shared account.
///  * Favorites queries (`IsFavorite=true`, `Filters=IsFavorite`) return only
///    this user's favorites.
///  * Resume (Continue Watching) and Next Up are built from this user's watch
///    history.
///  * Every response has this user's favorite / watched / progress state laid
///    over the shared account's `UserData`.
///
/// The registries are per Voltix username + profile, stored on the device and
/// backed up to Azure by `UserSettingsSyncService`.
class VoltixUserDataOverlay extends Interceptor {
  static final _favoriteWrite = RegExp(
    r'/(?:UserFavoriteItems|Users/[^/]+/FavoriteItems)/([^/]+)$',
    caseSensitive: false,
  );
  static final _playedWrite = RegExp(
    r'/(?:UserPlayedItems|Users/[^/]+/PlayedItems)/([^/]+)$',
    caseSensitive: false,
  );
  static final _resume = RegExp(
    r'/(?:UserItems|Users/[^/]+/Items)/Resume/?$',
    caseSensitive: false,
  );
  static final _nextUp = RegExp(r'/Shows/NextUp/?$', caseSensitive: false);
  static final _itemsQuery = RegExp(
    r'/(?:Users/[^/]+/)?Items/?$',
    caseSensitive: false,
  );

  /// Ids travel in the query string; Jellyfin's default request-line limit is
  /// 8 KB, which fits ~200 ids. The most recent favorites are kept.
  static const _maxIdsPerQuery = 200;
  static const _postFilterFavoritesKey = 'voltix_overlay_post_filter_favorites';
  static const _orderKey = 'voltix_overlay_order';
  static const _progressKey = 'voltix_overlay_progress';
  bool _progressInFlight = false;
  final Map<String, List<CancelToken>> _searchTokens = {};
  static const _totalKey = 'voltix_overlay_total';

  static const _playableTypes = {
    'movie', 'episode', 'video', 'musicvideo', 'trailer', 'audio', 'audiobook',
  };

  /// Plain client for the overlay's own look-ups. It carries the original
  /// request's headers (including the media-server token) but none of the
  /// client's interceptors, so it cannot re-enter this overlay.
  final Dio _side = Dio();

  VoltixWatchRegistryService? get _watch =>
      GetIt.instance.isRegistered<VoltixWatchRegistryService>()
          ? GetIt.instance<VoltixWatchRegistryService>()
          : null;

  VoltixFavoritesRegistryService? get _favorites =>
      GetIt.instance.isRegistered<VoltixFavoritesRegistryService>()
          ? GetIt.instance<VoltixFavoritesRegistryService>()
          : null;

  // ───────────────────────────── requests ─────────────────────────────

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_startedAtKey] = DateTime.now().millisecondsSinceEpoch;
    unawaited(_handleRequest(options, handler));
  }

  Future<void> _handleRequest(
    RequestOptions o,
    RequestInterceptorHandler h,
  ) async {
    final favorites = _favorites;
    final watch = _watch;
    if (favorites == null || watch == null) {
      h.next(o);
      return;
    }

    Response<dynamic>? answer;
    try {
      final path = o.uri.path;
      final method = o.method.toUpperCase();
      final isWrite = method == 'POST' || method == 'DELETE';

      // Search: when a newer search term arrives, cancel requests still
      // running for older terms. Typing on a TV remote fires a search per
      // letter; left running, they queued on the server and each new search
      // waited behind the old ones (6s, then 15s, then 22s).
      if (method == 'GET') {
        final term = _get(o.queryParameters, 'SearchTerm')?.toString();
        if (term != null) {
          _searchTokens.removeWhere((t, tokens) {
            if (t == term) return false;
            for (final c in tokens) {
              if (!c.isCancelled) c.cancel('superseded by a newer search');
            }
            return true;
          });
          final token = o.cancelToken ?? CancelToken();
          o.cancelToken = token;
          (_searchTokens[term] ??= <CancelToken>[]).add(token);
        }
      }

      // Progress reports: one at a time. While one is still waiting on a slow
      // server, newer ones are answered here instead of queueing behind it
      // (ten of them used to stack up and hold the connection slots).
      if (method == 'POST' && path.toLowerCase().endsWith('/sessions/playing/progress')) {
        if (_progressInFlight) {
          h.resolve(Response<dynamic>(requestOptions: o, statusCode: 204));
          return;
        }
        _progressInFlight = true;
        o.extra[_progressKey] = true;
      }

      final favoriteMatch = isWrite ? _favoriteWrite.firstMatch(path) : null;
      final playedMatch = isWrite ? _playedWrite.firstMatch(path) : null;

      if (favoriteMatch != null) {
        final id = Uri.decodeComponent(favoriteMatch.group(1)!);
        final isFavorite = method == 'POST';
        if (isFavorite) {
          if (!favorites.isFavorite(id)) {
            await favorites.addFavoriteById(id, _normalize(o.baseUrl));
          }
        } else {
          await favorites.removeFavoriteById(id);
        }
        answer = _ok(o, _userData(id, isFavorite: isFavorite));
      } else if (playedMatch != null) {
        final id = Uri.decodeComponent(playedMatch.group(1)!);
        final played = method == 'POST';
        unawaited(_recordPlayedToggle(o, id, played));
        answer = _ok(o, _userData(id, played: played));
      } else if (method == 'GET') {
        if (_resume.hasMatch(path)) {
          answer = await _resumeFor(o);
        } else if (_nextUp.hasMatch(path)) {
          answer = await _nextUpFor(o);
        } else if (_wantsFavorites(o.queryParameters)) {
          answer = _rewriteFavoritesQuery(o, path);
        } else if (_wantsPlayed(o.queryParameters) && _itemsQuery.hasMatch(path)) {
          answer = _rewritePlayedQuery(o);
        }
      }
    } catch (e) {
      debugPrint('[UserDataOverlay] ${o.method} ${o.uri.path} passed through: $e');
      answer = null;
    }

    if (answer != null) {
      h.resolve(answer);
      return;
    }
    if (o.method.toUpperCase() == 'GET' && o.responseType == ResponseType.json) {
      Response<dynamic>? shared;
      try {
        shared = await _shareGet(o);
      } catch (_) {
        shared = null;
      }
      if (shared != null) {
        h.resolve(shared);
        return;
      }
    }
    h.next(o);
  }

  // ─────────────────────── duplicate requests ───────────────────────
  //
  // Different parts of the home screen ask for the same thing at the same
  // moment (Users/Me and UserViews five times each at startup). On a slow
  // server each copy waited its turn in the connection queue. Identical GETs
  // in flight now share one request, and answers that rarely change are
  // reused for a few minutes. Shared answers get this user's own favorites /
  // watched state laid over them again when served, so they never go stale.

  static const _shareKey = 'voltix_overlay_share_key';
  final Map<String, Completer<Object?>> _inflight = {};
  final Map<String, ({Object data, int expiresAt})> _cache = {};

  Future<Response<dynamic>?> _shareGet(RequestOptions o) async {
    final key = '${o.uri}|${o.headers['Authorization'] ?? ''}';
    final now = DateTime.now().millisecondsSinceEpoch;
    final hit = _cache[key];
    if (hit != null) {
      if (hit.expiresAt > now) return _fromShared(o, hit.data);
      _cache.remove(key);
    }
    final pending = _inflight[key];
    if (pending != null) {
      final data = await pending.future;
      // The first request failed: send this one on its own.
      return data == null ? null : _fromShared(o, data);
    }
    _inflight[key] = Completer<Object?>();
    o.extra[_shareKey] = key;
    return null;
  }

  Response<dynamic> _fromShared(RequestOptions o, Object data) {
    final copy = jsonDecode(jsonEncode(data)) as Object;
    _overlay(copy);
    return _ok(o, copy);
  }

  void _finishShared(RequestOptions o, Object? data) {
    final key = o.extra[_shareKey];
    if (key is! String) return;
    final completer = _inflight.remove(key);
    if (data is! Map && data is! List) {
      completer?.complete(null);
      return;
    }
    final snapshot = jsonDecode(jsonEncode(data)) as Object;
    completer?.complete(snapshot);
    final ttl = _ttlFor(o.uri.path.toLowerCase());
    if (ttl > 0) {
      if (_cache.length > 200) _cache.clear();
      _cache[key] = (
        data: snapshot,
        expiresAt: DateTime.now().millisecondsSinceEpoch + ttl,
      );
    }
  }

  /// How long an answer may be reused, in ms. 0 = share in-flight only.
  static int _ttlFor(String path) {
    if (path.endsWith('/userviews') || path.endsWith('/users/me')) return 300000;
    if (RegExp(r'/users/[^/]+$').hasMatch(path)) return 300000;
    if (path.contains('/system/info') || path.contains('/system/configuration')) {
      return 600000;
    }
    if (path.endsWith('/genres') || path.endsWith('/studios')) return 600000;
    if (path.endsWith('/items/latest')) return 60000;
    if (path.contains('/displaypreferences/')) return 60000;
    return 0;
  }

  /// Rewrites a favorites query to this user's favorite ids. Returns an empty
  /// answer when the user has none, or null to send the (rewritten) request.
  Response<dynamic>? _rewriteFavoritesQuery(RequestOptions o, String path) {
    final qp = Map<String, dynamic>.from(o.queryParameters);
    _removeKey(qp, 'IsFavorite');
    final filtersKey = _keyOf(qp, 'Filters');
    if (filtersKey != null) {
      final remaining = _csv(qp[filtersKey])
          .where((f) => f.toLowerCase() != 'isfavorite')
          .toList();
      if (remaining.isEmpty) {
        qp.remove(filtersKey);
      } else {
        qp[filtersKey] = remaining.join(',');
      }
    }

    final ids = _favorites!.favoriteItemIdsByRecency(limit: _maxIdsPerQuery);
    if (ids.isEmpty) return _ok(o, _emptyPage());

    if (_itemsQuery.hasMatch(path)) {
      final idsKey = _keyOf(qp, 'Ids') ?? 'Ids';
      final requested = _csv(qp[idsKey]).toSet();
      final wanted = requested.isEmpty
          ? ids
          : ids.where(requested.contains).toList();
      if (wanted.isEmpty) return _ok(o, _emptyPage());
      qp[idsKey] = wanted.join(',');
    } else {
      // Endpoints without an Ids filter (Live TV channels, genres...): ask
      // without the favorite filter and keep only this user's favorites.
      o.extra[_postFilterFavoritesKey] = true;
    }
    o.queryParameters = qp;
    return null;
  }

  /// "Watched" queries (Filters=IsPlayed / IsPlayed=true) answered from this
  /// user's history: the shared account's played list is everybody's, and
  /// scanning it with cast lists was one of the slowest home-screen calls.
  /// Fetches exactly the titles this user watched, by id, newest first.
  Response<dynamic>? _rewritePlayedQuery(RequestOptions o) {
    final qp = Map<String, dynamic>.from(o.queryParameters);
    _removeKey(qp, 'IsPlayed');
    final filtersKey = _keyOf(qp, 'Filters');
    if (filtersKey != null) {
      final remaining = _csv(qp[filtersKey])
          .where((f) => f.toLowerCase() != 'isplayed')
          .toList();
      if (remaining.isEmpty) {
        qp.remove(filtersKey);
      } else {
        qp[filtersKey] = remaining.join(',');
      }
    }
    final types = _csv(_get(qp, 'IncludeItemTypes'))
        .map((t) => t.toLowerCase())
        .toSet();
    final all = _watch!.playedItemIds(types: types);
    final start = _int(_get(qp, 'StartIndex')) ?? 0;
    final limit = (_int(_get(qp, 'Limit')) ?? all.length).clamp(0, _maxIdsPerQuery);
    final page = all.skip(start).take(limit).toList();
    if (page.isEmpty) return _ok(o, _emptyPage(total: all.length, start: start));

    _removeKey(qp, 'StartIndex');
    _removeKey(qp, 'Limit');
    qp[_keyOf(qp, 'Ids') ?? 'Ids'] = page.join(',');
    o.queryParameters = qp;
    o.extra[_orderKey] = page;
    o.extra[_totalKey] = all.length;
    return null;
  }

  bool _wantsPlayed(Map<String, dynamic> qp) {
    final isPlayed = _get(qp, 'IsPlayed');
    if (isPlayed == true || isPlayed?.toString().toLowerCase() == 'true') return true;
    return _csv(_get(qp, 'Filters')).any((f) => f.toLowerCase() == 'isplayed');
  }

  /// Continue Watching from this user's history.
  Future<Response<dynamic>> _resumeFor(RequestOptions o) async {
    final qp = o.queryParameters;
    final limit = _int(_get(qp, 'Limit')) ?? 50;
    final start = _int(_get(qp, 'StartIndex')) ?? 0;
    final types = _csv(_get(qp, 'IncludeItemTypes'))
        .map((t) => t.toLowerCase())
        .toSet();
    final all = _watch!.inProgressItemIds(types: types);
    final page = all.skip(start).take(limit).toList();
    if (page.isEmpty) return _ok(o, _emptyPage(total: all.length, start: start));

    try {
      final parentId = _get(qp, 'ParentId');
      final response = await _side.fetch<dynamic>(o.copyWith(
        path: o.path
            .replaceFirst(RegExp(r'UserItems/Resume/?$', caseSensitive: false), 'Items')
            .replaceFirst(RegExp(r'Items/Resume/?$', caseSensitive: false), 'Items'),
        queryParameters: {
          ..._pick(qp, const ['Fields', 'EnableImageTypes', 'ImageTypeLimit', 'UserId']),
          'Ids': page.join(','),
          if (parentId != null) 'ParentId': parentId,
          if (parentId != null) 'Recursive': true,
        },
      ));
      final items = _itemsOf(response.data);
      final order = {for (var i = 0; i < page.length; i++) page[i]: i};
      items.sort((a, b) => (order[a['Id']] ?? 1 << 30).compareTo(order[b['Id']] ?? 1 << 30));
      final data = {'Items': items, 'TotalRecordCount': all.length, 'StartIndex': start};
      _overlay(data);
      return _ok(o, data);
    } catch (e) {
      debugPrint('[UserDataOverlay] resume look-up failed: $e');
      return _ok(o, _emptyPage());
    }
  }

  /// Next Up from this user's history: the episode after the last one they
  /// finished, per series.
  Future<Response<dynamic>> _nextUpFor(RequestOptions o) async {
    final qp = o.queryParameters;
    final limit = _int(_get(qp, 'Limit')) ?? 24;
    final seriesFilter = _get(qp, 'SeriesId')?.toString();
    final watch = _watch!;
    final byId = watch.entriesByItemId();

    var watched = watch.latestCompletedEpisodePerSeries();
    if (seriesFilter != null && seriesFilter.isNotEmpty) {
      watched = watched.where((e) => e.seriesId == seriesFilter).toList();
    }
    // One episode-list request per series: cap at 12 series to keep Next Up
    // light on the shared server.
    watched = watched.take(kFullHomeQueries ? limit : (limit < 12 ? limit : 12)).toList();
    if (watched.isEmpty) return _ok(o, _emptyPage());

    final passThrough =
        _pick(qp, const ['Fields', 'EnableImageTypes', 'ImageTypeLimit', 'UserId']);

    int rank(Map<String, dynamic> e) =>
        ((e['ParentIndexNumber'] as int? ?? 0) * 10000) +
        (e['IndexNumber'] as int? ?? 0);

    final picks = await Future.wait(watched.map((entry) async {
      try {
        final response = await _side.fetch<dynamic>(o.copyWith(
          path: o.path.replaceFirst(
            RegExp(r'Shows/NextUp/?$', caseSensitive: false),
            'Shows/${entry.seriesId}/Episodes',
          ),
          queryParameters: passThrough,
        ));
        final episodes = _itemsOf(response.data)
          ..sort((a, b) => rank(a).compareTo(rank(b)));
        final watchedRank =
            ((entry.seasonNumber ?? 0) * 10000) + (entry.episodeNumber ?? 0);
        for (final e in episodes) {
          if ((e['ParentIndexNumber'] as int? ?? 0) <= 0) continue; // specials
          if (rank(e) <= watchedRank) continue;
          if (byId[e['Id']]?.isPlayed ?? false) continue;
          return e;
        }
      } catch (_) {
        // Series not on this server, or unreachable: no Next Up for it here.
      }
      return null;
    }));

    final items = picks.whereType<Map<String, dynamic>>().toList();
    final data = {'Items': items, 'TotalRecordCount': items.length, 'StartIndex': 0};
    _overlay(data);
    return _ok(o, data);
  }

  /// Records a watched / unwatched toggle in this user's history. Series and
  /// seasons are expanded to their episodes so Next Up follows.
  Future<void> _recordPlayedToggle(RequestOptions o, String id, bool played) async {
    final watch = _watch;
    if (watch == null) return;
    try {
      final server = await _serverFor(o);
      const fields = 'Genres,People,Studios,Overview,ProviderIds,SeriesId,'
          'SeasonId,RunTimeTicks,ImageTags,BackdropImageTags';
      final itemResponse = await _side.fetch<dynamic>(o.copyWith(
        method: 'GET',
        path: '/Items/$id',
        queryParameters: {'Fields': fields},
        data: null,
      ));
      final raw = itemResponse.data;
      if (raw is! Map<String, dynamic>) return;
      final type = (raw['Type'] as String? ?? '').toLowerCase();

      var targets = <Map<String, dynamic>>[raw];
      if (type == 'series' || type == 'season') {
        final seriesId = type == 'series' ? id : raw['SeriesId']?.toString();
        if (seriesId == null || seriesId.isEmpty) return;
        final episodes = await _side.fetch<dynamic>(o.copyWith(
          method: 'GET',
          path: '/Shows/$seriesId/Episodes',
          queryParameters: {
            'Fields': fields,
            if (type == 'season') 'SeasonId': id,
          },
          data: null,
        ));
        targets = _itemsOf(episodes.data);
      }

      for (final t in targets) {
        final itemId = t['Id']?.toString() ?? '';
        if (itemId.isEmpty) continue;
        await watch.setPlayed(
          AggregatedItem(
            id: itemId,
            serverId: server.id,
            serverName: server.name,
            rawData: t,
          ),
          played,
        );
      }
    } catch (e) {
      debugPrint('[UserDataOverlay] could not record played=$played for $id: $e');
    }
  }

  // ───────────────────────────── responses ─────────────────────────────

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.type != DioExceptionType.cancel) _report(
      err.requestOptions,
      stage: 'jf-error',
      status: err.response?.statusCode,
      error: err.type.name,
    );
    _finishShared(err.requestOptions, null);
    if (err.requestOptions.extra[_progressKey] == true) _progressInFlight = false;
    handler.next(err);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    _report(response.requestOptions, stage: 'jf-slow', status: response.statusCode);
    if (response.requestOptions.extra[_progressKey] == true) _progressInFlight = false;
    try {
      final data = response.data;
      if (response.requestOptions.extra[_postFilterFavoritesKey] == true &&
          data is Map && data['Items'] is List) {
        final favoriteIds = _favorites?.favoriteItemIdSet() ?? const <String>{};
        final kept = (data['Items'] as List)
            .whereType<Map>()
            .where((i) => favoriteIds.contains(i['Id']?.toString()))
            .toList();
        data['Items'] = kept;
        data['TotalRecordCount'] = kept.length;
      }
      final order = response.requestOptions.extra[_orderKey];
      if (order is List && data is Map && data['Items'] is List) {
        final rank = {for (var i = 0; i < order.length; i++) order[i]: i};
        final items = (data['Items'] as List).whereType<Map>().toList()
          ..sort((a, b) => (rank[a['Id']] ?? 1 << 30).compareTo(rank[b['Id']] ?? 1 << 30));
        data['Items'] = items;
        final total = response.requestOptions.extra[_totalKey];
        if (total is int) data['TotalRecordCount'] = total;
      }
      _overlay(data);
      _finishShared(response.requestOptions, data);
    } catch (e) {
      debugPrint('[UserDataOverlay] overlay skipped: $e');
      _finishShared(response.requestOptions, null);
    }
    handler.next(response);
  }

  /// Replaces the shared account's UserData with this user's.
  void _overlay(dynamic data) {
    final favorites = _favorites;
    final watch = _watch;
    if (favorites == null || watch == null) return;

    final items = <Map>[];
    if (data is Map) {
      if (data['Items'] is List) {
        items.addAll((data['Items'] as List).whereType<Map>());
      } else if (data.containsKey('Id') && data['UserData'] is Map) {
        items.add(data);
      }
    } else if (data is List) {
      items.addAll(data.whereType<Map>());
    }
    if (items.isEmpty) return;

    final favoriteIds = favorites.favoriteItemIdSet();
    final history = watch.entriesByItemId();

    for (final item in items) {
      final userData = item['UserData'];
      if (userData is! Map) continue;
      final id = item['Id']?.toString() ?? '';
      final type = (item['Type'] as String? ?? '').toLowerCase();
      final ud = Map<String, dynamic>.from(userData);
      ud['IsFavorite'] = favoriteIds.contains(id);

      if (_playableTypes.contains(type)) {
        final entry = history[id];
        if (entry != null) {
          ud['Played'] = entry.isPlayed;
          ud['PlaybackPositionTicks'] = entry.isPlayed ? 0 : entry.playbackPositionTicks;
          ud['PlayedPercentage'] = entry.isPlayed ? 100.0 : entry.progressPercent;
          ud['PlayCount'] = entry.playCount;
          ud['LastPlayedDate'] = entry.lastWatchedAt.toUtc().toIso8601String();
        } else {
          ud['Played'] = false;
          ud['PlaybackPositionTicks'] = 0;
          ud['PlayCount'] = 0;
          ud.remove('PlayedPercentage');
          ud.remove('LastPlayedDate');
        }
      } else {
        // Series / seasons / folders: the shared account's aggregate watched
        // state and unwatched counts are everybody's, so drop them.
        ud['Played'] = false;
        ud.remove('PlayedPercentage');
        ud.remove('UnplayedItemCount');
        ud.remove('LastPlayedDate');
      }
      item['UserData'] = ud;
    }
  }

  // ─────────────────────────── diagnostics ───────────────────────────

  static const _startedAtKey = 'voltix_overlay_started_at';

  /// A request slower than this is reported as `jf-slow`.
  static const _slowMs = 1500;

  /// At most this many beacons per minute, so a bad minute cannot flood the
  /// backend.
  static const _maxBeaconsPerMinute = 60;
  int _beaconWindowStart = 0;
  int _beaconCount = 0;

  /// Sends failed and slow Jellyfin requests to the Voltix backend as
  /// `GET /api/diag/direct-streaming?stage=jf-error|jf-slow&...`, so direct
  /// streaming is visible in the Azure Log stream without proxying any media
  /// traffic. Path only: no query string, token or user data is sent.
  void _report(
    RequestOptions o, {
    required String stage,
    int? status,
    String? error,
  }) {
    try {
      final started = o.extra[_startedAtKey];
      if (started is! int) return;
      final ms = DateTime.now().millisecondsSinceEpoch - started;
      if (stage == 'jf-slow' && ms < _slowMs) return;

      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _beaconWindowStart > 60000) {
        _beaconWindowStart = now;
        _beaconCount = 0;
      }
      if (++_beaconCount > _maxBeaconsPerMinute) return;

      if (!GetIt.instance.isRegistered<VoltixApiService>()) return;
      GetIt.instance<VoltixApiService>().directStreamingDiag(stage, {
        'method': o.method,
        'host': o.uri.host,
        'path': o.uri.path,
        'q': _queryHint(o.queryParameters),
        'ms': '$ms',
        if (status != null) 'status': '$status',
        if (error != null) 'error': error,
      });
    } catch (_) {
      // Diagnostics must never affect the request.
    }
  }

  /// Which kind of query this was (sort, types, filters, limit, field
  /// count), without ids or search text, so slow requests can be told apart.
  static String _queryHint(Map<String, dynamic> qp) {
    final parts = <String>[];
    for (final k in const ['SortBy', 'IncludeItemTypes', 'Filters', 'Limit', 'Recursive', 'Genres']) {
      final v = _get(qp, k);
      if (v != null) parts.add('$k=${v is List ? v.join(',') : v}');
    }
    for (final k in const ['ParentId', 'Ids', 'PersonIds', 'SearchTerm', 'SeriesId']) {
      if (_get(qp, k) != null) parts.add('$k=1');
    }
    final fields = _get(qp, 'Fields');
    if (fields != null) parts.add('Fields=${_csv(fields).length}');
    final hint = parts.join(';');
    return hint.length > 200 ? hint.substring(0, 200) : hint;
  }

  // ───────────────────────────── helpers ─────────────────────────────

  Future<({String id, String? name})> _serverFor(RequestOptions o) async {
    final base = _normalize(o.baseUrl);
    try {
      if (GetIt.instance.isRegistered<MultiServerRepository>()) {
        final sessions =
            await GetIt.instance<MultiServerRepository>().getLoggedInServers();
        for (final s in sessions) {
          if (_normalize(s.client.baseUrl) == base) {
            return (id: s.server.id, name: s.server.name);
          }
        }
      }
    } catch (_) {}
    return (id: base, name: null);
  }

  Map<String, dynamic> _userData(String id, {bool? isFavorite, bool? played}) {
    final favorite = isFavorite ?? (_favorites?.isFavorite(id) ?? false);
    final entry = _watch?.entriesByItemId()[id];
    final isPlayed = played ?? (entry?.isPlayed ?? false);
    return {
      'IsFavorite': favorite,
      'Played': isPlayed,
      'PlaybackPositionTicks': isPlayed ? 0 : (entry?.playbackPositionTicks ?? 0),
      'PlayCount': entry?.playCount ?? (isPlayed ? 1 : 0),
      'Key': id,
      'ItemId': id,
    };
  }

  Response<dynamic> _ok(RequestOptions o, Object data) =>
      Response<dynamic>(requestOptions: o, statusCode: 200, data: data);

  Map<String, dynamic> _emptyPage({int total = 0, int start = 0}) =>
      {'Items': <dynamic>[], 'TotalRecordCount': total, 'StartIndex': start};

  List<Map<String, dynamic>> _itemsOf(dynamic data) {
    final raw = data is Map ? data['Items'] : data;
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
  }

  bool _wantsFavorites(Map<String, dynamic> qp) {
    final isFav = _get(qp, 'IsFavorite');
    if (isFav == true || isFav?.toString().toLowerCase() == 'true') return true;
    return _csv(_get(qp, 'Filters')).any((f) => f.toLowerCase() == 'isfavorite');
  }

  static String? _keyOf(Map<String, dynamic> qp, String key) {
    final lower = key.toLowerCase();
    for (final k in qp.keys) {
      if (k.toLowerCase() == lower) return k;
    }
    return null;
  }

  static dynamic _get(Map<String, dynamic> qp, String key) {
    final k = _keyOf(qp, key);
    return k == null ? null : qp[k];
  }

  static void _removeKey(Map<String, dynamic> qp, String key) {
    final k = _keyOf(qp, key);
    if (k != null) qp.remove(k);
  }

  static Map<String, dynamic> _pick(Map<String, dynamic> qp, List<String> keys) {
    final out = <String, dynamic>{};
    for (final key in keys) {
      final k = _keyOf(qp, key);
      if (k != null && qp[k] != null) out[k] = qp[k];
    }
    return out;
  }

  static List<String> _csv(dynamic value) {
    if (value == null) return const [];
    if (value is List) {
      return value.map((v) => v.toString().trim()).where((v) => v.isNotEmpty).toList();
    }
    return value
        .toString()
        .split(',')
        .map((v) => v.trim())
        .where((v) => v.isNotEmpty)
        .toList();
  }

  static int? _int(dynamic value) =>
      value is int ? value : int.tryParse(value?.toString() ?? '');

  static String _normalize(String url) =>
      url.trim().toLowerCase().replaceAll(RegExp(r'/+$'), '');
}
