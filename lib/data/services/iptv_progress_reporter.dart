import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:playback_core/playback_core.dart';

import '../models/aggregated_item.dart';
import '../models/iptv_models.dart';
import '../repositories/voltix_iptv_repository.dart';
import 'iptv_recent_store.dart';

/// Details of the upcoming IPTV episode, published while the end-of-episode
/// countdown overlay is showing. Recreated each tick so [secondsRemaining]
/// counts down live.
class IptvNextEpisodePrompt {
  final String seriesTitle;

  /// e.g. "S1 E5 · The Reveal" (or just the episode title if no numbering).
  final String episodeLabel;
  final String? poster;

  /// Whole seconds until the current episode ends and the next one plays.
  final int secondsRemaining;

  const IptvNextEpisodePrompt({
    required this.seriesTitle,
    required this.episodeLabel,
    required this.poster,
    required this.secondsRemaining,
  });
}

/// Tracks the IPTV movie/episode that is currently playing and:
///   * remembers it in the local [IptvRecentStore] (Continue Watching source),
///   * POSTs the playback position to `/api/progress` (throttled),
///   * autoplays the next episode when a series episode finishes.
///
/// Only VOD movies and series episodes are tracked — live channels are never
/// registered here, so nothing happens for them. Deliberately lightweight for
/// entry-level TVs: one timer-free throttle check per position tick and at most
/// one POST every [_postInterval].
///
/// Ownership: launch sites call [startPlayback] (which registers the session),
/// the video player screen feeds [onPosition] / [onPlayingChanged] and calls
/// [endSession] when it tears down.
class IptvProgressReporter {
  /// Minimum wall-clock gap between periodic progress POSTs.
  static const Duration _postInterval = Duration(seconds: 10);

  /// Remaining time at which an episode is considered finished (matches the
  /// backend's auto-"watched" window) and the next one is queued up.
  static const Duration _endThreshold = Duration(seconds: 10);

  /// Ignore completion/auto-next for the first few seconds of a stream so a
  /// bogus early duration can't skip an episode.
  static const Duration _minPlayedBeforeAdvance = Duration(seconds: 20);

  final VoltixIptvRepository _repo;
  final IptvRecentStore _recent;
  final PlaybackManager _manager;

  IptvProgressReporter({
    VoltixIptvRepository? repository,
    IptvRecentStore? recentStore,
    PlaybackManager? manager,
  })  : _repo = repository ?? VoltixIptvRepository(),
        _recent = recentStore ?? IptvRecentStore(),
        _manager = manager ?? GetIt.instance<PlaybackManager>();

  IptvRecentItem? _active;
  double _lastPosition = 0;
  double _lastDuration = 0;
  DateTime? _lastPostAt;
  bool _nearEndPosted = false;
  bool _advanceRequested = false;
  Future<bool>? _advanceFuture;

  // Next-episode countdown state (episodes only).
  bool _nextResolveStarted = false;
  bool _advanceCancelled = false;
  IptvRecentItem? _pendingNextItem;
  String? _pendingNextUrl;
  String? _pendingNextLabel;

  /// Shows the end-of-episode countdown overlay. Null when no countdown is
  /// active. The player screen listens to this to render the "Next episode"
  /// card and drive playback when it reaches zero.
  final ValueNotifier<IptvNextEpisodePrompt?> nextEpisodePrompt =
      ValueNotifier<IptvNextEpisodePrompt?>(null);

  /// The IPTV item being tracked, or null when nothing IPTV is playing.
  IptvRecentItem? get activeItem => _active;

  /// True while a next-episode handoff is in flight — the player screen must
  /// not exit playback during that window.
  bool get isAdvancing => _advanceFuture != null;

  // ── Session lifecycle ──────────────────────────────────────────────────────

  /// Plays an IPTV movie/episode through the shared PlaybackManager path and
  /// makes it the tracked session.
  ///
  /// Does not navigate: callers that aren't already on the player screen push
  /// `Destinations.videoPlayer` themselves (matching the existing
  /// `_launchIptvStream` behaviour). Rethrows playback failures so the caller
  /// can surface them.
  Future<void> startPlayback(
    IptvRecentItem item,
    String url, {
    Duration startPosition = Duration.zero,
  }) async {
    endSession();
    unawaited(_recent.touch(item));
    final playbackId = 'iptv_${DateTime.now().millisecondsSinceEpoch}';
    final playbackItem = AggregatedItem(
      id: playbackId,
      serverId: 'iptv',
      rawData: {
        'Id': playbackId,
        'url': url,
        'Name': item.title,
        'isLive': false,
        'Type': 'Video',
      },
    );
    await _manager.playItems([playbackItem], startPosition: startPosition);
    // Registered only once the new media is up, so trailing positions from the
    // previous stream can never be attributed to this item.
    _active = item;
    _lastPosition = startPosition.inMilliseconds / 1000.0;
    _lastDuration = 0;
    _lastPostAt = DateTime.now();
    _nearEndPosted = false;
    _advanceRequested = false;
    _resetNextEpisodeState();
  }

