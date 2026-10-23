import 'dart:async';

import 'package:dio/dio.dart';
import 'package:playback_core/playback_core.dart';
import 'package:server_core/server_core.dart';

class JellyfinMediaStreamResolver implements MediaStreamResolver {
  final MediaServerClient _client;

  JellyfinMediaStreamResolver(this._client);

  /// When true, a video the server would only convert (transcode/remux) is
  /// first tried as the original file, the way the Jellyfin app plays it.
  /// If the device can't play it, the manager's startup recovery still
  /// retries with conversion (enableDirectPlay=false bypasses this).
  static bool preferOriginalFile = true;

  /// The player decodes every audio format itself (Media3 + FFmpeg on Android,
  /// mpv on phones/desktop): TrueHD / DTS-HD do NOT need the server, so the
  /// original file is played even when the server would convert the audio.
  /// Server conversion on shared servers (supersilo) is slow or unavailable -
  /// it was the "Loading stream" that never finished.
  static bool deviceDecodesAllAudio = false;

  /// Titles that must play from the original file (a server-converted stream
  /// of them stalled). Set by the playback manager's stall recovery.
  static final Set<String> forceOriginalItems = <String>{};

  /// Diagnostics hook (the app forwards these to its backend log).
  static void Function(String stage, Map<String, String> data)? onDiag;

  // ── Playback-info prefetch ────────────────────────────────────────────
  // The detail screen asks for PlaybackInfo as soon as a movie / episode
  // opens; Play then uses that answer instead of waiting ~1-2 s for it.
  static const _prefetchTtl = Duration(seconds: 90);
  static final Map<String, ({DateTime at, Future<Map<String, dynamic>> info})>
      _prefetched = {};

  static String _prefetchKey(MediaServerClient client, String itemId) =>
      '${client.baseUrl}|${client.userId}|$itemId';

  /// Starts PlaybackInfo for [itemId] in the background (no-op when a fresh
  /// one is already cached). Never throws.
  static void prefetchPlaybackInfo(
    MediaServerClient client,
    String itemId, {
    Map<String, dynamic>? deviceProfile,
    int? maxStreamingBitrate,
  }) {
    if (itemId.isEmpty) return;
    final key = _prefetchKey(client, itemId);
    final existing = _prefetched[key];
    if (existing != null &&
        DateTime.now().difference(existing.at) < _prefetchTtl) {
      return;
    }
    _prefetched.removeWhere(
        (_, v) => DateTime.now().difference(v.at) >= _prefetchTtl);
    final request = PlaybackInfoRequest(
      itemId: itemId,
      deviceProfile: deviceProfile,
      maxStreamingBitrate: maxStreamingBitrate,
    );
    final future = client.playbackApi.getPlaybackInfo(
      itemId,
      requestBody: request.toJson(),
      userId: client.userId,
    );
    future.catchError((Object _) {
      _prefetched.remove(key);
      return const <String, dynamic>{};
    });
    _prefetched[key] = (at: DateTime.now(), info: future);
  }

  /// A fresh prefetched answer for a plain Play (no explicit track, source
  /// or transcode request); removed once taken so re-resolves ask again.
  Future<Map<String, dynamic>>? _takePrefetched(String itemId) {
    final key = _prefetchKey(_client, itemId);
    final hit = _prefetched.remove(key);
    if (hit == null) return null;
    if (DateTime.now().difference(hit.at) >= _prefetchTtl) return null;
    return hit.info;
  }

  Map<String, String> _buildRequestHeaders() {
    final token = _client.accessToken;
    final headers = <String, String>{
      'Authorization': buildServerAuthorizationHeader(
        scheme: 'MediaBrowser',
        deviceInfo: _client.deviceInfo,
        accessToken: token,
      ),
    };
    if (token != null && token.isNotEmpty) {
      headers['X-Emby-Token'] = token;
    }
    return headers;
  }

