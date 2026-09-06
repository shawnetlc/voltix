import 'dart:async';

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:get_it/get_it.dart';

import '../../auth/store/voltix_session_store.dart';
import '../models/dstv/dstv_epg_models.dart';
import '../models/iptv_models.dart';
import '../services/voltix_api_service.dart';
import 'dstv_epg_repository.dart';

/// Thrown for IPTV backend failures that should be surfaced inline in the UI.
///
/// Transient errors (network hiccups, 5xx) are retried with backoff before
/// this is thrown; authentication (401) is handled globally by the
/// [VoltixApiService] logout interceptor and never triggers a retry here.
class VoltixIptvException implements Exception {
  final String message;
  const VoltixIptvException(this.message);
  @override
  String toString() => 'VoltixIptvException: $message';
}

/// Typed repository over the Voltix backend IPTV API (`server/iptvProxy.ts`).
///
/// Endpoints used (all authenticated with `Authorization: Bearer <token>`):
///   GET    /api/iptv/categories?type=live|vod|series
///   GET    /api/iptv/content?type=&categoryId=&limit=&offset=&search=
///   GET    /api/iptv/epg/simple?streamId=&epgChannelId=&channelName=
///   GET    /api/iptv/series-info?seriesId=&seriesName=
///   GET    /api/favorites?type=          POST/DELETE /api/favorites
///   GET    /api/iptv/stream/{live|movie|series}/{id}?token=  (playback URL)
class VoltixIptvRepository {
  final VoltixApiService _api;
  final VoltixSessionStore _store;

  VoltixIptvRepository({VoltixApiService? api, VoltixSessionStore? store})
      : _api = api ?? GetIt.instance<VoltixApiService>(),
        _store = store ?? GetIt.instance<VoltixSessionStore>();

  String get _token => _store.sessionToken ?? '';

  bool get hasSession => _token.isNotEmpty;

  // ── In-memory stale-while-revalidate cache ─────────────────────────────────
  //
  // Keyed by section + categoryId + offset (content), section (categories,
  // favourites) and channel streamId (EPG). On a repeat request fresh-enough
  // data is returned immediately (no network); the screen additionally uses the
  // synchronous [peek*] helpers to paint cached data on the first frame while a
  // background refresh revalidates. Bounded LRU-ish to stay light on ~1GB TVs.
  static const Duration _ttlCategories = Duration(minutes: 10);
  static const Duration _ttlContent = Duration(minutes: 3);
  static const Duration _ttlFavorites = Duration(minutes: 3);
  static const Duration _ttlEpg = Duration(minutes: 2);
  static const Duration _reqTimeout = Duration(seconds: 20);
  static const int _cacheCap = 120;

  final Map<String, _CacheEntry> _cache = <String, _CacheEntry>{};

  String _catKey(IptvSection s) => 'cat|${s.apiType}';
  String _favKey(IptvSection s) => 'fav|${s.apiType}';
  String _contentKey(
          IptvSection s, String cat, int offset, int limit, String? search) =>
      'content|${s.apiType}|$cat|$offset|$limit|${search?.trim() ?? ''}';
  String _epgKey(String streamId) => 'epg|$streamId';

  T? _cacheGet<T>(String key, Duration ttl, {bool allowStale = false}) {
    final entry = _cache.remove(key);
    if (entry == null) return null;
    _cache[key] = entry; // re-insert at tail (LRU touch)
    final age = DateTime.now().millisecondsSinceEpoch - entry.ts;
    if (!allowStale && age > ttl.inMilliseconds) return null;
    final v = entry.value;
    return v is T ? v as T : null;
  }

  void _cachePut(String key, Object value) {
    _cache.remove(key);
    _cache[key] = _CacheEntry(value, DateTime.now().millisecondsSinceEpoch);
    while (_cache.length > _cacheCap) {
      _cache.remove(_cache.keys.first); // trim oldest
    }
  }

  void _invalidateFavorites(IptvSection s) {
    _cache.remove(_favKey(s));
    _cache.removeWhere((k, _) => k.startsWith('content|${s.apiType}|favorites|'));
  }

  /// Synchronous cached snapshots (stale allowed) for instant first paint.
  IptvContentPage? peekContent(
    IptvSection section, {
    String categoryId = 'all',
    int offset = 0,
    int limit = 60,
    String? search,
  }) =>
      _cacheGet<IptvContentPage>(
          _contentKey(section, categoryId, offset, limit, search), _ttlContent,
          allowStale: true);

  List<IptvCategory>? peekCategories(IptvSection section) =>
      _cacheGet<List<IptvCategory>>(_catKey(section), _ttlCategories,
          allowStale: true);

  Set<String>? peekFavorites(IptvSection section) =>
      _cacheGet<Set<String>>(_favKey(section), _ttlFavorites, allowStale: true);