  /// Flushes the last known position and stops tracking.
  void endSession() {
    final active = _active;
    _active = null;
    _nearEndPosted = false;
    _advanceRequested = false;
    _resetNextEpisodeState();
    if (active != null) unawaited(_post(active));
    _lastPosition = 0;
    _lastDuration = 0;
    _lastPostAt = null;
  }

  void _resetNextEpisodeState() {
    _nextResolveStarted = false;
    _advanceCancelled = false;
    _pendingNextItem = null;
    _pendingNextUrl = null;
    _pendingNextLabel = null;
    nextEpisodePrompt.value = null;
  }

  // ── Playback observation ───────────────────────────────────────────────────

  /// Feeds a position tick. Cheap no-op when nothing IPTV is being tracked.
  void onPosition(Duration position, Duration duration) {
    final active = _active;
    if (active == null) return;
    final seconds = position.inMilliseconds / 1000.0;
    final total = duration.inMilliseconds / 1000.0;
    if (seconds <= 0) return;
    _lastPosition = seconds;
    if (total > 0) _lastDuration = total;

    final remaining = _lastDuration > 0 ? _lastDuration - seconds : double.infinity;
    final nearEnd = remaining <= _endThreshold.inSeconds;

    if (nearEnd && seconds >= _minPlayedBeforeAdvance.inSeconds) {
      // Post once on entering the end window so the backend's auto-"watched"
      // flip is recorded even if the stream is torn down before the next
      // periodic tick.
      if (!_nearEndPosted) {
        _nearEndPosted = true;
        unawaited(_post(active));
      }
      // Episodes: resolve the next one (once) and drive the countdown overlay
      // instead of jumping silently. The overlay plays it at zero, or the user
      // can cancel.
      if (active.isEpisode &&
          !_advanceCancelled &&
          _manager.autoAdvanceEnabled) {
        unawaited(_ensureNextResolved(active));
        _publishPrompt(active, remaining);
        // At the end of the countdown, play the next episode ourselves rather
        // than relying on a clean "completed" event (some VOD streams just
        // EOF). Idempotent — the completion hook may also call this.
        if (remaining <= 1 && _pendingNextItem != null) {
          unawaited(playPendingNext());
        }
      }
      return;
    }
    // Left the end window (e.g. user seeked back) — hide the countdown.
    if (nextEpisodePrompt.value != null) nextEpisodePrompt.value = null;

    final last = _lastPostAt;
    if (last != null && DateTime.now().difference(last) < _postInterval) return;
    unawaited(_post(active));
  }

  /// Records the position whenever playback pauses.
  void onPlayingChanged(bool playing) {
    if (playing) return;
    final active = _active;
    if (active != null) unawaited(_post(active));
  }

  /// Called when the queue reports the session ended. Returns true when a next
  /// episode was started instead (so the caller should stay on the player).
  /// The countdown overlay normally triggers the handoff first; this is the
  /// fallback for when the stream ends before the countdown reaches zero.
  Future<bool> maybeAdvanceOnCompletion() {
    if (_advanceCancelled) return Future<bool>.value(false);
    return playPendingNext();
  }

  /// Plays the resolved next episode now (called by the countdown overlay at
  /// zero, by "Play now", or by [maybeAdvanceOnCompletion]). Idempotent — only
  /// the first call in a handoff does anything. Returns true if it started.
  Future<bool> playPendingNext() {
    final pending = _advanceFuture;
    if (pending != null) return pending;
    if (_advanceRequested || _advanceCancelled) {
      return Future<bool>.value(false);
    }
    if (!_manager.autoAdvanceEnabled) return Future<bool>.value(false);
    final current = _active;
    if (current == null || !current.isEpisode) {
      return Future<bool>.value(false);
    }
    _advanceRequested = true;
    nextEpisodePrompt.value = null;
    final future = _advanceToNextEpisode(current);
    _advanceFuture = future;
    future.whenComplete(() {
      if (_advanceFuture == future) _advanceFuture = null;
    });
    return future;
  }

  /// User dismissed the countdown — let the episode finish without advancing.
  void cancelPendingNext() {
    _advanceCancelled = true;
    _pendingNextItem = null;
    _pendingNextUrl = null;
    _pendingNextLabel = null;
    nextEpisodePrompt.value = null;
  }