  /// Live TV channels/programmes must never take the "original file" path:
  /// a channel has no file, its stream comes from an opened live session.
  bool _isLiveMediaItem(dynamic mediaItem) {
    bool isLiveType(Object? raw) {
      final t = raw?.toString().trim().toLowerCase();
      return t == 'tvchannel' || t == 'livetvchannel' || t == 'program' ||
          t == 'channel' || t == 'recording';
    }

    Map? raw;
    try {
      final dynamic dyn = mediaItem;
      if (isLiveType(dyn.type)) return true;
      raw = dyn.rawData as Map?;
    } catch (_) {}
    if (mediaItem is Map) raw = mediaItem;
    if (raw != null) {
      if (isLiveType(raw['Type']) || isLiveType(raw['MediaType'])) return true;
      if (raw['ChannelId'] != null || raw['TimerId'] != null) return true;
      if (raw['IsLive'] == true) return true;
    }
    return false;
  }


  /// When the file's default audio track is a heavy codec and the same file
  /// has a light-codec track in the same language, returns that track's
  /// index (most channels first). Null = keep the default.
  static int? preferDecodableAudioTrack(
    List<Map<String, dynamic>> streams,
    int? defaultIndex,
  ) {
    final audio = streams.where((s) => s['Type'] == 'Audio').toList();
    if (audio.length < 2) return null;
    final current = audio.firstWhere(
      (s) => defaultIndex != null ? s['Index'] == defaultIndex : s['IsDefault'] == true,
      orElse: () => audio.first,
    );
    // AC3 5.1 first, then E-AC3 5.1+, other AC3/E-AC3, AAC (see
    // AudioTrackPreference).
    final alt = AudioTrackPreference.lighterAlternative(audio, current);
    return alt?['Index'] as int?;
  }

  bool _isAudioMediaItem(dynamic mediaItem) {
    bool isAudioType(String? rawType) {
      final type = rawType?.trim().toLowerCase();
      return type == 'audio';
    }

    try {
      final dynamic dyn = mediaItem;
      if (isAudioType(dyn.type?.toString())) {
        return true;
      }
    } catch (_) {}

    if (mediaItem is Map && isAudioType(mediaItem['Type']?.toString())) {
      return true;
    }

    return false;
  }

  @override
  Future<StreamResolutionResult> resolve(
    dynamic mediaItem, {
    Map<String, dynamic>? deviceProfile,
    int? maxStreamingBitrate,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    int? startTimeTicks,
    String? mediaSourceId,
    bool enableDirectPlay = true,
    bool enableDirectStream = true,
    bool enableTranscoding = true,
  }) async {
    final itemId = MediaStreamResolver.extractItemId(mediaItem);
    final resolveWatch = Stopwatch()..start();
    final slowTimer = Timer(const Duration(seconds: 10), () {
      try {
        onDiag?.call('resolve-slow', {
          'item': itemId,
          'source': mediaSourceId ?? '',
          'ms': '${resolveWatch.elapsedMilliseconds}',
        });
      } catch (_) {}
    });
    try {
      return await _resolve(
        mediaItem,
        itemId,
        deviceProfile: deviceProfile,
        maxStreamingBitrate: maxStreamingBitrate,
        audioStreamIndex: audioStreamIndex,
        subtitleStreamIndex: subtitleStreamIndex,
        startTimeTicks: startTimeTicks,
        mediaSourceId: mediaSourceId,
        enableDirectPlay: enableDirectPlay,
        enableDirectStream: enableDirectStream,
        enableTranscoding: enableTranscoding,
      );
    } finally {
      slowTimer.cancel();
    }
  }