  // ── Retry with backoff (transient errors only — never on 401/403) ──────────

  static const List<Duration> _backoff = [
    Duration(milliseconds: 400),
    Duration(milliseconds: 1200),
  ];

  Future<T> _withRetry<T>(Future<T> Function() run, String label) async {
    Object? lastError;
    for (var attempt = 0; attempt <= _backoff.length; attempt++) {
      try {
        return await run();
      } on DioException catch (e) {
        // Cancelled requests (section/category switch) are no-ops: never retry
        // and never surface as an error to the caller.
        if (e.type == DioExceptionType.cancel) {
          throw const VoltixIptvException('cancelled');
        }
        final status = e.response?.statusCode;
        if (status == 401 || status == 403) {
          // Auth/suspension — handled by the VoltixApiService interceptor
          // (401) or surfaced immediately (403). Never retry.
          throw VoltixIptvException(_messageFor(e));
        }
        lastError = e;
        if (attempt < _backoff.length) {
          await Future<void>.delayed(_backoff[attempt]);
        }
      }
    }
    final msg = lastError is DioException
        ? _messageFor(lastError)
        : 'Request failed';
    throw VoltixIptvException('$label: $msg');
  }

  static String _messageFor(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['error'] is String) return data['error'] as String;
    final status = e.response?.statusCode;
    if (status != null) return 'Server error ($status)';
    return 'Network error';
  }

  // ── Categories ─────────────────────────────────────────────────────────────

  /// Categories for [section]. The backend already prepends the
  /// `Favorites` and `All` pseudo-categories.
  Future<List<IptvCategory>> getCategories(
    IptvSection section, {
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) {
    final key = _catKey(section);
    if (!forceRefresh) {
      final cached = _cacheGet<List<IptvCategory>>(key, _ttlCategories);
      if (cached != null) return Future.value(cached);
    }
    return _withRetry(() async {
      final data = await _api.restGet(
        '/api/iptv/categories',
        query: {'type': section.apiType},
        sessionToken: _token,
        cancelToken: cancelToken,
        timeout: _reqTimeout,
      );
      final items = (data is Map ? data['items'] : null) as List? ?? const [];
      final result = items
          .whereType<Map<String, dynamic>>()
          .map(IptvCategory.fromJson)
          .toList(growable: false);
      _cachePut(key, result);
      return result;
    }, 'Categories');
  }

  Future<List<IptvCategory>> getLiveCategories() =>
      getCategories(IptvSection.live);

  // ── Content (channels / movies / series) ───────────────────────────────────

  Future<IptvContentPage> getContent(
    IptvSection section, {
    String categoryId = 'all',
    int offset = 0,
    int limit = 60,
    String? search,
    bool forceRefresh = false,
    CancelToken? cancelToken,
  }) {
    final key = _contentKey(section, categoryId, offset, limit, search);
    if (!forceRefresh) {
      final cached = _cacheGet<IptvContentPage>(key, _ttlContent);
      if (cached != null) return Future.value(cached);
    }
    return _withRetry(() async {
      final data = await _api.restGet(
        '/api/iptv/content',
        query: {
          'type': section.apiType,
          'categoryId': categoryId,
          'offset': '$offset',
          'limit': '$limit',
          if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
        },
        sessionToken: _token,
        cancelToken: cancelToken,
        timeout: _reqTimeout,
      );
      if (data is! Map<String, dynamic>) {
        throw DioException(
          requestOptions: RequestOptions(path: '/api/iptv/content'),
          message: 'Unexpected response',
        );
      }
      final page = IptvContentPage.fromJson(data);
      _cachePut(key, page);
      return page;
    }, 'Content');
  }

  Future<IptvContentPage> getLiveChannels({
    String categoryId = 'all',
    int offset = 0,
    int limit = 60,
    String? search,
  }) =>
      getContent(IptvSection.live,
          categoryId: categoryId, offset: offset, limit: limit, search: search);

  Future<IptvContentPage> getVodMovies({
    String categoryId = 'all',
    int offset = 0,
    int limit = 60,
    String? search,
  }) =>
      getContent(IptvSection.movies,
          categoryId: categoryId, offset: offset, limit: limit, search: search);

  Future<IptvContentPage> getSeries({
    String categoryId = 'all',
    int offset = 0,
    int limit = 60,
    String? search,
  }) =>
      getContent(IptvSection.series,
          categoryId: categoryId, offset: offset, limit: limit, search: search);

  /// Every archive-capable live channel, as one flat list.
  ///
  /// Backed by `/api/iptv/catchup/channels`, which is the same endpoint the
  /// web player's Catch Up section uses -- deliberately, so the two show the
  /// same channels.
  ///
  /// The screen used to assemble this itself by walking every live category
  /// and keeping whatever came back with `hasArchive`. That produced a
  /// different list from the website, because the website's list is not a raw
  /// `hasArchive` filter: the backend also drops foreign-language duplicates,
  /// applies the account's package quality limits, collapses a channel's
  /// quality variants down to the sharpest one, and treats a channel as
  /// archive-capable when the provider exposes an archive variant under a
  /// separate stream id -- which a `tv_archive` flag check on its own misses.
  /// Reproducing four server-side rules in the client would only mean two
  /// implementations to keep in step, so the client asks for the answer.
  ///
  /// It is also one request instead of a scan that pages through every
  /// category to exhaustion.
  Future<List<IptvContentItem>> getCatchupChannels({
    bool forceRefresh = false,
  }) {
    const key = 'catchup_channels';
    if (!forceRefresh) {
      final cached = _cacheGet<List<IptvContentItem>>(key, _ttlContent);
      if (cached != null) return Future.value(cached);
    }
    return _withRetry(() async {
      final data = await _api.restGet(
        '/api/iptv/catchup/channels',
        sessionToken: _token,
        timeout: _reqTimeout,
      );
      final rawItems = (data is Map ? data['items'] : null) as List? ?? const [];
      final items = rawItems
          .whereType<Map<String, dynamic>>()
          .map(IptvContentItem.fromJson)
          .toList(growable: false);
      _cachePut(key, items);
      return items;
    }, 'CatchupChannels');
  }

  /// In-memory cache for DStv programme thumbnails (channel/programme key -> iconUrl)
  static final Map<String, String> _dstvThumbCache = <String, String>{};

  /// Returns cached thumbnail / poster URL for a channel or programme.
  static String? getCachedThumbnail(String channelOrProgramme) {
    final key = channelOrProgramme.toLowerCase().trim();
    return _dstvThumbCache[key];
  }

  static bool _containsCyrillic(String text) =>
      RegExp(r'[\u0400-\u04FF]').hasMatch(text);

  /// Now/next guide data for a live [channel], deduplicated by
  /// start-timestamp + title and limited to programmes that end after now
  /// and start within [window] (default 4 hours).
  ///
  /// Defaults to provider guide ('provider'), enriched with DStv programme artwork.
  Future<List<IptvEpgEntry>> getSimpleEpg(
    IptvContentItem channel, {
    Duration window = const Duration(hours: 2),
    bool forceRefresh = false,
    /// 'dstv', 'provider', or 'auto'. Defaults to 'provider' with DStv thumbnail data.
    String? source,
  }) {
    final streamId = channel.streamId?.toString() ?? channel.id;
    final effectiveSource = source ?? 'provider';
    final key = _epgKey('${streamId}_$effectiveSource');
    if (!forceRefresh) {
      final cached = _cacheGet<List<IptvEpgEntry>>(key, _ttlEpg);
      if (cached != null) return Future.value(cached);
    }
    return _withRetry(() async {
      final data = await _api.restGet(
        '/api/iptv/epg/simple',
        query: {
          'streamId': streamId,
          if (channel.epgChannelId != null && channel.epgChannelId!.isNotEmpty)
            'epgChannelId': channel.epgChannelId,
          'channelName': channel.title,
          if (effectiveSource.isNotEmpty) 'source': effectiveSource,
        },
        sessionToken: _token,
        timeout: _reqTimeout,
      );
      final items = (data is Map ? data['items'] : null) as List? ?? const [];
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final horizon = now + window.inSeconds;

      final seen = <String>{};
      final result = <IptvEpgEntry>[];
      final channelKey = channel.title.toLowerCase();
      for (final raw in items.whereType<Map<String, dynamic>>()) {
        var entry = IptvEpgEntry.fromJson(raw);
        if (!entry.hasTimes) continue;
        if (entry.stopTimestamp! <= now) continue; // already finished
        if (entry.startTimestamp! >= horizon) continue; // beyond window
        if (!seen.add(entry.dedupeKey)) continue; // dedupe start+title

        // Skip Russian mis-mapped entries on South African / English channels
        if (_containsCyrillic(entry.title) || _containsCyrillic(entry.description)) {
          continue;
        }

        // If using provider EPG and icon is empty, check DStv artwork cache.
        if (entry.icon == null || entry.icon!.isEmpty) {
          final progTitle = entry.title.toLowerCase();
          final cachedIcon = _dstvThumbCache['${channelKey}_$progTitle'] ??
              _dstvThumbCache[channelKey] ??
              _dstvThumbCache[progTitle];
          if (cachedIcon != null && cachedIcon.isNotEmpty) {
            entry = entry.copyWith(icon: cachedIcon);
          }
        } else if (entry.icon != null && entry.icon!.isNotEmpty) {
          _dstvThumbCache['${channelKey}_${entry.title.toLowerCase()}'] = entry.icon!;
          _dstvThumbCache[channelKey] = entry.icon!;
        }

        result.add(entry);
      }

      // If provider guide had no icons, trigger a lightweight DStv thumbnail lookup in background
      if (effectiveSource == 'provider' &&
          result.isNotEmpty &&
          result.every((e) => e.icon == null || e.icon!.isEmpty)) {
        _enrichThumbnailsFromDstv(channel, streamId);
      }

      result.sort((a, b) => a.startTimestamp!.compareTo(b.startTimestamp!));
      _cachePut(key, result);
      return result;
    }, 'Guide');
  }

  static String _sanitizeTitle(String title, String channelTitle) {
    if (!_containsCyrillic(title) && title.trim().isNotEmpty) {
      return title.trim();
    }

    final cleanCh = DstvEpgRepository.normalizeChannelName(channelTitle);
    if (cleanCh.contains('movie') ||
        cleanCh.contains('m net') ||
        cleanCh.contains('mnet') ||
        cleanCh.contains('cinema')) {
      return 'Feature Presentation';
    }
    if (cleanCh.contains('sport') ||
        cleanCh.contains('ss ') ||
        cleanCh.contains('psl') ||
        cleanCh.contains('premier') ||
        cleanCh.contains('league') ||
        cleanCh.contains('rugby') ||
        cleanCh.contains('cricket') ||
        cleanCh.contains('football')) {
      return 'Sports Match Replay';
    }
    if (cleanCh.contains('news') ||
        cleanCh.contains('enca') ||
        cleanCh.contains('sabc')) {
      return 'News Bulletin';
    }
    if (cleanCh.contains('magic') ||
        cleanCh.contains('am ') ||
        cleanCh.contains('mzansi') ||
        cleanCh.contains('kyknet')) {
      return 'Drama Series';
    }
    final cleanName = channelTitle
        .replaceAll(RegExp(r'\s*\[.*?\]\s*'), '')
        .replaceAll(RegExp(r'\b(za|dstv)\s*[:\-_]\s*', caseSensitive: false), '')
        .trim();
    return cleanName.isNotEmpty ? '$cleanName Broadcast' : 'Channel Replay';
  }

  /// Past programmes for a live [channel] that support catch-up playback,
  /// most recent first, going back [lookback] (24h).
  ///
  /// Maps to official DStv English TV guide directly when available, matches
  /// replayable stream slots, and replaces any Russian provider XMLTV with
  /// clean English titles & thumbnails.
  Future<List<IptvEpgEntry>> getCatchupEpg(
    IptvContentItem channel, {
    Duration lookback = const Duration(hours: 72),
    String? source,
  }) async {
    final streamId = channel.catchupStreamId;
    final effectiveSource = source ?? 'provider';
    final key = 'catchup|${streamId}_$effectiveSource';
    final cached = _cacheGet<List<IptvEpgEntry>>(key, _ttlEpg);
    if (cached != null) return cached;

    DstvEpgRepository? dstvRepo;
    DstvChannel? dstvChannel;
    List<IptvEpgEntry>? dstvProgs;
    try {
      if (GetIt.instance.isRegistered<DstvEpgRepository>()) {
        dstvRepo = GetIt.instance<DstvEpgRepository>();
        dstvChannel = await dstvRepo.findMatchingChannel(
          channel.title,
          channelNumber: channel.channelNumber,
        );
        if (dstvChannel != null) {
          final icon = dstvChannel.thumbnailUrl ?? dstvChannel.logo;
          if (icon != null && icon.isNotEmpty) {
            _dstvThumbCache[channel.title.toLowerCase()] = icon;
            _dstvThumbCache[DstvEpgRepository.normalizeChannelName(channel.title)] = icon;
          }
          dstvProgs = await dstvRepo.getCatchupProgrammesForDstvChannel(
            dstvChannel,
            lookback: lookback,
          );
        }
      }
    } catch (_) {}

    return _withRetry(() async {
      final data = await _api.restGet(
        '/api/iptv/epg/simple',
        query: {
          'streamId': streamId,
          if (channel.epgChannelId != null && channel.epgChannelId!.isNotEmpty)
            'epgChannelId': channel.epgChannelId,
          'channelName': channel.title,
          if (effectiveSource.isNotEmpty) 'source': effectiveSource,
        },
        sessionToken: _token,
        timeout: _reqTimeout,
      );
      final items = (data is Map ? data['items'] : null) as List? ?? const [];
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final earliest = now - lookback.inSeconds;

      final seen = <String>{};
      final result = <IptvEpgEntry>[];
      final channelKey = channel.title.toLowerCase();
      final defaultIcon = dstvChannel?.thumbnailUrl ??
          dstvChannel?.logo ??
          _dstvThumbCache[channelKey] ??
          _dstvThumbCache[DstvEpgRepository.normalizeChannelName(channel.title)] ??
          channel.poster;

      for (final raw in items.whereType<Map<String, dynamic>>()) {
        var entry = IptvEpgEntry.fromJson(raw);
        if (!entry.hasTimes) continue;
        if (entry.stopTimestamp! > now) continue; // still airing or upcoming
        if (entry.startTimestamp! < earliest) continue; // outside catch-up window
        if (!seen.add(entry.dedupeKey)) continue;

        // The DStv-side programme covering this slot. Resolved once per entry
        // now rather than only inside the Cyrillic branch, because it carries
        // the per-programme artwork and synopsis from the XMLTV feed, not just
        // an English title.
        IptvEpgEntry? matchingDstv;
        if (dstvProgs != null && dstvProgs.isNotEmpty) {
          matchingDstv = dstvProgs.firstWhereOrNull((dp) {
            if (dp.startTimestamp == null) return false;
            final diff = (dp.startTimestamp! - entry.startTimestamp!).abs();
            return diff <= 1800; // within 30 mins
          });
        }

        // If title is Russian / Cyrillic or empty, find English title from DStv schedule or sanitize
        var title = entry.title;
        var description = entry.description;

        if (_containsCyrillic(title) || title.trim().isEmpty) {
          if (matchingDstv != null && matchingDstv.title.isNotEmpty) {
            title = matchingDstv.title;
          } else {
            title = _sanitizeTitle(title, channel.title);
          }
        }

        if (_containsCyrillic(description)) {
          description = '';
        }

        if (description.trim().isEmpty &&
            matchingDstv != null &&
            matchingDstv.description.trim().isNotEmpty) {
          description = matchingDstv.description;
        }

        var icon = entry.icon;
        if (icon == null || icon.isEmpty) {
          // Order matters: the matched programme's own image first, then the
          // per-programme thumbnail cache, and only then the channel-level
          // fallbacks. Those last two are channel logos, so reaching them for
          // every row is exactly what made the catch-up page look like one
          // picture repeated down the list.
          final programKey = title.toLowerCase();
          // The DStv side already falls back to the channel logo internally,
          // so only treat its icon as a real programme image when it is not
          // simply that same channel-level picture.
          final dstvIcon = matchingDstv?.icon;
          final programmeIcon =
              (dstvIcon != null && dstvIcon.isNotEmpty && dstvIcon != defaultIcon)
                  ? dstvIcon
                  : null;
          icon = programmeIcon ??
              _dstvThumbCache['${channelKey}_$programKey'] ??
              _dstvThumbCache[programKey] ??
              defaultIcon;
        }

        entry = entry.copyWith(
          title: title,
          description: description,
          icon: icon,
        );

        result.add(entry);
      }

      // If the provider returned no items, but DStv direct guide had programmes, use DStv programmes
      if (result.isEmpty && dstvProgs != null && dstvProgs.isNotEmpty) {
        _cachePut(key, dstvProgs);
        return dstvProgs;
      }

      result.sort((a, b) => (b.startTimestamp ?? 0).compareTo(a.startTimestamp ?? 0));
      _cachePut(key, result);
      return result;
    }, 'CatchupGuide');
  }

  void _enrichThumbnailsFromDstv(IptvContentItem channel, String streamId) {
    _api.restGet(
      '/api/iptv/epg/simple',
      query: {
        'streamId': streamId,
        if (channel.epgChannelId != null && channel.epgChannelId!.isNotEmpty)
          'epgChannelId': channel.epgChannelId,
        'channelName': channel.title,
        'source': 'dstv',
      },
      sessionToken: _token,
      timeout: const Duration(seconds: 3),
    ).then((data) {
      final dstvItems = (data is Map ? data['items'] : null) as List? ?? const [];
      for (final raw in dstvItems.whereType<Map<String, dynamic>>()) {
        final icon = raw['icon']?.toString();
        final title = raw['title']?.toString().toLowerCase().trim() ?? '';
        if (icon != null && icon.isNotEmpty) {
          _dstvThumbCache['${channel.title.toLowerCase()}_$title'] = icon;
          _dstvThumbCache[channel.title.toLowerCase()] = icon;
          if (title.isNotEmpty) _dstvThumbCache[title] = icon;
        }
      }
    }).catchError((_) {});
  }

  // ── Series info ────────────────────────────────────────────────────────────

  Future<IptvSeriesInfo> getSeriesInfo(String seriesId, {String? seriesName}) {
    return _withRetry(() async {
      final data = await _api.restGet(
        '/api/iptv/series-info',
        query: {
          'seriesId': seriesId,
          if (seriesName != null && seriesName.isNotEmpty) 'seriesName': seriesName,
        },
        sessionToken: _token,
      );
      if (data is! Map<String, dynamic>) {
        throw DioException(
          requestOptions: RequestOptions(path: '/api/iptv/series-info'),
          message: 'Unexpected response',
        );
      }
      return IptvSeriesInfo.fromJson(data);
    }, 'Series info');
  }

  // ── Favorites ──────────────────────────────────────────────────────────────

  /// Item ids favourited for [section].
  Future<Set<String>> getFavorites(
    IptvSection section, {
    bool forceRefresh = false,
  }) {
    final key = _favKey(section);
    if (!forceRefresh) {
      final cached = _cacheGet<Set<String>>(key, _ttlFavorites);
      if (cached != null) return Future.value(cached);
    }
    return _withRetry(() async {
      final data = await _api.restGet(
        '/api/favorites',
        query: {'type': section.apiType},
        sessionToken: _token,
        timeout: _reqTimeout,
      );
      final items = (data is Map ? data['items'] : null) as List? ?? const [];
      final result = items.map((e) => e.toString()).toSet();
      _cachePut(key, result);
      return result;
    }, 'Favorites');
  }

  /// Adds or removes a favourite. Returns the new favourite state.
  Future<bool> toggleFavorite(
    IptvSection section,
    String itemId, {
    required bool makeFavorite,
  }) {
    return _withRetry(() async {
      final body = {'type': section.apiType, 'itemId': itemId};
      if (makeFavorite) {
        await _api.restPost('/api/favorites', body: body, sessionToken: _token);
      } else {
        await _api.restDelete('/api/favorites', body: body, sessionToken: _token);
      }
      _invalidateFavorites(section);
      return makeFavorite;
    }, 'Favorite');
  }

  // ── Watch progress (`/api/progress`) ───────────────────────────────────────
  // `type` is [IptvProgressType.movie] ('vod') or [IptvProgressType.episode]
  // ('series_episode') — the same strings the Voltix web player writes, so the
  // two clients share a single Continue-Watching state. Every call here fails
  // soft (empty map / null / silently swallowed) so a progress hiccup can never
  // block or break playback: a missing row simply means "not started".

  /// Saved progress for [itemIds], keyed by item id. Ids without a stored row
  /// are absent from the map. Returns an empty map on any failure.
  Future<Map<String, IptvProgress>> getProgress(
    String type,
    List<String> itemIds,
  ) async {
    if (_token.isEmpty) return const <String, IptvProgress>{};
    final ids = <String>{
      for (final id in itemIds)
        if (id.trim().isNotEmpty) id.trim(),
    }.toList(growable: false);
    if (ids.isEmpty) return const <String, IptvProgress>{};
    try {
      final data = await _api.restGet(
        '/api/progress',
        query: {'type': type, 'itemIds': ids.join(',')},
        sessionToken: _token,
        timeout: _reqTimeout,
      );
      final items = (data is Map ? data['items'] : null) as List? ?? const [];
      final result = <String, IptvProgress>{};
      for (final raw in items.whereType<Map<String, dynamic>>()) {
        final progress = IptvProgress.fromJson(raw);
        if (progress.itemId.isNotEmpty) result[progress.itemId] = progress;
      }
      return result;
    } catch (_) {
      return const <String, IptvProgress>{};
    }
  }

  /// Records the current playback position. The backend auto-marks the item
  /// watched once 10s or less remain, so [isWatched] only has to be passed for
  /// an explicit "mark watched" action.
  Future<void> saveProgress({
    required String type,
    required String itemId,
    String? seriesId,
    int? seasonNumber,
    int? episodeNumber,
    required double currentTime,
    required double totalDuration,
    bool? isWatched,
  }) async {
    if (_token.isEmpty || itemId.isEmpty) return;
    try {
      await _api.restPost(
        '/api/progress',
        body: {
          'type': type,
          'itemId': itemId,
          if (seriesId != null && seriesId.isNotEmpty) 'seriesId': seriesId,
          'seasonNumber': ?seasonNumber,
          'episodeNumber': ?episodeNumber,
          'currentTime': currentTime,
          'totalDuration': totalDuration,
          'isWatched': ?isWatched,
        },
        sessionToken: _token,
      );
    } catch (_) {
      // Best-effort — a dropped progress ping is recovered by the next one.
    }
  }

  /// Forgets the saved position for an item (removes it from Continue Watching).
  Future<void> clearProgress(String type, String itemId) async {
    if (_token.isEmpty || itemId.isEmpty) return;
    try {
      await _api.restDelete(
        '/api/progress',
        body: {'type': type, 'itemId': itemId},
        sessionToken: _token,
      );
    } catch (_) {
      // Best-effort.
    }
  }

  /// Last-watched episode plus the watched episode ids for a series.
  /// Returns null when nothing has been watched yet (or on failure).
  Future<IptvSeriesProgress?> getSeriesProgress(String seriesId) async {
    if (_token.isEmpty || seriesId.isEmpty) return null;
    try {
      final data = await _api.restGet(
        '/api/progress/series',
        query: {'seriesId': seriesId},
        sessionToken: _token,
        timeout: _reqTimeout,
      );
      if (data is! Map<String, dynamic>) return null;
      return IptvSeriesProgress.fromJson(data);
    } catch (_) {
      return null;
    }
  }

  // ── Session freshness ────────────────────────────────────────────────────
  //
  // Stream URLs embed the session token as a query parameter. If the user's
  // session has expired (e.g. after the app was backgrounded for a while), the
  // baked token causes a 401 on the backend proxy and the stream fails
  // silently. Call [ensureTokenFresh] before building a stream URL so the
  // token is re-read from the store (which may have been refreshed by the
  // global session keepalive or a re-login).

  /// Re-reads the session token from the store and validates it against the
  /// backend if it appears stale. Returns `true` if the session is still
  /// valid, `false` if it could not be refreshed (callers should still
  /// attempt playback — the backend may accept the token regardless).
  Future<bool> ensureTokenFresh() async {
    // Re-read from store in case a background refresh updated it.
    final currentToken = _store.sessionToken ?? '';
    if (currentToken.isEmpty) return false;
    try {
      await _api.validateSession(currentToken);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── Stream URL resolution ──────────────────────────────────────────────────
  // The backend proxies streams at /api/iptv/stream/{type}/{id} with session
  // auth via the `token` query parameter (same path the existing native home
  // row playback uses in home_screen._playIptvChannel).

  /// Direct playable URL for a live [channel].
  String resolveLiveStreamUrl(IptvContentItem channel) {
    final streamId = channel.streamId?.toString() ?? channel.id;
    return '${_api.baseUrl}/api/iptv/stream/live/$streamId?token=$_token';
  }

  /// Playable URL for replaying a past [program] on an archive-enabled
  /// [channel] ("catch-up" / timeshift).
  ///
  /// Goes through the backend's `/api/iptv/stream-proxy` in timeshift mode,
  /// the same byte-proxied path live, VOD and series already use.
  ///
  /// It previously called `/api/iptv/replay-url`, which returns the provider's
  /// own timeshift URL for the client to open directly. That is the one stream
  /// type in the app that was not proxied, and a direct provider connection is
  /// exactly what fails on a player that cannot reach the upstream host (the
  /// provider IP-locks to the backend, blocks the device's user agent, or sits
  /// behind a redirect chain the native player will not follow) -- so the tile
  /// opens and the stream never starts.
  ///
  /// `start` is sent as a naive UTC "YYYY-MM-DD HH:MM:SS" string rather than
  /// epoch seconds: the endpoint parses it with JavaScript's `new Date(...)` in
  /// UTC, which would read a bare epoch-seconds number as milliseconds and land
  /// in 1970. Using UTC ensures the Xtream timeshift start time matches the
  /// actual broadcast UTC time regardless of client device timezone.
  ///
  /// Returns null only when the programme has no usable time window. Whether
  /// the recording is still available, and whether this line is entitled to
  /// the channel, is decided by the backend when the stream is requested -- it
  /// answers 410 for an expired window and 403 for a sport-only line.
  Future<String?> fetchCatchupStreamUrl(
    IptvContentItem channel,
    IptvEpgEntry program,
  ) async {
    // The archive variant, which is not always the channel's own stream id.
    final streamId = channel.catchupStreamId;
    if (!program.hasTimes) return null;
    final start = DateTime.fromMillisecondsSinceEpoch(
      program.startTimestamp! * 1000,
      isUtc: true,
    );
    final durationMinutes =
        ((program.stopTimestamp! - program.startTimestamp!) / 60).ceil();
    if (durationMinutes <= 0) return null;

    String two(int v) => v.toString().padLeft(2, '0');
    final startArg = '${start.year}-${two(start.month)}-${two(start.day)} '
        '${two(start.hour)}:${two(start.minute)}:${two(start.second)}';

    try {
      final data = await _api.restGet(
        '/api/iptv/replay-url',
        query: {
          'streamId': streamId,
          'start': startArg,
          'durationMinutes': '$durationMinutes',
          'containerExtension': 'ts',
        },
        sessionToken: _token,
        timeout: const Duration(seconds: 4),
      );
      if (data is Map && data['url'] != null) {
        final replayUrl = data['url'].toString();
        if (replayUrl.isNotEmpty) return replayUrl;
      }
    } catch (_) {}

    // Fall back to stream-proxy in timeshift mode
    return Uri.parse('${_api.baseUrl}/api/iptv/stream-proxy').replace(
      queryParameters: {
        'type': 'timeshift',
        'streamId': streamId,
        'start': startArg,
        'durationMinutes': '$durationMinutes',
        'containerExtension': 'ts',
        'token': _token,
      },
    ).toString();
  }

  /// Container extensions the upstream Xtream provider actually serves. Some
  /// providers return junk values (e.g. "vod4"), which produce a 404 on the
  /// CDN — those fall back to `mp4`, the Xtream default.
  static const _knownContainers = <String>{
    'mp4', 'mkv', 'avi', 'ts', 'm3u8', 'mov', 'm4v',
    'webm', 'flv', 'mpg', 'mpeg', 'wmv', '3gp',
  };

  static String _safeContainer(String? ext) {
    final value = ext?.trim().toLowerCase().replaceAll('.', '') ?? '';
    return _knownContainers.contains(value) ? value : 'mp4';
  }

  /// Direct playable URL for a VOD movie [item].
  String resolveVodStreamUrl(IptvContentItem item) {
    final streamId = item.streamId?.toString() ?? item.id;
    final ext = _safeContainer(item.containerExtension);
    return '${_api.baseUrl}/api/iptv/stream/movie/$streamId?ext=$ext&token=$_token';
  }

  /// Direct playable URL for a series [episode].
  String resolveEpisodeStreamUrl(IptvEpisode episode) {
    final ext = _safeContainer(episode.containerExtension);
    return '${_api.baseUrl}/api/iptv/stream/series/${episode.id}'
        '?ext=$ext&token=$_token';
  }

  // ── Admin: series download (zip, 24h link) ──────────────────────────────────
  // Admin-only. The backend downloads the series from the IPTV provider, zips
  // it, and returns a link valid for 24h before the zip + data are purged.
  // Backend contract (implement in Voltix Streaming server/iptvProxy.ts):
  //   GET  /api/iptv/admin/status                              -> { isAdmin: bool }
  //   POST /api/iptv/admin/series-download {seriesId,seriesName}-> { jobId }
  //   GET  /api/iptv/admin/series-download-status?jobId=       ->
  //        { status: pending|processing|ready|failed, progress, downloadUrl, expiresAt, error }
  // All routes require the Voltix session (role === 'admin') and reject others.

  /// Whether the signed-in Voltix user is an administrator. Derived from the
  /// Voltix session (validateSession) so it needs no extra endpoint — the
  /// backend just has to include an `isAdmin` bool (or a `role`/`serverRole`
  /// of "admin"/"voltixadmin") on the session `user`. Fails closed (false) so
  /// the download feature stays hidden for non-admins.
  Future<bool> fetchIsAdmin() async {
    if (_token.isEmpty) return false;
    try {
      final result = await _api.validateSession(_token);
      return result.user.isAdmin;
    } catch (_) {
      return false;
    }
  }

  /// Requests a server-side zip download of a whole series. Returns a job id.
  Future<String> requestSeriesDownload(String seriesId,
      {String? seriesName}) async {
    return _withRetry(() async {
      final data = await _api.restPost(
        '/api/iptv/admin/series-download',
        body: {
          'seriesId': seriesId,
          if (seriesName != null && seriesName.isNotEmpty) 'seriesName': seriesName,
        },
        sessionToken: _token,
      );
      final jobId = (data is Map ? data['jobId'] : null)?.toString();
      if (jobId == null || jobId.isEmpty) {
        throw const VoltixIptvException('No job id returned by server');
      }
      return jobId;
    }, 'Series download');
  }

  /// Polls the status of a series download job.
  Future<IptvDownloadStatus> getDownloadStatus(String jobId) async {
    try {
      final data = await _api.restGet(
        '/api/iptv/admin/series-download-status',
        query: {'jobId': jobId},
        sessionToken: _token,
      );
      if (data is! Map<String, dynamic>) {
        throw const VoltixIptvException('Unexpected status response');
      }
      return IptvDownloadStatus.fromJson(data);
    } on DioException catch (e) {
      throw VoltixIptvException(_messageFor(e));
    }
  }
}

/// Status of an admin series-download (zip) job.
class IptvDownloadStatus {
  final String status; // pending | processing | ready | failed
  final double progress; // 0.0–1.0
  final String? downloadUrl;
  final int? expiresAt; // epoch seconds (link valid until)
  final String? error;

  const IptvDownloadStatus({
    required this.status,
    this.progress = 0,
    this.downloadUrl,
    this.expiresAt,
    this.error,
  });

  bool get isReady => status == 'ready' && (downloadUrl?.isNotEmpty ?? false);
  bool get isFailed => status == 'failed';

  factory IptvDownloadStatus.fromJson(Map<String, dynamic> json) =>
      IptvDownloadStatus(
        status: json['status']?.toString() ?? 'pending',
        progress:
            json['progress'] is num ? (json['progress'] as num).toDouble() : 0,
        downloadUrl: json['downloadUrl']?.toString(),
        expiresAt:
            json['expiresAt'] is num ? (json['expiresAt'] as num).toInt() : null,
        error: json['error']?.toString(),
      );
}

/// Timestamped cache entry (millisecondsSinceEpoch) for the repository's
/// in-memory stale-while-revalidate cache.
class _CacheEntry {
  final Object value;
  final int ts;
  const _CacheEntry(this.value, this.ts);
}