  Future<void> _post(IptvRecentItem item) async {
    if (_lastPosition <= 0) return;
    _lastPostAt = DateTime.now();
    await _repo.saveProgress(
      type: item.type,
      itemId: item.itemId,
      seriesId: item.isEpisode ? item.seriesId : null,
      seasonNumber: item.isEpisode ? item.seasonNumber : null,
      episodeNumber: item.isEpisode ? item.episodeNumber : null,
      currentTime: _lastPosition,
      totalDuration: _lastDuration,
    );
  }

  // ── Autoplay next episode ──────────────────────────────────────────────────

  /// Resolves the next episode once and stores it, so the countdown overlay can
  /// show its title immediately and playback is instant at zero. Fails soft.
  Future<void> _ensureNextResolved(IptvRecentItem current) async {
    if (_nextResolveStarted) return;
    _nextResolveStarted = true;
    final seriesId = current.seriesId;
    if (seriesId == null || seriesId.isEmpty) return;
    try {
      final info =
          await _repo.getSeriesInfo(seriesId, seriesName: current.seriesTitle);
      final next = nextEpisodeAfter(
        info,
        seasonNumber: current.seasonNumber,
        episodeNumber: current.episodeNumber,
      );
      if (next == null) return;
      _pendingNextItem = IptvRecentItem(
        type: IptvProgressType.episode,
        itemId: next.id.toString(),
        title: next.title,
        poster: next.poster ?? current.poster,
        seriesId: seriesId,
        seriesTitle: current.seriesTitle ?? info.name,
        seasonNumber: next.seasonNumber,
        episodeNumber: next.episodeNumber,
        episodeId: next.id.toString(),
      );
      _pendingNextUrl = _repo.resolveEpisodeStreamUrl(next);
      final code = (next.seasonNumber != null && next.episodeNumber != null)
          ? 'S${next.seasonNumber} E${next.episodeNumber}'
          : '';
      _pendingNextLabel = next.title.isEmpty
          ? code
          : (code.isEmpty ? next.title : '$code · ${next.title}');
    } catch (_) {
      // Leave pending null — the overlay simply won't show for this episode.
    }
  }

  /// Publishes/updates the countdown overlay for the resolved next episode.
  void _publishPrompt(IptvRecentItem current, double remaining) {
    if (_advanceCancelled || _advanceRequested) return;
    final next = _pendingNextItem;
    if (next == null) return; // not resolved yet, or no next episode
    final secs = remaining.isFinite ? remaining.ceil().clamp(0, 60) : 0;
    nextEpisodePrompt.value = IptvNextEpisodePrompt(
      seriesTitle:
          next.seriesTitle ?? current.seriesTitle ?? current.title,
      episodeLabel: _pendingNextLabel ?? next.title,
      poster: next.poster,
      secondsRemaining: secs,
    );
  }

  Future<bool> _advanceToNextEpisode(IptvRecentItem current) async {
    try {
      // Final position for the episode that just finished, then stop
      // attributing positions while the handoff happens.
      await _post(current);
      _active = null;
      // Resolve now if the end window was too short to pre-resolve.
      if (_pendingNextItem == null) await _ensureNextResolved(current);
      final next = _pendingNextItem;
      final url = _pendingNextUrl;
      if (next == null || url == null) return false;
      await startPlayback(next, url);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The episode that follows season [seasonNumber] / episode [episodeNumber]:
  /// the next episode number in the same season, else the first episode of the
  /// next season that has any, else null.
  static IptvEpisode? nextEpisodeAfter(
    IptvSeriesInfo info, {
    int? seasonNumber,
    int? episodeNumber,
  }) {
    if (seasonNumber == null || episodeNumber == null) return null;
    IptvEpisode? best;
    for (final episode in info.episodesBySeason[seasonNumber] ??
        const <IptvEpisode>[]) {
      final number = episode.episodeNumber;
      if (number == null || number <= episodeNumber) continue;
      if (best == null || number < best.episodeNumber!) best = episode;
    }
    if (best != null) return best;

    final laterSeasons = info.seasonNumbers
        .where((season) => season > seasonNumber)
        .toList(growable: false)
      ..sort();
    for (final season in laterSeasons) {
      final episodes = info.episodesBySeason[season] ?? const <IptvEpisode>[];
      if (episodes.isEmpty) continue;
      IptvEpisode first = episodes.first;
      for (final episode in episodes) {
        final number = episode.episodeNumber;
        final bestNumber = first.episodeNumber;
        if (number != null && (bestNumber == null || number < bestNumber)) {
          first = episode;
        }
      }
      return first;
    }
    return null;
  }
}