  Future<StreamResolutionResult> _resolve(
    dynamic mediaItem,
    String itemId, {
    Map<String, dynamic>? deviceProfile,
    int? maxStreamingBitrate,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    int? startTimeTicks,
    String? mediaSourceId,
    bool enableDirectPlay = true,
    bool enableDirectStream = true,
    bool enableTranscoding = true,
  }) async {
    final resolveTimer = Stopwatch()..start();
    final resolvedMediaSourceId =
        MediaStreamResolver.resolveStaticMediaSourceId(mediaItem, mediaSourceId);

    final request = PlaybackInfoRequest(
      itemId: itemId,
      mediaSourceId: resolvedMediaSourceId,
      deviceProfile: deviceProfile,
      maxStreamingBitrate: maxStreamingBitrate,
      audioStreamIndex: audioStreamIndex,
      subtitleStreamIndex: subtitleStreamIndex,
      startTimeTicks: startTimeTicks,
      enableDirectPlay: enableDirectPlay,
      enableDirectStream: enableDirectStream,
      enableTranscoding: enableTranscoding,
    );

    final canUsePrefetch = audioStreamIndex == null &&
        subtitleStreamIndex == null &&
        enableDirectPlay &&
        enableDirectStream &&
        enableTranscoding &&
        (mediaSourceId == null || mediaSourceId == itemId);
    final prefetched = canUsePrefetch ? _takePrefetched(itemId) : null;
    Map<String, dynamic>? fromPrefetch;
    if (prefetched != null) {
      try {
        final v = await prefetched;
        if (v.isNotEmpty) fromPrefetch = v;
      } catch (_) {}
    }
    final rawInfo = fromPrefetch ?? await _playbackInfoWithFallback(
          itemId,
          request.toJson(),
          startTimeTicks: startTimeTicks,
        );

    final info = PlaybackInfoResult.fromJson(rawInfo);

    if (info.errorCode != null) {
      throw Exception('Playback error: ${info.errorCode}');
    }
    if (info.mediaSources.isEmpty) {
      throw Exception('No media sources available for item $itemId');
    }

    // No version chosen by the viewer: take the one that fits their maximum
    // resolution (e.g. the 1080p file when 2160p and 1080p versions exist).
    var preferredSourceId = resolvedMediaSourceId;
    if ((preferredSourceId == null || preferredSourceId.isEmpty) &&
        info.mediaSources.length > 1) {
      final rawSources = (rawInfo['MediaSources'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      preferredSourceId = MediaSourceVersionPicker.pickId(rawSources);
    }
    // Versions that already failed on this device are skipped (a different
    // one is played instead of an error).
    final usableSources = info.mediaSources.length > 1
        ? info.mediaSources
            .where((s) => !MediaSourceVersionPicker.isUnplayable(s.id))
            .toList()
        : info.mediaSources;
    if (MediaSourceVersionPicker.isUnplayable(preferredSourceId) &&
        usableSources.isNotEmpty) {
      final rawUsable = (rawInfo['MediaSources'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .where((m) => !MediaSourceVersionPicker.isUnplayable(m['Id']))
          .toList();
      preferredSourceId = MediaSourceVersionPicker.pickId(rawUsable);
    }
    var source = _selectBestSource(
      usableSources.isEmpty ? info.mediaSources : usableSources,
      preferredId: preferredSourceId,
      enableDirectPlay: enableDirectPlay,
    );
    final hasKnownMediaStreams = source.mediaStreams.isNotEmpty;
    final hasVideoStream = source.mediaStreams.any((stream) => stream['Type'] == 'Video');
    final isAudioByStreams = hasKnownMediaStreams && !hasVideoStream;
    final isAudio = isAudioByStreams || _isAudioMediaItem(mediaItem);
    var (url, playMethod) = _resolveStreamUrl(
      itemId,
      source,
      isAudio: isAudio,
      isLive: _isLiveMediaItem(mediaItem),
      enableDirectPlay: enableDirectPlay,
    );

    // Title with several versions: check the version's file address answers
    // before handing it to the player. Servers differ on which address a
    // version uses (/Videos/<item>/stream?MediaSourceId=<version> or
    // /Videos/<version>/stream); supersilo accepts only one of them per
    // version. A version neither address can deliver is marked unplayable
    // (hidden from Versions) and the next best version is played instead.
    if (!isAudio &&
        !_isLiveMediaItem(mediaItem) &&
        playMethod == StreamPlayMethod.directPlay &&
        source.id.isNotEmpty &&
        source.id != itemId &&
        _isServerUrl(url) &&
        (source.liveStreamId ?? '').isEmpty) {
      for (var attempt = 0; attempt < info.mediaSources.length; attempt++) {
        final working = await _workingVersionUrl(
          itemId,
          source,
          ownSourceFirst: identical(source, info.mediaSources.first),
        );
        if (working != null) {
          url = working;
          break;
        }
        MediaSourceVersionPicker.markUnplayable(source.id);
        final rawUsable = (rawInfo['MediaSources'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .where((m) => !MediaSourceVersionPicker.isUnplayable(m['Id']))
            .toList();
        if (rawUsable.isEmpty) break; // nothing else to try: keep the error path
        final nextId = MediaSourceVersionPicker.pickId(rawUsable);
        final next = info.mediaSources.where((s) => s.id == nextId).firstOrNull;
        if (next == null) break;
        source = next;
        (url, playMethod) = _resolveStreamUrl(
          itemId,
          source,
          isAudio: isAudio,
          isLive: false,
          enableDirectPlay: enableDirectPlay,
        );
        if (playMethod != StreamPlayMethod.directPlay || !_isServerUrl(url)) {
          break;
        }
      }
    }

    try {
      final uri = Uri.tryParse(url);
      final sourceName = source.name ?? '';
      onDiag?.call('play-resolve', {
        'item': itemId,
        'source': source.id,
        'sources': '${info.mediaSources.length}',
        'name': sourceName.length > 80 ? sourceName.substring(0, 80) : sourceName,
        'mbps': ((source.bitrate ?? 0) / 1000000).toStringAsFixed(1),
        'dp': '${source.supportsDirectPlay}',
        'ds': '${source.supportsDirectStream}',
        'tc': '${source.supportsTranscoding}',
        'reasons': source.transcodingReasons.join(','),
        'method': playMethod.name,
        'path': uri?.path ?? '',
        'static': uri?.queryParameters['Static'] ??
            uri?.queryParameters['static'] ?? '',
        'ms': '${resolveTimer.elapsedMilliseconds}',
      });
    } catch (_) {}

    // supersilo's own streaming system (/audio-v2/master.m3u8): played
    // exactly as the server returned it, like the web player does. The usual
    // rewrites (stream indexes, StartTimeTicks, api_key) are not part of that
    // address and are the likely cause of "Playback session not found".
    final isServerStreamV2 = url.contains('/audio-v2/');
    if (!isServerStreamV2 &&
        (playMethod == StreamPlayMethod.transcode || playMethod == StreamPlayMethod.directStream)) {
      url = MediaStreamResolver.applyStreamIndices(url, audioStreamIndex, subtitleStreamIndex);
      url = url
          .replaceFirst(RegExp(r'\?StartTimeTicks=\d+&', caseSensitive: false), '?')
          .replaceFirst(RegExp(r'[&?]StartTimeTicks=\d+', caseSensitive: false), '');
    }

    // Append auth token for mpv (which doesn't use our Dio interceptors).
    if (!isServerStreamV2) url = _appendAuth(url);

    final externalSubs = MediaStreamResolver.extractExternalSubtitles(source.mediaStreams, _client.baseUrl);
    final authedSubs = externalSubs.map((s) => ExternalSubtitle(
      deliveryUrl: _appendAuth(s.deliveryUrl),
      title: s.title,
      language: s.language,
      codec: s.codec,
      isDefault: s.isDefault,
      isForced: s.isForced,
      streamIndex: s.streamIndex,
    )).toList();

    final mediaType = MediaStreamResolver.detectMediaType(
      source.mediaStreams,
      fallbackUrl: url,
    );
    final videoRangeType = source.mediaStreams
        .where((stream) => stream['Type'] == 'Video')
        .map((stream) => stream['VideoRangeType']?.toString())
        .firstWhere((value) => value != null && value.isNotEmpty, orElse: () => null);
    final normalizationGainDb =
        MediaStreamResolver.extractNormalizationGainDb(source.mediaStreams);
    final requestHeaders = _isServerUrl(url)
        ? _buildRequestHeaders()
        : const <String, String>{};

    final hasEac3Audio = source.mediaStreams.any((stream) =>
        stream['Type'] == 'Audio' &&
        (stream['Codec']?.toString().toLowerCase() ?? '') == 'eac3');
    final hybridAudioUrl = (hasVideoStream && hasEac3Audio)
        ? _buildHybridAudioRemuxUrl(
            itemId,
            source,
            info.playSessionId,
            source.defaultAudioStreamIndex,
          )
        : null;

    return StreamResolutionResult(
      streamUrl: url,
      mediaSourceId: source.id,
      liveStreamId: source.liveStreamId,
      playSessionId: info.playSessionId,
      requestHeaders: requestHeaders,
      playMethod: playMethod,
      container: source.container,
      videoRangeType: videoRangeType,
      mediaType: mediaType,
      normalizationGainDb: normalizationGainDb,
      externalSubtitles: authedSubs,
      mediaStreams: source.mediaStreams,
      // No track chosen by the viewer, or the file's default one: swap a
      // TrueHD/DTS default for the same-language AC3 5.1 (etc.) track.
      selectedAudioStreamIndex: ((audioStreamIndex == null ||
                  audioStreamIndex == source.defaultAudioStreamIndex) &&
              playMethod != StreamPlayMethod.transcode)
          ? (preferDecodableAudioTrack(source.mediaStreams,
                  source.defaultAudioStreamIndex) ??
              source.defaultAudioStreamIndex)
          : source.defaultAudioStreamIndex,
      transcodingReasons: source.transcodingReasons,
      hybridAudioUrl: hybridAudioUrl,
      sourceBitrate: source.bitrate,
    );
  }

  String? _buildHybridAudioRemuxUrl(
    String itemId,
    PlaybackMediaSource source,
    String? playSessionId,
    int? audioStreamIndex,
  ) {
    if (itemId.isEmpty) return null;
    final params = <String, String>{
      'AudioCodec': 'copy',
      'SegmentContainer': 'mp4',
      'AllowAudioStreamCopy': 'true',
      'EnableAutoStreamCopy': 'true',
      if (source.id.isNotEmpty) 'MediaSourceId': source.id,
      if (playSessionId != null && playSessionId.isNotEmpty)
        'PlaySessionId': playSessionId,
      if (_client.deviceInfo.id.isNotEmpty) 'DeviceId': _client.deviceInfo.id,
      if (audioStreamIndex != null) 'AudioStreamIndex': '$audioStreamIndex',
    };
    final query = params.entries
        .map((entry) => '${entry.key}=${Uri.encodeQueryComponent(entry.value)}')
        .join('&');
    return _appendAuth(_joinServerUrl('/Audio/$itemId/main.m3u8?$query'));
  }

  PlaybackMediaSource _selectBestSource(
    List<PlaybackMediaSource> sources, {
    String? preferredId,
    bool enableDirectPlay = true,
  }) {
    if (preferredId != null) {
      final preferred = sources.where((s) => s.id == preferredId).firstOrNull;
      if (preferred != null) {
        return preferred;
      }
    }
    PlaybackMediaSource? directPlay;
    PlaybackMediaSource? directStream;
    PlaybackMediaSource? transcode;
    for (final s in sources) {
      if (enableDirectPlay && s.supportsDirectPlay) {
        return s;
      }
      if (s.supportsDirectPlay) {
        directPlay ??= s;
      }
      directStream ??= s.supportsDirectStream ? s : null;
      transcode ??= s.supportsTranscoding ? s : null;
    }
    return directStream ?? transcode ?? directPlay ?? sources.first;
  }

  /// The server says this device can't decode the file's audio (e.g. TrueHD /
  /// DTS-HD on a TV without that decoder). Playing the original file then
  /// gives a stalled or silent start, so take the server's version instead:
  /// "direct stream" copies the video untouched and only converts the audio,
  /// which is light for the server - what the official Jellyfin app does.
  static const _audioConversionReasons = {
    'AudioCodecNotSupported',
    'AudioProfileNotSupported',
    'AudioBitDepthNotSupported',
    'AudioSampleRateNotSupported',
    'SecondaryAudioNotSupported',
  };

  bool _audioNeedsConversion(PlaybackMediaSource source) =>
      source.transcodingReasons.any(_audioConversionReasons.contains);

  bool _isServerUrl(String url) {
    final base = _client.baseUrl.trim().toLowerCase();
    final cleanBase =
        base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final cleanUrl = url.trim().toLowerCase();
    return cleanUrl.startsWith(cleanBase);
  }

  String _joinServerUrl(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return path;
    }
    final base = _client.baseUrl.endsWith('/')
        ? _client.baseUrl.substring(0, _client.baseUrl.length - 1)
        : _client.baseUrl;
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return '$base$normalizedPath';
  }

  String _appendAuth(String url) {
    final token = _client.accessToken;
    if (token == null || token.isEmpty) return url;
    if (!_isServerUrl(url)) return url;
    final lowerUrl = url.toLowerCase();
    if (lowerUrl.contains('api_key=') || lowerUrl.contains('apikey=')) return url;
    final separator = url.contains('?') ? '&' : '?';
    return '$url${separator}api_key=${Uri.encodeComponent(token)}';
  }

  /// PlaybackInfo, retried without the device profile when the server refuses
  /// the request (supersilo answered 400 Bad Request for 4K titles, so Play did
  /// nothing at all). The app decides the play method itself (original file
  /// first), so the server's profile check is not needed to start playback.
  /// The server's reason is sent to the diagnostics log.
  Future<Map<String, dynamic>> _playbackInfoWithFallback(
    String itemId,
    Map<String, dynamic> body, {
    int? startTimeTicks,
  }) async {
    try {
      return await _client.playbackApi.getPlaybackInfo(
        itemId,
        requestBody: body,
        userId: _client.userId,
        startTimeTicks: startTimeTicks,
      );
    } on DioException catch (e) {
      final code = e.response?.statusCode ?? 0;
      var reason = '';
      try {
        final d = e.response?.data;
        reason = (d is String ? d : d?.toString() ?? '').replaceAll(RegExp(r'\s+'), ' ');
        if (reason.length > 300) reason = reason.substring(0, 300);
      } catch (_) {}
      try {
        onDiag?.call('playbackinfo-error', {
          'item': itemId,
          'source': body['MediaSourceId']?.toString() ?? '',
          'http': '$code',
          'reason': reason,
          'audio': body['AudioStreamIndex']?.toString() ?? '',
          'maxBitrate': body['MaxStreamingBitrate']?.toString() ?? '',
        });
      } catch (_) {}
      if (code < 400 || code >= 500) rethrow;
      // Minimal request: no device profile / stream indexes.
      final minimal = <String, dynamic>{
        if (body['MediaSourceId'] != null) 'MediaSourceId': body['MediaSourceId'],
        'EnableDirectPlay': true,
        'EnableDirectStream': true,
        'EnableTranscoding': true,
      };
      try {
        final res = await _client.playbackApi.getPlaybackInfo(
          itemId,
          requestBody: minimal,
          userId: _client.userId,
          startTimeTicks: startTimeTicks,
        );
        onDiag?.call('playbackinfo-retry', {'item': itemId, 'result': 'ok'});
        return res;
      } on DioException catch (e2) {
        onDiag?.call('playbackinfo-retry', {
          'item': itemId,
          'result': 'failed',
          'http': '${e2.response?.statusCode ?? 0}',
        });
        // Last try: no version either (let the server pick its default).
        if (body['MediaSourceId'] == null) rethrow;
        return _client.playbackApi.getPlaybackInfo(
          itemId,
          requestBody: const {
            'EnableDirectPlay': true,
            'EnableDirectStream': true,
            'EnableTranscoding': true,
          },
          userId: _client.userId,
          startTimeTicks: startTimeTicks,
        );
      }
    }
  }

  // ── Version address check ─────────────────────────────────────────────
  /// Which address worked for a version, per server: 'own' = /Videos/<version>
  /// /stream, 'item' = /Videos/<item>/stream?MediaSourceId=<version>.
  static final Map<String, String> _versionUrlForm = {};
  static final Dio _probeDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 8),
      followRedirects: true,
      validateStatus: (_) => true,
      responseType: ResponseType.stream,
    ),
  );

  /// The address that delivers [source], or null when the server refused
  /// both (missing/broken file). When the check itself can't finish (slow
  /// server, timeout) the usual address is returned, as before.
  Future<String?> _workingVersionUrl(
    String itemId,
    PlaybackMediaSource source, {
    required bool ownSourceFirst,
  }) async {
    final byOwnId =
        _client.playbackApi.getStreamUrl(source.id, mediaSourceId: source.id);
    final byItem =
        _client.playbackApi.getStreamUrl(itemId, mediaSourceId: source.id);
    if (source.id.isEmpty || source.id == itemId) return byItem;
    final key = '${_client.baseUrl}|${source.id}';
    switch (_versionUrlForm[key]) {
      case 'own':
        return byOwnId;
      case 'item':
        return byItem;
    }
    // The standard Jellyfin address first (/Videos/<title>/stream?MediaSourceId=
    // <version>): supersilo serves every version of Wicked that way and answers
    // 401 to /Videos/<version>/stream (tested with the stream-test script).
    final order = [('item', byItem), ('own', byOwnId)];
    var undecided = false;
    final results = <String>[];
    final sw = Stopwatch()..start();
    String? found;
    for (final (form, candidate) in order) {
      // Hard limit: the check must never hold up Play for long.
      final ok = await _probe(_appendAuth(candidate))
          .timeout(const Duration(seconds: 5), onTimeout: () => null);
      results.add('$form=${ok ?? 'unknown'}');
      if (ok == true) {
        _versionUrlForm[key] = form;
        found = candidate;
        break;
      }
      if (ok == null) {
        // Unknown (slow server or a front-end block): don't spend another 5 s
        // on the second address - play the usual one and let the player's own
        // retry handle a brief block.
        undecided = true;
        break;
      }
    }
    try {
      onDiag?.call('version-check', {
        'source': source.id,
        'result': results.join(','),
        'ms': '${sw.elapsedMilliseconds}',
      });
    } catch (_) {}
    if (found != null) return found;
    return undecided ? order.first.$2 : null;
  }

  /// true = the file answers, false = the server refused it, null = unknown.
  ///
  /// supersilo's front end briefly answers a plain-text "404 page not found"
  /// to an account that sent a quick burst of requests (seen in test-4k.ps1:
  /// the same file failed, then worked seconds later). That is NOT the file
  /// being missing - Jellyfin's own 404s are JSON - so it is retried and, if
  /// it persists, treated as "unknown": the version must not be marked
  /// unplayable (that would hide a working 4K version on this device).
  Future<bool?> _probe(String url) async {
    // One quick retry only: this check runs before anything is on screen.
    for (var attempt = 0; attempt < 2; attempt++) {
      final result = await _probeOnce(url);
      if (result != _frontEnd404) return result as bool?;
      if (attempt == 0) await Future<void>.delayed(const Duration(milliseconds: 1500));
    }
    return null;
  }

  static const Object _frontEnd404 = 'front-end-404';

  /// true / false / null as [_probe], or [_frontEnd404].
  Future<Object?> _probeOnce(String url) async {
    try {
      final cancel = CancelToken();
      final timer = Timer(const Duration(seconds: 5), () {
        if (!cancel.isCancelled) cancel.cancel();
      });
      final Response<ResponseBody> r;
      try {
        r = await _probeDio.get<ResponseBody>(
          url,
          cancelToken: cancel,
          options: Options(
            headers: {..._buildRequestHeaders(), 'Range': 'bytes=0-0'},
          ),
        );
      } finally {
        timer.cancel();
      }
      final code = r.statusCode ?? 0;
      if (code == 404) {
        var head = '';
        try {
          final chunk = await r.data?.stream.first.timeout(const Duration(seconds: 2));
          if (chunk != null) {
            head = String.fromCharCodes(chunk.take(64)).trim().toLowerCase();
          }
        } catch (_) {}
        if (head.startsWith('404 page not found')) return _frontEnd404;
        return false;
      }
      // Don't wait for the (possibly huge) body: drop the connection.
      try {
        unawaited(r.data?.stream.listen(null).cancel() ?? Future.value());
      } catch (_) {}
      if (code == 200 || code == 206) return true;
      if (code == 400 || code == 401 || code == 403 ||
          code == 410 || code == 500) {
        return false;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  String _buildDirectPlayAudioUrl(String itemId, PlaybackMediaSource source) {
    final params = <String, String>{
      if (source.id.isNotEmpty) 'MediaSourceId': source.id,
      if (source.container != null && source.container!.isNotEmpty)
        'Container': source.container!,
      if (source.eTag != null && source.eTag!.isNotEmpty)
        'Tag': source.eTag!,
      if (source.liveStreamId != null && source.liveStreamId!.isNotEmpty)
        'LiveStreamId': source.liveStreamId!,
      'Static': 'true',
    };
    final query = params.entries
        .map((entry) => '${entry.key}=${Uri.encodeQueryComponent(entry.value)}')
        .join('&');
    return _joinServerUrl('/Audio/$itemId/stream?$query');
  }

  (String, StreamPlayMethod) _resolveStreamUrl(
    String itemId,
    PlaybackMediaSource source, {
    bool isAudio = false,
    bool isLive = false,
    bool enableDirectPlay = true,
  }) {
    final remotePath = source.path;
    final isManagedLiveStream =
        source.liveStreamId != null && source.liveStreamId!.isNotEmpty;
    if (enableDirectPlay &&
        source.supportsDirectPlay &&
        source.isRemote &&
        !isManagedLiveStream &&
        source.protocol?.toLowerCase() == 'http' &&
        remotePath != null &&
        (remotePath.startsWith('http://') ||
            remotePath.startsWith('https://'))) {
      return (remotePath, StreamPlayMethod.directPlay);
    }

    // Live TV: play the source path directly instead of the HLS transcode.
    // Server-served path (e.g. Jellyfin LiveStreamFiles) is a remux ->
    // directStream (keeps the live session); a remote upstream -> directPlay.
    if (MediaStreamResolver.isLiveSourceDirectPlayEligible(
      enableDirectPlay: enableDirectPlay,
      isManagedLiveStream: isManagedLiveStream,
      path: remotePath,
    )) {
      final method = _isServerUrl(remotePath!)
          ? StreamPlayMethod.directStream
          : StreamPlayMethod.directPlay;
      return (remotePath, method);
    }

    if (enableDirectPlay && source.supportsDirectPlay && isAudio) {
      return (
        _buildDirectPlayAudioUrl(itemId, source),
        StreamPlayMethod.directPlay,
      );
    }

    // Another version of the title (its own media source id): stream it by
    // ITS id. In Jellyfin every version is an item of its own, and supersilo
    // answers 404 to /Videos/<main id>/stream?MediaSourceId=<other version>.
    // Standard Jellyfin address: /Videos/<title>/stream?MediaSourceId=<version>.
    // (The version-id form returned 401 on supersilo; a server that wants it
    // is found by the address check in resolve().)
    final fileItemId = itemId;
    if (enableDirectPlay && source.supportsDirectPlay) {
      return (
        _client.playbackApi.getStreamUrl(fileItemId, mediaSourceId: source.id, liveStreamId: source.liveStreamId),
        StreamPlayMethod.directPlay,
      );
    }
    if (preferOriginalFile &&
        enableDirectPlay &&
        (!_audioNeedsConversion(source) ||
            deviceDecodesAllAudio ||
            forceOriginalItems.contains(itemId)) &&
        !isAudio &&
        !isLive &&
        !isManagedLiveStream &&
        itemId.isNotEmpty) {
      return (
        _client.playbackApi.getStreamUrl(fileItemId, mediaSourceId: source.id),
        StreamPlayMethod.directPlay,
      );
    }
    if (source.supportsDirectStream && source.directStreamUrl != null) {
      var dsUrl = _joinServerUrl(source.directStreamUrl!);
      if (source.liveStreamId != null) {
        dsUrl = '$dsUrl${dsUrl.contains('?') ? '&' : '?'}LiveStreamId=${Uri.encodeComponent(source.liveStreamId!)}';
      }
      return (dsUrl, StreamPlayMethod.directStream);
    }
    if (source.supportsTranscoding && source.transcodingUrl != null) {
      var tcUrl = _joinServerUrl(source.transcodingUrl!);
      if (source.liveStreamId != null) {
        tcUrl = '$tcUrl${tcUrl.contains('?') ? '&' : '?'}LiveStreamId=${Uri.encodeComponent(source.liveStreamId!)}';
      }
      return (tcUrl, StreamPlayMethod.transcode);
    }
    return (
      _client.playbackApi.getStreamUrl(itemId, mediaSourceId: source.id, liveStreamId: source.liveStreamId),
      StreamPlayMethod.directPlay,
    );
  }
}
