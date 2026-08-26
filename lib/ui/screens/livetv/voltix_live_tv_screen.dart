import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:playback_core/playback_core.dart';
import 'package:voltix_design/voltix_design.dart';

import '../../../data/models/aggregated_item.dart';
import '../../../data/models/iptv_models.dart';
import '../../../data/repositories/voltix_iptv_repository.dart';
import '../../../data/services/iptv_progress_reporter.dart';
import '../../../data/services/iptv_recent_store.dart';
import '../../../preference/user_preferences.dart';
import '../../../util/focus/key_event_utils.dart';
import '../../navigation/destinations.dart';
import '../../widgets/focus/request_initial_focus.dart';

/// Native Voltix Live TV screen backed by the Voltix backend IPTV API.
///
/// Replaces the old WebView-based `XtreamIptvScreen`. Built for entry-level
/// Android TVs: builder-based lists/grids, small cache extents, downscaled
/// decoded images, no blur/shadow/opacity animations, selective rebuilds via
/// [ValueNotifier], and EPG fetches throttled to the focused channel only.
/// Shows an IPTV detail sheet as a centered, height-capped dialog so it never
/// clips at the bottom (bottom sheets were being cut off by TV overscan).
Future<void> _showCenteredIptvSheet({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogCtx) => Dialog(
      backgroundColor: _LiveTvPalette.bg,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 28),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 760,
          maxHeight: MediaQuery.sizeOf(dialogCtx).height * 0.85,
        ),
        child: builder(dialogCtx),
      ),
    ),
  );
}

class VoltixLiveTvScreen extends StatefulWidget {
  const VoltixLiveTvScreen({super.key});

  @override
  State<VoltixLiveTvScreen> createState() => _VoltixLiveTvScreenState();
}

// ─── Public launchers (reused by Home for favourited IPTV series / movies) ───
// These build a minimal [IptvContentItem] from the fields Home stores on its
// AggregatedItems and reuse the exact detail sheets the Live TV screen shows,
// so a favourited series/movie opens its detail (season/episode selector or
// VOD play) instead of being played as a live channel.

/// Channel names arrive prefixed by the provider (e.g. "DSTV: M-NET FHD").
/// The prefix is noise in the UI, so strip it for display.
String _cleanChannelName(String title) {
  final cleaned = title.replaceFirst(
    RegExp(r'^\s*d\s*[\-_]?\s*stv\s*[:\-\u2013\u2014|]?\s*', caseSensitive: false),
    '',
  );
  return cleaned.trim().isEmpty ? title.trim() : cleaned.trim();
}

/// Continue Watching entry for a VOD movie.
IptvRecentItem _movieRecentItem(IptvContentItem movie) => IptvRecentItem(
      type: IptvProgressType.movie,
      itemId: movie.id,
      title: movie.title,
      poster: movie.poster,
      streamId: movie.streamId,
      containerExtension: movie.containerExtension,
    );

/// Continue Watching entry for [episode] of the series [series].
IptvRecentItem _episodeRecentItem(IptvEpisode episode, IptvContentItem series) =>
    IptvRecentItem(
      type: IptvProgressType.episode,
      itemId: episode.id.toString(),
      title: episode.title,
      poster: episode.poster ?? series.poster,
      containerExtension: episode.containerExtension,
      seriesId: series.id,
      seriesTitle: series.title,
      seasonNumber: episode.seasonNumber,
      episodeNumber: episode.episodeNumber,
      episodeId: episode.id.toString(),
    );

/// Saved position to resume [itemId] at, or [Duration.zero] to start from the
/// beginning (nothing saved, already watched, or too close to either end —
/// see [IptvProgress.canResume]). Fails soft: any error means "from zero".
Future<Duration> _iptvResumePosition(
  VoltixIptvRepository repo,
  String type,
  String itemId,
) async {
  try {
    final progress = (await repo.getProgress(type, <String>[itemId]))[itemId];
    return progress != null && progress.canResume
        ? progress.position
        : Duration.zero;
  } catch (_) {
    return Duration.zero;
  }
}

/// Plays an IPTV movie/episode through [IptvProgressReporter] — which records
/// it in Continue Watching, reports progress and autoplays the next episode —
/// resuming where it was left off, then opens the player. Live channels never
/// come through here (see `_playUrl` / `_playLiveChannel`).
Future<void> _launchIptvItem(
  BuildContext context,
  VoltixIptvRepository repo,
  IptvRecentItem item,
  String url,
) async {
  try {
    final startPosition =
        await _iptvResumePosition(repo, item.type, item.itemId);
    await GetIt.instance<IptvProgressReporter>()
        .startPlayback(item, url, startPosition: startPosition);
    if (context.mounted) context.push(Destinations.videoPlayer);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Playback failed: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }
}

/// Opens the IPTV **series** detail sheet (season/episode selector) for the
/// series identified by [seriesId]. Home calls this so a favourited series
/// opens correctly instead of being played as a live channel.
Future<void> showIptvSeriesDetailForItem(
  BuildContext context, {
  required String seriesId,
  required String title,
  String? poster,
}) async {
  final repo = VoltixIptvRepository();
  if (!repo.hasSession) return;
  final item = IptvContentItem(
    id: seriesId,
    title: title,
    categoryId: '',
    poster: poster,
  );
  Set<String> favs = const <String>{};
  try {
    favs = await repo.getFavorites(IptvSection.series);
  } catch (_) {}
  // Admins get the "Download Series" action here too — previously this launcher
  // (used by the home favourite / continue-watching rows) always defaulted to
  // false, so admins only saw the option inside the Live TV page itself.
  final isAdmin = await repo.fetchIsAdmin();
  if (!context.mounted) return;
  _showCenteredIptvSheet(
    context: context,
    builder: (sheetContext) => _SeriesDetailSheet(
      repo: repo,
      item: item,
      isAdmin: isAdmin,
      isFavorite: favs.contains(seriesId),
      onToggleFavorite: () async {
        final makeFav = !favs.contains(seriesId);
        try {
          await repo.toggleFavorite(IptvSection.series, seriesId,
              makeFavorite: makeFav);
          favs = makeFav
              ? <String>{...favs, seriesId}
              : (<String>{...favs}..remove(seriesId));
          return makeFav;
        } catch (_) {
          return !makeFav;
        }
      },
      onPlayEpisode: (episode) {
        Navigator.of(sheetContext).pop();
        unawaited(_launchIptvItem(
          context,
          repo,
          _episodeRecentItem(episode, item),
          repo.resolveEpisodeStreamUrl(episode),
        ));
      },
    ),
  );
}

/// Opens the IPTV **movie** detail sheet for a VOD movie. Home calls this so a
/// favourited movie plays its VOD stream (not a live URL). [movieId] is the
/// content id; [streamId] (when known) yields the correct stream URL.
Future<void> showIptvMovieDetailForItem(
  BuildContext context, {
  required String movieId,
  int? streamId,
  required String title,
  String? poster,
  String? containerExtension,
}) async {
  final repo = VoltixIptvRepository();
  if (!repo.hasSession) return;
  final item = IptvContentItem(
    id: movieId,
    title: title,
    categoryId: '',
    poster: poster,
    streamId: streamId,
    containerExtension: containerExtension,
  );
  Set<String> favs = const <String>{};
  try {
    favs = await repo.getFavorites(IptvSection.movies);
  } catch (_) {}
  if (!context.mounted) return;
  _showCenteredIptvSheet(
    context: context,
    builder: (sheetContext) => _MovieDetailSheet(
      item: item,
      isFavorite: favs.contains(movieId),
      onToggleFavorite: () async {
        final makeFav = !favs.contains(movieId);
        try {
          await repo.toggleFavorite(IptvSection.movies, movieId,
              makeFavorite: makeFav);
          favs = makeFav
              ? <String>{...favs, movieId}
              : (<String>{...favs}..remove(movieId));
          return makeFav;
        } catch (_) {
          return !makeFav;
        }
      },
      onPlay: () {
        Navigator.of(sheetContext).pop();
        unawaited(_launchIptvItem(
          context,
          repo,
          _movieRecentItem(item),
          repo.resolveVodStreamUrl(item),
        ));
      },
    ),
  );
}

class _HeroState {
  final IptvContentItem channel;
  final List<IptvEpgEntry>? epg; // null while loading
  final bool epgFailed;

  const _HeroState(this.channel, {this.epg, this.epgFailed = false});
}

/// Live TV palette, resolved from the active theme on every build.
///
/// This screen was written against a fixed blue-on-navy palette and never
/// referenced the theme system, so applying a theme recoloured every page
/// except this one. Each former literal now maps to the nearest theme token,
/// so Live TV follows Voltix, Neon Pulse, Glass and any Theme Store theme.
///
/// AppColorScheme reads ThemeRegistry.active through getters, and app.dart
/// rebuilds MaterialApp from the active spec, so these resolve fresh on each
/// build with no listener needed here.
class _LiveTvPalette {
  const _LiveTvPalette._();

  /// Page backdrop.
  static Color get bg => AppColorScheme.background;

  /// Cards, rows and side panels at rest.
  static Color get panel => AppColorScheme.surface;

  /// Raised or focused surface - one step up from [panel].
  static Color get panelFocused => AppColorScheme.surfaceVariant;

  /// Unfocused chips and pills.
  static Color get chip => AppColorScheme.buttonNormal;

  /// Primary accent: selection, focus rings, active icons, cursor.
  static Color get accent => AppColorScheme.accent;

  /// Softer accent for secondary labels. Blended toward the foreground so it
  /// stays legible whatever hue the theme's accent is.
  static Color get accentSoft =>
      Color.lerp(AppColorScheme.accent, AppColorScheme.onSurface, 0.45)!;

  /// Overlay behind modals and gradients.
  static Color get scrim => AppColorScheme.scrim;

  /// Favourite star. Deliberately theme-independent: gold reads as "favourite"
  /// regardless of palette, and tinting it by accent loses that meaning.
  static const Color favourite = Color(0xFFFFC933);
}

class _VoltixLiveTvScreenState extends State<VoltixLiveTvScreen> {
  static const _pageSize = 60;

  late final VoltixIptvRepository _repo;
  late final IptvRecentStore _recentStore;
  late final UserPreferences _prefs;

  IptvSection _section = IptvSection.live;
  List<IptvCategory> _categories = const [];
  bool _categoriesLoading = true;
  String? _categoriesError;
  String _selectedCategoryId = 'all';

  final List<IptvContentItem> _items = [];
  bool _itemsLoading = true;
  String? _itemsError;
  bool _hasMore = false;
  int _nextOffset = 0;
  bool _loadingMore = false;
  int _contentRequestId = 0;
  // Cancel in-flight requests when the section/category changes so a slow old
  // response can't delay or clobber the new selection.
  CancelToken? _contentCancel;
  CancelToken? _categoriesCancel;

  final Map<IptvSection, Set<String>> _favorites = {
    IptvSection.live: <String>{},
    IptvSection.movies: <String>{},
    IptvSection.series: <String>{},
  };

  final ValueNotifier<_HeroState?> _hero = ValueNotifier<_HeroState?>(null);
  final ValueNotifier<IptvContentItem?> _focusedVod =
      ValueNotifier<IptvContentItem?>(null);
  Timer? _epgDebounce;
  int _epgRequestId = 0;

  // ── Per-tile "on now" EPG ───────────────────────────────────────────────────
  //
  // /api/iptv/content embeds `currentProgram` for only a subset of channels
  // (whichever the provider's EPG feed covers), so most tiles rendered no
  // programme title and no progress bar. Tiles ask for their own entry as they
  // scroll into view and the result is cached here by channel id.
  //
  // Bounded on purpose: GridView only builds visible tiles (+cacheExtent), and
  // _maxConcurrentTileEpg keeps entry-level TVs from firing dozens of parallel
  // requests. The repository layer caches per channel, so scrolling back is free.
  static const _maxConcurrentTileEpg = 3;
  final Map<String, IptvEpgEntry?> _tileEpg = {};
  final Set<String> _tileEpgInFlight = {};
  final List<IptvContentItem> _tileEpgQueue = [];

  bool _isAdmin = false;

  // ── Continue Watching (in-progress IPTV movies / episodes) ─────────────────
  List<_ContinueEntry> _continueWatching = const [];
  int _continueRequestId = 0;

  // ── Search (across live / movies / series) ─────────────────────────────────
  bool _searchActive = false;
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  int _searchRequestId = 0;
  CancelToken? _searchCancel;
  bool _searchLoading = false;
  String _searchQuery = '';
  List<IptvContentItem> _searchLive = const [];
  List<IptvContentItem> _searchMovies = const [];
  List<IptvContentItem> _searchSeries = const [];

  @override
  void initState() {
    super.initState();
    _repo = VoltixIptvRepository();
    _recentStore = GetIt.instance<IptvRecentStore>();
    _prefs = GetIt.instance<UserPreferences>();
    _loadSection(IptvSection.live);
    unawaited(_loadContinueWatching());
    // Admin gate for the series download feature (hidden for non-admins and
    // when the backend endpoint is absent).
    _repo.fetchIsAdmin().then((admin) {
      if (mounted && admin) setState(() => _isAdmin = admin);
    });
  }

  @override
  void dispose() {
    _epgDebounce?.cancel();
    _contentCancel?.cancel();
    _categoriesCancel?.cancel();
    _searchDebounce?.cancel();
    _searchCancel?.cancel();
    _searchController.dispose();
    _hero.dispose();
    _focusedVod.dispose();
    super.dispose();
  }

  // ── Data loading ────────────────────────────────────────────────────────────

  Future<void> _loadSection(IptvSection section,
      {bool forceRefresh = false}) async {
    // Cancel a previous section's category request so its slow response can't
    // clobber the new selection.
    if (_searchActive) _resetSearchState();
    _categoriesCancel?.cancel();
    final catCancel = CancelToken();
    _categoriesCancel = catCancel;
    _focusedVod.value = null;
    // Fast first paint: show cached categories instantly if we have them.
    final cachedCats = forceRefresh ? null : _repo.peekCategories(section);
    setState(() {
      _section = section;
      _selectedCategoryId = 'all';
      if (cachedCats != null) {
        _categories = cachedCats;
        _categoriesLoading = false;
      } else {
        _categories = const [];
        _categoriesLoading = true;
      }
      _categoriesError = null;
    });
    // Categories + first content page + favourites fire in parallel.
    unawaited(_loadContent(reset: true, forceRefresh: forceRefresh));
    unawaited(_loadFavorites(section, forceRefresh: forceRefresh));
    try {
      final categories =
          await _repo.getCategories(section, forceRefresh: forceRefresh, cancelToken: catCancel);
      if (!mounted || _section != section || catCancel.isCancelled) return;
      setState(() {
        _categories = categories;
        _categoriesLoading = false;
      });
    } on VoltixIptvException catch (e) {
      if (!mounted || _section != section || catCancel.isCancelled) return;
      // Keep any cached categories visible rather than clobbering with an error.
      if (_categories.isNotEmpty) {
        setState(() => _categoriesLoading = false);
        return;
      }
      setState(() {
        _categories = const [];
        _categoriesLoading = false;
        _categoriesError = e.message;
      });
    }
  }

  Future<void> _loadFavorites(IptvSection section,
      {bool forceRefresh = false}) async {
    // Instant paint from cache, then revalidate.
    final cached = forceRefresh ? null : _repo.peekFavorites(section);
    if (cached != null) _favorites[section] = cached;
    try {
      final favs = await _repo.getFavorites(section, forceRefresh: forceRefresh);
      if (!mounted) return;
      _favorites[section] = favs;
    } catch (_) {
      // Non-critical — favourites stay empty until the next refresh.
    }
  }

  Future<void> _loadContent(
      {required bool reset, bool forceRefresh = false}) async {
    final requestId = ++_contentRequestId;
    final section = _section;
    final categoryId = _selectedCategoryId;
    if (reset) {
      // Cancel any in-flight content request for the previous selection.
      _contentCancel?.cancel();
      _contentCancel = CancelToken();
      // Fast first paint: show cached page instantly (stale allowed) and only
      // show the spinner when we have nothing to display.
      final cached = forceRefresh
          ? null
          : _repo.peekContent(section,
              categoryId: categoryId, offset: 0, limit: _pageSize);
      setState(() {
        _items.clear();
        if (cached != null) {
          _items.addAll(cached.items);
          _itemsLoading = false;
          _hasMore = cached.hasMore;
          _nextOffset = cached.nextOffset ?? _items.length;
        } else {
          _itemsLoading = true;
          _hasMore = false;
          _nextOffset = 0;
        }
        _itemsError = null;
        _loadingMore = false;
      });
    }
    final cancelToken = _contentCancel;
    try {
      final page = await _repo.getContent(
        section,
        categoryId: categoryId,
        offset: reset ? 0 : _nextOffset,
        limit: _pageSize,
        forceRefresh: forceRefresh,
        cancelToken: cancelToken,
      );
      if (!mounted || requestId != _contentRequestId) return;
      setState(() {
        if (reset) _items.clear();
        _items.addAll(page.items);
        _itemsLoading = false;
        _loadingMore = false;
        _hasMore = page.hasMore;
        _nextOffset = page.nextOffset ?? (_items.length);
      });
    } on VoltixIptvException catch (e) {
      // Dropped/cancelled or superseded response — treat as a no-op.
      if (!mounted || requestId != _contentRequestId) return;
      if (cancelToken?.isCancelled ?? false) return;
      setState(() {
        _itemsLoading = false;
        _loadingMore = false;
        // Keep cached items visible; only surface the error on an empty grid.
        if (reset && _items.isEmpty) _itemsError = e.message;
      });
    }
  }

  void _maybeLoadMore() {
    if (_loadingMore || !_hasMore || _itemsLoading) return;
    _loadingMore = true;
    unawaited(_loadContent(reset: false));
  }

  void _selectCategory(String categoryId) {
    if (_selectedCategoryId == categoryId) return;
    setState(() {
      if (_searchActive) _resetSearchState();
      _selectedCategoryId = categoryId;
    });
    unawaited(_loadContent(reset: true));
  }

  // ── Search (across all three sections) ──────────────────────────────────────

  void _openSearch() {
    if (_searchActive) return;
    setState(() => _searchActive = true);
  }

  void _closeSearch() {
    setState(_resetSearchState);
  }

  // Resets all search fields (does NOT call setState — callers wrap it).
  void _resetSearchState() {
    _searchDebounce?.cancel();
    _searchCancel?.cancel();
    _searchActive = false;
    _searchLoading = false;
    _searchQuery = '';
    _searchController.clear();
    _searchLive = const [];
    _searchMovies = const [];
    _searchSeries = const [];
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    final query = value.trim();
    _searchDebounce = Timer(
      const Duration(milliseconds: 400),
      () => unawaited(_runSearch(query)),
    );
  }

  Future<void> _runSearch(String query) async {
    if (query.isEmpty) {
      _searchCancel?.cancel();
      if (!mounted) return;
      setState(() {
        _searchQuery = '';
        _searchLoading = false;
        _searchLive = const [];
        _searchMovies = const [];
        _searchSeries = const [];
      });
      return;
    }
    final requestId = ++_searchRequestId;
    // Cancel a prior in-flight search so a slow response can't clobber a newer
    // query (mirrors the _contentRequestId / CancelToken guard used elsewhere).
    _searchCancel?.cancel();
    final cancel = _searchCancel = CancelToken();
    setState(() {
      _searchQuery = query;
      _searchLoading = true;
    });
    try {
      final results = await Future.wait([
        _repo.getContent(IptvSection.live,
            search: query, limit: 40, cancelToken: cancel),
        _repo.getContent(IptvSection.movies,
            search: query, limit: 40, cancelToken: cancel),
        _repo.getContent(IptvSection.series,
            search: query, limit: 40, cancelToken: cancel),
      ]);
      if (!mounted || requestId != _searchRequestId) return;
      setState(() {
        _searchLive = results[0].items;
        _searchMovies = results[1].items;
        _searchSeries = results[2].items;
        _searchLoading = false;
      });
    } on VoltixIptvException {
      // Cancelled or superseded — treat as a no-op; keep any prior results.
      if (!mounted || requestId != _searchRequestId) return;
      if (cancel.isCancelled) return;
      setState(() => _searchLoading = false);
    }
  }

  // ── EPG (throttled to the focused channel) ─────────────────────────────────

  void _onVodFocused(IptvContentItem item) {
    _focusedVod.value = item;
  }

  /// Queues [channel] for an "on now" EPG lookup so its tile can show the
  /// current programme and progress bar. No-op when the item already carries an
  /// embedded `currentProgram`, is cached, or is already queued.
  void _requestTileEpg(IptvContentItem channel) {
    if (channel.currentProgram != null) return;
    final id = channel.id;
    if (_tileEpg.containsKey(id) || _tileEpgInFlight.contains(id)) return;
    if (_tileEpgQueue.any((c) => c.id == id)) return;
    _tileEpgQueue.add(channel);
    _pumpTileEpgQueue();
  }

  void _pumpTileEpgQueue() {
    while (_tileEpgInFlight.length < _maxConcurrentTileEpg &&
        _tileEpgQueue.isNotEmpty) {
      final channel = _tileEpgQueue.removeAt(0);
      final id = channel.id;
      if (_tileEpg.containsKey(id) || _tileEpgInFlight.contains(id)) continue;
      _tileEpgInFlight.add(id);

      _repo.getSimpleEpg(channel, source: _epgSourcePref).then((entries) {
        if (!mounted) return;
        final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        // Only the programme genuinely airing right now. Deliberately no
        // fallback to "first entry with times" — getSimpleEpg returns a 2-hour
        // window, so that would label an upcoming programme as on-now and draw
        // a progress bar for something that hasn't started.
        IptvEpgEntry? airing;
        for (final entry in entries) {
          if (entry.isAiringAt(nowSeconds)) {
            airing = entry;
            break;
          }
        }
        setState(() => _tileEpg[id] = airing);
      }).catchError((_) {
        // Cache the miss so a failing channel isn't retried on every rebuild.
        if (mounted) setState(() => _tileEpg[id] = null);
      }).whenComplete(() {
        _tileEpgInFlight.remove(id);
        if (mounted) _pumpTileEpgQueue();
      });
    }
  }

  // ── Live TV settings ────────────────────────────────────────────────────────

  /// Columns for the channel grid at [width].
  ///
  /// Honours the viewer's pinned column count when set, still clamped so a very
  /// narrow window can't produce unusably thin tiles. 0 falls back to fitting as
  /// many [_channelTileTargetWidth] tiles as the width allows.
  int _resolveChannelColumns(double width) {
    final maxThatFit = (width / 120).floor().clamp(2, 12).toInt();
    final pinned = _channelColumnsPref;
    if (pinned > 0) return pinned.clamp(2, maxThatFit).toInt();
    return (width / _channelTileTargetWidth).floor().clamp(2, 10).toInt();
  }

  /// Channel tiles per row. 0 = Auto (fit as many as the width allows).
  int get _channelColumnsPref =>
      _prefs.get(UserPreferences.liveTvChannelColumns);

  /// Which programme guide to request: 'dstv' or 'provider'.
  String get _epgSourcePref => _prefs.get(UserPreferences.liveTvEpgSource);

  /// Options offered in the settings sheet. Auto first, then denser/larger.
  static const _channelColumnChoices = <int>[0, 3, 4, 5, 6, 7, 8];

  String _columnChoiceLabel(int value) {
    if (value == 0) return 'Auto (fit to screen)';
    if (value <= 3) return '$value per row - largest tiles';
    if (value >= 8) return '$value per row - most channels';
    return '$value per row';
  }

  void _showLiveTvSettings() {
    _showCenteredIptvSheet(
      context: context,
      builder: (sheetContext) => _LiveTvSettingsSheet(
        selectedColumns: _channelColumnsPref,
        columnChoices: _channelColumnChoices,
        columnLabelFor: _columnChoiceLabel,
        onColumnsSelected: (value) async {
          Navigator.of(sheetContext).pop();
          await _prefs.set(UserPreferences.liveTvChannelColumns, value);
          if (mounted) setState(() {});
        },
        selectedEpgSource: _epgSourcePref,
        onEpgSourceSelected: (value) async {
          Navigator.of(sheetContext).pop();
          await _prefs.set(UserPreferences.liveTvEpgSource, value);
          if (!mounted) return;
          // Guide entries already fetched came from the old source, so drop them
          // rather than leaving a mix of the two on screen.
          setState(() {
            _tileEpg.clear();
            _tileEpgQueue.clear();
          });
          final channel = _hero.value?.channel;
          if (channel != null) {
            _hero.value = _HeroState(channel);
            _onChannelFocusedForce(channel);
          }
        },
      ),
    );
  }

  /// Re-fetches the hero's guide entry, bypassing the "same channel" guard in
  /// [_onChannelFocused] - needed after a guide source change, where the channel
  /// is unchanged but its data must be reloaded.
  void _onChannelFocusedForce(IptvContentItem channel) {
    final requestId = ++_epgRequestId;
    _repo.getSimpleEpg(channel, source: _epgSourcePref, forceRefresh: true).then((epg) {
      if (!mounted || requestId != _epgRequestId) return;
      if (_hero.value?.channel.id != channel.id) return;
      _hero.value = _HeroState(channel, epg: epg);
    }).catchError((_) {
      if (!mounted || requestId != _epgRequestId) return;
      if (_hero.value?.channel.id != channel.id) return;
      _hero.value = _HeroState(channel, epgFailed: true);
    });
  }

  void _onChannelFocused(IptvContentItem channel) {
    final current = _hero.value;
    if (current?.channel.id == channel.id) return;
    // Show provisional hero immediately (uses embedded currentProgram).
    _hero.value = _HeroState(channel);
    _epgDebounce?.cancel();
    _epgDebounce = Timer(const Duration(milliseconds: 300), () {
      final requestId = ++_epgRequestId;
      _repo.getSimpleEpg(channel, source: _epgSourcePref).then((epg) {
        if (!mounted || requestId != _epgRequestId) return;
        if (_hero.value?.channel.id != channel.id) return;
        _hero.value = _HeroState(channel, epg: epg);
      }).catchError((_) {
        if (!mounted || requestId != _epgRequestId) return;
        if (_hero.value?.channel.id != channel.id) return;
        _hero.value = _HeroState(channel, epgFailed: true);
      });
    });
  }

  // ── Favorites ───────────────────────────────────────────────────────────────

  bool _isFavorite(String itemId) =>
      _favorites[_section]?.contains(itemId) ?? false;

  Future<bool> _toggleFavorite(IptvSection section, String itemId) async {
    final favs = _favorites[section] ?? <String>{};
    final makeFavorite = !favs.contains(itemId);
    try {
      await _repo.toggleFavorite(section, itemId, makeFavorite: makeFavorite);
      if (makeFavorite) {
        favs.add(itemId);
      } else {
        favs.remove(itemId);
      }
      _favorites[section] = favs;
      if (_selectedCategoryId == 'favorites' && mounted) {
        unawaited(_loadContent(reset: true));
      }
      return makeFavorite;
    } catch (_) {
      return !makeFavorite; // unchanged
    }
  }

  // ── Playback (existing native live player path) ─────────────────────────────

  Future<void> _playUrl(String url, String title, {required bool isLive}) async {
    final manager = GetIt.instance<PlaybackManager>();
    final itemId = 'iptv_${DateTime.now().millisecondsSinceEpoch}';
    final playbackItem = AggregatedItem(
      id: itemId,
      serverId: 'iptv',
      rawData: {
        'Id': itemId,
        'url': url,
        'Name': title,
        'isLive': isLive,
        'Type': 'Video',
      },
    );
    try {
      await manager.playItems([playbackItem]);
      if (mounted) context.push(Destinations.videoPlayer);
    } catch (e) {
      // On first failure for live streams, refresh the session token and retry
      // once — the most common cause is a stale token baked into the URL.
      if (isLive) {
        final refreshed = await _repo.ensureTokenFresh();
        if (refreshed && mounted) {
          final freshUrl = _repo.resolveLiveStreamUrl(
            _hero.value?.channel ??
                IptvContentItem(id: '', title: title, categoryId: ''),
          );
          final retryItem = AggregatedItem(
            id: 'iptv_retry_${DateTime.now().millisecondsSinceEpoch}',
            serverId: 'iptv',
            rawData: {
              'Id': 'iptv_retry_${DateTime.now().millisecondsSinceEpoch}',
              'url': freshUrl,
              'Name': title,
              'isLive': true,
              'Type': 'Video',
            },
          );
          try {
            await manager.playItems([retryItem]);
            if (mounted) context.push(Destinations.videoPlayer);
            return;
          } catch (_) {
            // Fall through to show the original error.
          }
        }
      }
      if (mounted) {
        // Show a more informative error message so users can report
        // actionable details instead of just "not working".
        final errorMsg = e.toString();
        final host = Uri.tryParse(url)?.host ?? '';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              host.isNotEmpty
                  ? 'Stream failed ($host): $errorMsg'
                  : 'Playback failed: $errorMsg',
            ),
            backgroundColor: Colors.redAccent,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  void _playLiveChannel(IptvContentItem channel) {
    unawaited(() async {
      // Ensure the session token is fresh before building the stream URL —
      // stale tokens baked into the URL are the #1 cause of stream failures
      // after the app has been idle.
      try {
        await _repo.ensureTokenFresh();
      } catch (_) {
        // Proceed anyway — the backend may still accept the current token.
      }
      await _playUrl(
        _repo.resolveLiveStreamUrl(channel),
        _cleanChannelName(channel.title),
        isLive: true,
      );
    }());
  }

  // ── Playback (VOD movies / series episodes, tracked for Continue Watching) ──

  /// Starts [item] through [IptvProgressReporter] so its position is reported
  /// and the next episode autoplays, resuming at [startPosition] when given
  /// (Continue Watching already knows it) or at the saved position otherwise.
  /// Refreshes the Continue Watching row when the player is popped.
  Future<void> _playIptvItem(
    IptvRecentItem item,
    String url, {
    Duration? startPosition,
  }) async {
    try {
      final resumeAt = startPosition ??
          await _iptvResumePosition(_repo, item.type, item.itemId);
      await GetIt.instance<IptvProgressReporter>()
          .startPlayback(item, url, startPosition: resumeAt);
      if (!mounted) return;
      await context.push(Destinations.videoPlayer);
      // Small grace period so the reporter's final progress POST lands before
      // the row re-reads it.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (mounted) unawaited(_loadContinueWatching());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Playback failed: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  // ── Continue Watching ───────────────────────────────────────────────────────

  /// Rebuilds the row: the locally remembered items (one card per movie / per
  /// series via [IptvRecentItem.dedupeKey]) crossed with their server progress,
  /// keeping only the ones that are genuinely mid-watch and sorted
  /// most-recent-first. Two batch lookups because movies and episodes use
  /// different progress `type` values. Fails soft — the row just stays hidden.
  Future<void> _loadContinueWatching() async {
    final requestId = ++_continueRequestId;
    final seen = <String>{};
    final recent = <IptvRecentItem>[];
    for (final item in _recentStore.items) {
      if (seen.add(item.dedupeKey)) recent.add(item);
    }
    if (recent.isEmpty) {
      if (mounted && _continueWatching.isNotEmpty) {
        setState(() => _continueWatching = const []);
      }
      return;
    }
    final movieIds = <String>[
      for (final item in recent)
        if (!item.isEpisode) item.itemId,
    ];
    final episodeIds = <String>[
      for (final item in recent)
        if (item.isEpisode) item.itemId,
    ];
    var movieProgress = const <String, IptvProgress>{};
    var episodeProgress = const <String, IptvProgress>{};
    try {
      final results = await Future.wait(<Future<Map<String, IptvProgress>>>[
        movieIds.isEmpty
            ? Future<Map<String, IptvProgress>>.value(
                const <String, IptvProgress>{})
            : _repo.getProgress(IptvProgressType.movie, movieIds),
        episodeIds.isEmpty
            ? Future<Map<String, IptvProgress>>.value(
                const <String, IptvProgress>{})
            : _repo.getProgress(IptvProgressType.episode, episodeIds),
      ]);
      movieProgress = results[0];
      episodeProgress = results[1];
    } catch (_) {
      return;
    }
    final entries = <_ContinueEntry>[];
    for (final item in recent) {
      final progress =
          (item.isEpisode ? episodeProgress : movieProgress)[item.itemId];
      // canResume == started, not watched, and not within seconds of the end.
      if (progress == null || !progress.canResume) continue;
      entries.add(_ContinueEntry(item, progress));
    }
    entries.sort((a, b) => b.sortKey.compareTo(a.sortKey));
    if (!mounted || requestId != _continueRequestId) return;
    setState(() => _continueWatching = entries);
  }

  /// Rebuilds the playable URL for a remembered item from the fields the recent
  /// store keeps, so resuming needs no catalogue round-trip.
  String _streamUrlForRecent(IptvRecentItem item) {
    if (item.isEpisode) {
      return _repo.resolveEpisodeStreamUrl(IptvEpisode(
        id: int.tryParse(item.episodeId ?? item.itemId) ?? 0,
        title: item.title,
        episodeNumber: item.episodeNumber,
        seasonNumber: item.seasonNumber,
        containerExtension: item.containerExtension ?? 'mp4',
        poster: item.poster,
      ));
    }
    return _repo.resolveVodStreamUrl(IptvContentItem(
      id: item.itemId,
      title: item.title,
      categoryId: '',
      poster: item.poster,
      streamId: item.streamId,
      containerExtension: item.containerExtension,
    ));
  }

  /// Drops [item] from Continue Watching everywhere (server progress + local
  /// recent list) and takes the card away immediately.
  Future<void> _removeFromContinueWatching(IptvRecentItem item) async {
    setState(() {
      _continueWatching = _continueWatching
          .where((entry) => entry.item.dedupeKey != item.dedupeKey)
          .toList(growable: false);
    });
    await _repo.clearProgress(item.type, item.itemId);
    await _recentStore.remove(item.type, item.itemId);
    if (mounted) unawaited(_loadContinueWatching());
  }

  // ── Item activation ─────────────────────────────────────────────────────────

  void _onItemSelected(IptvContentItem item) {
    switch (_section) {
      case IptvSection.live:
        _showLiveChannelSheet(item);
      case IptvSection.movies:
        _showMovieSheet(item);
      case IptvSection.series:
        _showSeriesSheet(item);
    }
  }

  void _showLiveChannelSheet(IptvContentItem item) {
    _showCenteredIptvSheet(
      context: context,
      builder: (_) => _LiveChannelSheet(
        repo: _repo,
        item: item,
        isFavorite: _isFavorite(item.id),
        onToggleFavorite: () => _toggleFavorite(IptvSection.live, item.id),
        onWatch: () {
          Navigator.of(context).pop();
          _playLiveChannel(item);
        },
      ),
    );
  }

  void _showMovieSheet(IptvContentItem item) {
    _showCenteredIptvSheet(
      context: context,
      builder: (_) => _MovieDetailSheet(
        item: item,
        isFavorite: _isFavorite(item.id),
        onToggleFavorite: () => _toggleFavorite(IptvSection.movies, item.id),
        onPlay: () {
          Navigator.of(context).pop();
          unawaited(_playIptvItem(
            _movieRecentItem(item),
            _repo.resolveVodStreamUrl(item),
          ));
        },
      ),
    );
  }

  void _showSeriesSheet(IptvContentItem item) {
    _showCenteredIptvSheet(
      context: context,
      builder: (_) => _SeriesDetailSheet(
        repo: _repo,
        item: item,
        isAdmin: _isAdmin,
        isFavorite: _isFavorite(item.id),
        onToggleFavorite: () => _toggleFavorite(IptvSection.series, item.id),
        onPlayEpisode: (episode) {
          Navigator.of(context).pop();
          unawaited(_playIptvItem(
            _episodeRecentItem(episode, item),
            _repo.resolveEpisodeStreamUrl(episode),
          ));
        },
      ),
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!_repo.hasSession) {
      return Scaffold(
        backgroundColor: _LiveTvPalette.bg,
        body: Center(
          child: Text(
            'Sign in to Voltix to use Live TV',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: _LiveTvPalette.bg,
      body: RequestInitialFocus(
        child: SafeArea(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildRail(),
              Expanded(child: _buildContentArea()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRail() {
    return SizedBox(
      width: 236,
      child: ColoredBox(
        color: _LiveTvPalette.panel,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset(
                    'assets/images/voltix_bolt.png',
                    width: 22,
                    height: 22,
                    fit: BoxFit.contain,
                    // Decoded at 2x the display size so it stays crisp without
                    // holding a full-resolution bitmap on entry-level TVs.
                    cacheWidth: 44,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Voltix Live TV',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            _RailTile(
              label: 'Search',
              icon: Icons.search_rounded,
              selected: _searchActive,
              onSelect: _openSearch,
            ),
            _RailTile(
              label: 'Live TV',
              icon: Icons.live_tv_rounded,
              selected: !_searchActive && _section == IptvSection.live,
              autofocus: true,
              onSelect: () => unawaited(_loadSection(IptvSection.live)),
            ),
            _RailTile(
              label: 'Movies',
              icon: Icons.movie_rounded,
              selected: !_searchActive && _section == IptvSection.movies,
              onSelect: () => unawaited(_loadSection(IptvSection.movies)),
            ),
            _RailTile(
              label: 'Series',
              icon: Icons.video_library_rounded,
              selected: !_searchActive && _section == IptvSection.series,
              onSelect: () => unawaited(_loadSection(IptvSection.series)),
            ),
            _RailTile(
              label: 'Settings',
              icon: Icons.tune_rounded,
              selected: false,
              onSelect: _showLiveTvSettings,
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Divider(height: 1, color: Color(0x22FFFFFF)),
            ),
            Expanded(child: _buildCategoryList()),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryList() {
    if (_categoriesLoading) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    if (_categoriesError != null) {
      return _InlineError(
        message: 'Couldn\'t load categories',
        onRetry: () => unawaited(_loadSection(_section, forceRefresh: true)),
      );
    }
    final categories = _orderedCategories(_categories);
    return ListView.builder(
      itemCount: categories.length,
      itemExtent: 42,
      // ignore: deprecated_member_use
      cacheExtent: 200,
      padding: const EdgeInsets.only(bottom: 12),
      itemBuilder: (context, index) {
        final category = categories[index];
        return _RailTile(
          label: category.count != null
              ? '${category.name} (${category.count})'
              : category.name,
          icon: category.isFavorites ? Icons.star_rounded : null,
          selected: _selectedCategoryId == category.id,
          dense: true,
          onSelect: () => _selectCategory(category.id),
        );
      },
    );
  }

  /// Orders the rail: Favorites/All pseudo-categories first, then DSTV
  /// categories grouped together, then the rest — preserving the backend's
  /// original order within each group.
  List<IptvCategory> _orderedCategories(List<IptvCategory> cats) {
    final pseudo = <IptvCategory>[];
    final dstv = <IptvCategory>[];
    final rest = <IptvCategory>[];
    for (final c in cats) {
      if (c.isFavorites || c.isAll) {
        pseudo.add(c);
      } else if (c.name.toUpperCase().contains('DSTV')) {
        dstv.add(c);
      } else {
        rest.add(c);
      }
    }
    return [...pseudo, ...dstv, ...rest];
  }

  Widget _buildContentArea() {
    if (_searchActive) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSearchBar(),
          Expanded(child: _buildSearchResults()),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_continueWatching.isNotEmpty)
          _ContinueWatchingRow(
            entries: _continueWatching,
            onSelect: (entry) => unawaited(_playIptvItem(
              entry.item,
              _streamUrlForRecent(entry.item),
              startPosition: entry.progress.position,
            )),
            onRemove: (entry) =>
                unawaited(_removeFromContinueWatching(entry.item)),
          ),
        if (_section == IptvSection.live)
          ValueListenableBuilder<_HeroState?>(
            valueListenable: _hero,
            builder: (context, hero, _) => _EpgHero(
              hero: hero,
              isFavorite:
                  hero != null && _isFavorite(hero.channel.id),
              onToggleFavorite: hero == null
                  ? null
                  : () => _toggleFavorite(IptvSection.live, hero.channel.id),
            ),
          ),
        if (_section != IptvSection.live)
          ValueListenableBuilder<IptvContentItem?>(
            valueListenable: _focusedVod,
            builder: (context, item, _) => _VodHero(
              item: item,
              isFavorite: item != null && _isFavorite(item.id),
              onToggleFavorite: item == null
                  ? null
                  : () => _toggleFavorite(_section, item.id),
              onPlay: item == null ? null : () => _onItemSelected(item),
            ),
          ),
        Expanded(child: _buildGrid()),
      ],
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Row(
        children: [
          const Icon(Icons.search_rounded, color: Colors.white54, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _searchController,
              autofocus: true,
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              onSubmitted: (v) => unawaited(_runSearch(v.trim())),
              style: const TextStyle(color: Colors.white, fontSize: 16),
              cursorColor: _LiveTvPalette.accent,
              decoration: const InputDecoration(
                hintText: 'Search Live TV, Movies and Series',
                hintStyle: TextStyle(color: Colors.white38, fontSize: 16),
                border: InputBorder.none,
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 10),
          _SheetButton(
            label: 'Close',
            icon: Icons.close_rounded,
            onSelect: _closeSearch,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchResults() {
    if (_searchLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    final query = _searchQuery.trim();
    if (query.isEmpty) {
      return const Center(
        child: Text(
          'Type to search Live TV, Movies and Series',
          style: TextStyle(color: Colors.white54, fontSize: 15),
        ),
      );
    }
    final hasResults = _searchLive.isNotEmpty ||
        _searchMovies.isNotEmpty ||
        _searchSeries.isNotEmpty;
    if (!hasResults) {
      return Center(
        child: Text(
          'No results for "$query"',
          style: const TextStyle(color: Colors.white54, fontSize: 15),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final channelCols = _resolveChannelColumns(width);
        final posterCols = (width / 150).floor().clamp(3, 8).toInt();
        final slivers = <Widget>[];
        void addGroup(
          String title,
          List<IptvContentItem> items, {
          required bool isLive,
          required void Function(IptvContentItem) onSelect,
        }) {
          if (items.isEmpty) return;
          slivers.add(SliverToBoxAdapter(child: _SearchGroupHeader(title: title)));
          slivers.add(SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: isLive ? channelCols : posterCols,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: isLive ? _channelTileAspect : 0.58,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final item = items[index];
                  return RepaintBoundary(
                    child: isLive
                        ? _ChannelTile(
                            key: ValueKey('search_ch_${item.id}'),
                            item: item,
                            epgOverride: _tileEpg[item.id],
                            onNeedEpg: () => _requestTileEpg(item),
                            onFocused: () {},
                            onSelect: () => onSelect(item),
                          )
                        : _PosterTile(
                            key: ValueKey('search_vod_${item.id}'),
                            item: item,
                            onSelect: () => onSelect(item),
                          ),
                  );
                },
                childCount: items.length,
              ),
            ),
          ));
        }

        addGroup('Live TV', _searchLive,
            isLive: true, onSelect: _showLiveChannelSheet);
        addGroup('Movies', _searchMovies,
            isLive: false, onSelect: _showMovieSheet);
        addGroup('Series', _searchSeries,
            isLive: false, onSelect: _showSeriesSheet);

        return CustomScrollView(
          // ignore: deprecated_member_use
          cacheExtent: 300,
          slivers: [
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            ...slivers,
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        );
      },
    );
  }

  Widget _buildGrid() {
    if (_itemsLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_itemsError != null) {
      return _InlineError(
        message: _itemsError!,
        onRetry: () =>
            unawaited(_loadContent(reset: true, forceRefresh: true)),
      );
    }
    if (_items.isEmpty) {
      return const Center(
        child: Text(
          'Nothing here yet',
          style: TextStyle(color: Colors.white54, fontSize: 15),
        ),
      );
    }
    final isLive = _section == IptvSection.live;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = isLive
            ? _resolveChannelColumns(width)
            : (width / 150).floor().clamp(3, 8).toInt();
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          // ignore: deprecated_member_use
          cacheExtent: 300,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: isLive ? _channelTileAspect : 0.58,
          ),
          itemCount: _items.length,
          itemBuilder: (context, index) {
            if (index >= _items.length - columns * 3) {
              // Prefetch: request the next page ~3 rows early so paging feels
              // seamless (guarded against duplicate fetches by _loadingMore).
              WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadMore());
            }
            final item = _items[index];
            return RepaintBoundary(
              child: isLive
                  ? _ChannelTile(
                      key: ValueKey('ch_${item.id}'),
                      item: item,
                      epgOverride: _tileEpg[item.id],
                      onNeedEpg: () => _requestTileEpg(item),
                      onFocused: () => _onChannelFocused(item),
                      onSelect: () => _onItemSelected(item),
                    )
                  : _PosterTile(
                      key: ValueKey('vod_${item.id}'),
                      item: item,
                      onFocused: () => _onVodFocused(item),
                      onSelect: () => _onItemSelected(item),
                    ),
            );
          },
        );
      },
    );
  }
}

// ─── EPG hero (top of Live section) ──────────────────────────────────────────

class _EpgHero extends StatelessWidget {
  final _HeroState? hero;
  final bool isFavorite;
  final Future<bool> Function()? onToggleFavorite;

  const _EpgHero({
    required this.hero,
    required this.isFavorite,
    required this.onToggleFavorite,
  });

  static String _fmtTime(int epochSeconds) {
    // Render in SAST (UTC+2) regardless of device timezone — Voltix DStv EPG
    // is South African and SA has no daylight saving.
    final dt = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000,
            isUtc: true)
        .add(const Duration(hours: 2));
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final state = hero;
    if (state == null) {
      return const SizedBox(
        height: 148,
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Select a channel to see the guide',
              style: TextStyle(color: Colors.white38, fontSize: 14),
            ),
          ),
        ),
      );
    }

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final epg = state.epg;
    IptvEpgEntry? current;
    final next = <IptvEpgEntry>[];
    if (epg != null) {
      for (final entry in epg) {
        if (current == null && entry.isAiringAt(now)) {
          current = entry;
        } else if (entry.startTimestamp != null && entry.startTimestamp! > now) {
          // Hero shows only the single next programme.
          if (next.isEmpty) next.add(entry);
        }
      }
    }
    current ??= state.channel.currentProgram;

    final channel = state.channel;
    // Prefer the DSTV programme thumbnail (EPG icon) when available; otherwise
    // fall back to the channel logo.
    final heroImage = (current?.icon != null && current!.icon!.isNotEmpty)
        ? current.icon!
        : (channel.poster ?? '');
    return SizedBox(
      height: 148,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Channel logo
            SizedBox(
              width: 96,
              height: 96,
              child: heroImage.isEmpty
                  ? ColoredBox(
                      color: _LiveTvPalette.panel,
                      child: Icon(Icons.live_tv_rounded,
                          color: Colors.white24, size: 40),
                    )
                  : CachedNetworkImage(
                      imageUrl: heroImage,
                      fit: BoxFit.contain,
                      memCacheWidth: 192,
                      errorWidget: (_, _, _) => const Icon(
                          Icons.live_tv_rounded,
                          color: Colors.white24,
                          size: 40),
                    ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          channel.channelNumber != null
                              ? '${channel.channelNumber}  ${_cleanChannelName(channel.title)}'
                              : _cleanChannelName(channel.title),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      if (onToggleFavorite != null)
                        _FavoriteStar(
                          key: ValueKey('fav_${channel.id}'),
                          isFavorite: isFavorite,
                          onToggle: onToggleFavorite!,
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (current != null) ...[
                    Text(
                      current.hasTimes
                          ? '${_fmtTime(current.startTimestamp!)} – ${_fmtTime(current.stopTimestamp!)}  ${current.title}'
                          : current.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (current.hasTimes)
                      _ProgressBar(progress: current.progressAt(now)),
                    const SizedBox(height: 8),
                    // Synopsis of what's on now.
                    if ((current.description).trim().isNotEmpty) ...[
                      Text(
                        current.description.trim(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12.5,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 6),
                    ],
                    if (next.isNotEmpty)
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: 'Streaming next  ',
                              style: TextStyle(
                                color: _LiveTvPalette.accent,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            TextSpan(
                              text: next
                                  .map((e) => e.hasTimes
                                      ? '${_fmtTime(e.startTimestamp!)} ${e.title}'
                                      : e.title)
                                  .join('  ·  '),
                            ),
                          ],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style:
                            const TextStyle(color: Colors.white60, fontSize: 12.5),
                      ),
                  ] else if (epg == null && !state.epgFailed)
                    const Text(
                      'Loading guide…',
                      style: TextStyle(color: Colors.white38, fontSize: 13),
                    )
                  else
                    const Text(
                      'No guide information available',
                      style: TextStyle(color: Colors.white38, fontSize: 13),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  final double progress;
  const _ProgressBar({required this.progress});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 4,
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            Container(
              width: constraints.maxWidth,
              decoration: const BoxDecoration(
                color: Color(0x33FFFFFF),
                borderRadius: BorderRadius.all(Radius.circular(2)),
              ),
            ),
            Container(
              width: constraints.maxWidth * progress.clamp(0.0, 1.0),
              decoration: BoxDecoration(
                color: _LiveTvPalette.accent,
                borderRadius: BorderRadius.all(Radius.circular(2)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Continue Watching row (top of the content area) ─────────────────────────

/// One Continue Watching card: the remembered item plus its server progress.
class _ContinueEntry {
  final IptvRecentItem item;
  final IptvProgress progress;

  const _ContinueEntry(this.item, this.progress);

  /// Server `updatedAt` when known, else the local play time — newest first.
  int get sortKey => progress.updatedAt > 0 ? progress.updatedAt : item.playedAt;
}

class _ContinueWatchingRow extends StatelessWidget {
  final List<_ContinueEntry> entries;
  final void Function(_ContinueEntry entry) onSelect;
  final void Function(_ContinueEntry entry) onRemove;

  const _ContinueWatchingRow({
    required this.entries,
    required this.onSelect,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SearchGroupHeader(title: 'Continue Watching'),
        SizedBox(
          height: 190,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            // ignore: deprecated_member_use
            cacheExtent: 300,
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              return RepaintBoundary(
                child: Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: _ContinueWatchingCard(
                    key: ValueKey('cw_${entry.item.dedupeKey}'),
                    entry: entry,
                    onSelect: () => onSelect(entry),
                    onRemove: () => onRemove(entry),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Poster + title + progress bar. Select resumes; long-press / context menu
/// (or long-press / right-click by touch and mouse) removes the entry.
class _ContinueWatchingCard extends StatefulWidget {
  final _ContinueEntry entry;
  final VoidCallback onSelect;
  final VoidCallback onRemove;

  const _ContinueWatchingCard({
    super.key,
    required this.entry,
    required this.onSelect,
    required this.onRemove,
  });

  @override
  State<_ContinueWatchingCard> createState() => _ContinueWatchingCardState();
}

class _ContinueWatchingCardState extends State<_ContinueWatchingCard> {
  final LongPressSelectKeyHandler _selectKeyHandler =
      LongPressSelectKeyHandler();
  bool _focused = false;

  @override
  void dispose() {
    _selectKeyHandler.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.entry.item;
    final poster = item.poster;
    final subtitle = item.displaySubtitle;
    return Focus(
      onKeyEvent: (node, event) => _selectKeyHandler.handleKeyEvent(
        event,
        onTap: widget.onSelect,
        onLongPress: widget.onRemove,
      ),
      onFocusChange: (f) => setState(() => _focused = f),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onSelect,
        onLongPress: widget.onRemove,
        onSecondaryTap: widget.onRemove,
        child: SizedBox(
          width: 116,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 152,
                child: Container(
                  width: double.infinity,
                  clipBehavior: Clip.hardEdge,
                  decoration: BoxDecoration(
                    color: _LiveTvPalette.panel,
                    borderRadius: const BorderRadius.all(Radius.circular(8)),
                    border: Border.all(
                      color: _focused
                          ? _LiveTvPalette.accent
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      poster == null || poster.isEmpty
                          ? const Icon(Icons.movie_rounded,
                              color: Colors.white24, size: 32)
                          : CachedNetworkImage(
                              imageUrl: poster,
                              fit: BoxFit.cover,
                              memCacheWidth: 240,
                              fadeInDuration: Duration.zero,
                              fadeOutDuration: Duration.zero,
                              errorWidget: (_, _, _) => const Icon(
                                  Icons.movie_rounded,
                                  color: Colors.white24,
                                  size: 32),
                            ),
                      if (_focused)
                        Positioned(
                          top: 4,
                          right: 4,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: _LiveTvPalette.scrim,
                              borderRadius:
                                  BorderRadius.all(Radius.circular(10)),
                            ),
                            child: Padding(
                              padding: EdgeInsets.all(2),
                              child: Icon(Icons.close_rounded,
                                  color: Colors.white70, size: 14),
                            ),
                          ),
                        ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: _ProgressBar(
                            progress: widget.entry.progress.fraction),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                item.displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _focused ? Colors.white : Colors.white70,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (subtitle != null)
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Favorite star button (self-contained state, no parent rebuilds) ─────────

class _FavoriteStar extends StatefulWidget {
  final bool isFavorite;
  final Future<bool> Function() onToggle;

  const _FavoriteStar({super.key, required this.isFavorite, required this.onToggle});

  @override
  State<_FavoriteStar> createState() => _FavoriteStarState();
}

class _FavoriteStarState extends State<_FavoriteStar> {
  late bool _fav = widget.isFavorite;
  bool _focused = false;
  bool _busy = false;

  Future<void> _toggle() async {
    if (_busy) return;
    _busy = true;
    setState(() => _fav = !_fav); // optimistic
    final result = await widget.onToggle();
    if (mounted) setState(() => _fav = result);
    _busy = false;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: (node, event) => handleOneShotSelect(event, _toggle),
      onFocusChange: (f) => setState(() => _focused = f),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggle,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            border: Border.all(
              color: _focused ? _LiveTvPalette.accent : Colors.transparent,
              width: 2,
            ),
            borderRadius: const BorderRadius.all(Radius.circular(8)),
          ),
          child: Icon(
            _fav ? Icons.star_rounded : Icons.star_border_rounded,
            color: _fav ? _LiveTvPalette.favourite : Colors.white54,
            size: 24,
          ),
        ),
      ),
    );
  }
}

// ─── Rail tile (sections + categories) ───────────────────────────────────────

class _RailTile extends StatefulWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final bool dense;
  final bool autofocus;
  /// When true the tile shrink-wraps its label instead of expanding to fill the
  /// parent width (used for horizontal chips like the season selector, where a
  /// fixed width clipped longer labels such as "Season 10").
  final bool compact;
  final VoidCallback onSelect;

  const _RailTile({
    required this.label,
    this.icon,
    required this.selected,
    this.dense = false,
    this.autofocus = false,
    this.compact = false,
    required this.onSelect,
  });

  @override
  State<_RailTile> createState() => _RailTileState();
}

class _RailTileState extends State<_RailTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final highlight = _focused
        ? _LiveTvPalette.accent
        : widget.selected
            ? _LiveTvPalette.accent.withValues(alpha: 0.2)
            : Colors.transparent;
    final textColor = _focused
        ? Colors.white
        : widget.selected
            ? _LiveTvPalette.accentSoft
            : Colors.white70;
    return Focus(
      autofocus: widget.autofocus,
      onKeyEvent: (node, event) => handleOneShotSelect(event, widget.onSelect),
      onFocusChange: (f) => setState(() => _focused = f),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onSelect,
        child: Container(
          height: widget.dense ? 42 : 46,
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: highlight,
            borderRadius: const BorderRadius.all(Radius.circular(8)),
          ),
          child: Row(
            mainAxisSize:
                widget.compact ? MainAxisSize.min : MainAxisSize.max,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon,
                    size: 18,
                    color: _focused ? Colors.white : Colors.white54),
                const SizedBox(width: 8),
              ],
              if (widget.compact)
                Text(
                  widget.label,
                  maxLines: 1,
                  style: TextStyle(
                    color: textColor,
                    fontSize: widget.dense ? 13.5 : 15,
                    fontWeight:
                        widget.selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                )
              else
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor,
                      fontSize: widget.dense ? 13.5 : 15,
                      fontWeight:
                          widget.selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Search group heading ────────────────────────────────────────────────────

class _SearchGroupHeader extends StatelessWidget {
  final String title;

  const _SearchGroupHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Text(
        title,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

// ─── Live TV settings sheet ──────────────────────────────────────────────────

/// Lets the viewer choose how many channel tiles appear per row. D-pad
/// friendly: a plain focusable list, no nested scroll traps.
class _LiveTvSettingsSheet extends StatelessWidget {
  final int selectedColumns;
  final List<int> columnChoices;
  final String Function(int) columnLabelFor;
  final void Function(int) onColumnsSelected;

  final String selectedEpgSource;
  final void Function(String) onEpgSourceSelected;

  const _LiveTvSettingsSheet({
    required this.selectedColumns,
    required this.columnChoices,
    required this.columnLabelFor,
    required this.onColumnsSelected,
    required this.selectedEpgSource,
    required this.onEpgSourceSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: _LiveTvPalette.bg,
        borderRadius: BorderRadius.all(Radius.circular(14)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text(
              'Live TV Settings',
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SettingsSectionLabel('Programme guide'),
                  _SettingsChoiceRow(
                    label: 'Provider guide (default)',
                    subtitle: "Your IPTV provider's guide with DStv programme artwork",
                    isSelected: selectedEpgSource == 'provider',
                    autofocus: selectedEpgSource == 'provider',
                    onSelect: () => onEpgSourceSelected('provider'),
                  ),
                  _SettingsChoiceRow(
                    label: 'DStv guide only',
                    subtitle: 'DStv XMLTV feed (Non-DStv channels will show no programme info)',
                    isSelected: selectedEpgSource == 'dstv',
                    autofocus: selectedEpgSource == 'dstv',
                    onSelect: () => onEpgSourceSelected('dstv'),
                  ),
                  _SettingsChoiceRow(
                    label: 'Automatic',
                    subtitle: 'DStv guide for DStv channels, provider guide for the rest',
                    isSelected: selectedEpgSource == 'auto',
                    autofocus: selectedEpgSource == 'auto',
                    onSelect: () => onEpgSourceSelected('auto'),
                  ),
                  const _SettingsSectionLabel('Channels per row'),
                  for (final choice in columnChoices)
                    _SettingsChoiceRow(
                      label: columnLabelFor(choice),
                      isSelected: choice == selectedColumns,
                      autofocus: false,
                      onSelect: () => onColumnsSelected(choice),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsSectionLabel extends StatelessWidget {
  final String text;
  const _SettingsSectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: Colors.white38,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}

class _SettingsChoiceRow extends StatefulWidget {
  final String label;
  final String? subtitle;
  final bool isSelected;
  final bool autofocus;
  final VoidCallback onSelect;

  const _SettingsChoiceRow({
    required this.label,
    this.subtitle,
    required this.isSelected,
    required this.autofocus,
    required this.onSelect,
  });

  @override
  State<_SettingsChoiceRow> createState() => _SettingsChoiceRowState();
}

class _SettingsChoiceRowState extends State<_SettingsChoiceRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: widget.autofocus,
      onKeyEvent: (node, event) => handleOneShotSelect(event, widget.onSelect),
      onFocusChange: (f) => setState(() => _focused = f),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onSelect,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          color: _focused ? _LiveTvPalette.panelFocused : Colors.transparent,
          child: Row(
            children: [
              Icon(
                widget.isSelected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 18,
                color: widget.isSelected
                    ? _LiveTvPalette.accent
                    : Colors.white38,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.label,
                      style: TextStyle(
                        color: widget.isSelected ? Colors.white : Colors.white70,
                        fontSize: 14,
                        fontWeight: widget.isSelected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                    if (widget.subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        widget.subtitle!,
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Live channel tile ────────────────────────────────────────────────────────

/// Target width per channel tile; the grid fits as many columns as this allows.
const double _channelTileTargetWidth = 168;

/// Width : height. Higher is shorter. The tile needs roughly 50 logical pixels
/// of content (name row, programme row, progress bar, padding), so at the widths
/// this grid produces there is comfortable headroom.
const double _channelTileAspect = 3.0;

class _ChannelTile extends StatefulWidget {
  final IptvContentItem item;

  /// "On now" entry fetched by the parent for channels whose content payload
  /// carried no embedded `currentProgram`. Null means either not-yet-loaded or
  /// no programme data available.
  final IptvEpgEntry? epgOverride;

  /// Asks the parent to look up this channel's current programme.
  final VoidCallback onNeedEpg;

  final VoidCallback onFocused;
  final VoidCallback onSelect;

  const _ChannelTile({
    super.key,
    required this.item,
    required this.epgOverride,
    required this.onNeedEpg,
    required this.onFocused,
    required this.onSelect,
  });

  @override
  State<_ChannelTile> createState() => _ChannelTileState();
}

class _ChannelTileState extends State<_ChannelTile> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    // Only a subset of channels arrive with an embedded currentProgram, so the
    // rest ask for theirs as they scroll into view. The parent dedupes, caches
    // and rate-limits, so calling this unconditionally is safe.
    if (widget.item.currentProgram == null && widget.epgOverride == null) {
      widget.onNeedEpg();
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    // Embedded programme wins; otherwise use whatever the parent resolved.
    final now = item.currentProgram ?? widget.epgOverride;
    final nowTitle = now?.title;
    final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // DSTV guide thumbnail for the current programme.
    final thumbUrl = now?.icon;
    return Focus(
      onKeyEvent: (node, event) => handleOneShotSelect(event, widget.onSelect),
      onFocusChange: (f) {
        setState(() => _focused = f);
        if (f) widget.onFocused();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onSelect,
        child: Container(
          decoration: BoxDecoration(
            // Subtle lift on focus instead of a heavy border — no blur/shadow,
            // so this stays cheap on entry-level TVs.
            color: _focused ? _LiveTvPalette.panelFocused : _LiveTvPalette.panel,
            borderRadius: const BorderRadius.all(Radius.circular(8)),
            border: Border.all(
              color: _focused
                  ? _LiveTvPalette.accent
                  : const Color(0x14FFFFFF),
              width: _focused ? 2 : 1,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
          child: Row(
            children: [
              // Channel logo
              SizedBox(
                width: 30,
                height: 30,
                child: item.poster == null || item.poster!.isEmpty
                    ? const Icon(Icons.live_tv_rounded,
                        color: Colors.white24, size: 18)
                    : CachedNetworkImage(
                        imageUrl: item.poster!,
                        fit: BoxFit.contain,
                        memCacheWidth: 64,
                        fadeInDuration: Duration.zero,
                        fadeOutDuration: Duration.zero,
                        errorWidget: (_, _, _) => const Icon(
                            Icons.live_tv_rounded,
                            color: Colors.white24,
                            size: 18),
                      ),
              ),
              const SizedBox(width: 6),
              // Channel line (number + name) spans the full tile width and
              // may run over the thumbnail; the programme row sits beneath it.
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (item.channelNumber != null) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: _LiveTvPalette.accent.withValues(alpha: 0.15),
                              borderRadius:
                                  BorderRadius.all(Radius.circular(3)),
                            ),
                            child: Text(
                              item.channelNumber!,
                              style: TextStyle(
                                color: _LiveTvPalette.accentSoft,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 5),
                        ],
                        Expanded(
                          child: Text(
                            _cleanChannelName(item.title),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    // What's on now + its thumbnail.
                    //
                    // The title line and the progress bar are ALWAYS rendered,
                    // even with no programme data. Previously both were
                    // conditional, so the handful of channels the provider's EPG
                    // covered looked completely different from the rest and the
                    // tiles had inconsistent heights.
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                (nowTitle != null && nowTitle.isNotEmpty)
                                    ? nowTitle
                                    : 'No programme info',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: (nowTitle != null && nowTitle.isNotEmpty)
                                      ? Colors.white60
                                      : Colors.white24,
                                  fontSize: 10,
                                ),
                              ),
                              const SizedBox(height: 3),
                              // Empty track when the programme has no times, so
                              // every tile keeps the same shape.
                              _ProgressBar(
                                progress: (now != null && now.hasTimes)
                                    ? now.progressAt(nowSeconds)
                                    : 0,
                              ),
                            ],
                          ),
                        ),
                        if (thumbUrl != null && thumbUrl.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          ClipRRect(
                            borderRadius:
                                const BorderRadius.all(Radius.circular(4)),
                            child: CachedNetworkImage(
                              imageUrl: thumbUrl,
                              width: 40,
                              height: 24,
                              fit: BoxFit.cover,
                              memCacheWidth: 88,
                              fadeInDuration: Duration.zero,
                              fadeOutDuration: Duration.zero,
                              errorWidget: (_, _, _) =>
                                  const SizedBox(width: 40, height: 24),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Poster tile (movies / series) ───────────────────────────────────────────

class _PosterTile extends StatefulWidget {
  final IptvContentItem item;
  final VoidCallback onSelect;
  final VoidCallback? onFocused;

  const _PosterTile(
      {super.key, required this.item, required this.onSelect, this.onFocused});

  @override
  State<_PosterTile> createState() => _PosterTileState();
}

class _PosterTileState extends State<_PosterTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Focus(
      onKeyEvent: (node, event) => handleOneShotSelect(event, widget.onSelect),
      onFocusChange: (f) {
        setState(() => _focused = f);
        if (f) widget.onFocused?.call();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onSelect,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                width: double.infinity,
                clipBehavior: Clip.hardEdge,
                decoration: BoxDecoration(
                  color: _LiveTvPalette.panel,
                  borderRadius: const BorderRadius.all(Radius.circular(8)),
                  border: Border.all(
                    color: _focused
                        ? _LiveTvPalette.accent
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    item.poster == null || item.poster!.isEmpty
                        ? const Icon(Icons.movie_rounded,
                            color: Colors.white24, size: 36)
                        : CachedNetworkImage(
                            imageUrl: item.poster!,
                            fit: BoxFit.cover,
                            memCacheWidth: 342,
                            fadeInDuration: Duration.zero,
                            fadeOutDuration: Duration.zero,
                            errorWidget: (_, _, _) => const Icon(
                                Icons.movie_rounded,
                                color: Colors.white24,
                                size: 36),
                          ),
                    Positioned(
                      top: 6,
                      right: 6,
                      child: _RatingBadge(rating: item.displayRating ?? '0'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _focused ? Colors.white : Colors.white70,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Rating badge (poster overlay) ───────────────────────────────────────────

class _RatingBadge extends StatelessWidget {
  final String rating;
  const _RatingBadge({required this.rating});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: _LiveTvPalette.scrim,
        borderRadius: BorderRadius.all(Radius.circular(6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, color: _LiveTvPalette.favourite, size: 12),
          const SizedBox(width: 2),
          Text(
            rating,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Movies / Series hero (top of VOD sections) ──────────────────────────────

class _VodHero extends StatelessWidget {
  final IptvContentItem? item;
  final bool isFavorite;
  final Future<bool> Function()? onToggleFavorite;
  final VoidCallback? onPlay;

  const _VodHero({
    required this.item,
    required this.isFavorite,
    required this.onToggleFavorite,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    final it = item;
    if (it == null) {
      return const SizedBox(
        height: 152,
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Select a title to see details',
              style: TextStyle(color: Colors.white38, fontSize: 14),
            ),
          ),
        ),
      );
    }
    final meta = <String>[
      if (it.year != null && it.year!.isNotEmpty) it.year!,
      if (it.genre != null && it.genre!.isNotEmpty) it.genre!,
      if (it.displayRating != null) '★ ${it.displayRating}',
    ];
    return SizedBox(
      height: 152,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 92,
              height: 128,
              child: it.poster == null || it.poster!.isEmpty
                  ? ColoredBox(
                      color: _LiveTvPalette.panel,
                      child: Icon(Icons.movie_rounded,
                          color: Colors.white24, size: 34),
                    )
                  : CachedNetworkImage(
                      imageUrl: it.poster!,
                      fit: BoxFit.cover,
                      memCacheWidth: 184,
                      errorWidget: (_, _, _) => ColoredBox(
                        color: _LiveTvPalette.panel,
                        child: Icon(Icons.movie_rounded,
                            color: Colors.white24, size: 34),
                      ),
                    ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    it.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      meta.join('  ·  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: _LiveTvPalette.accentSoft, fontSize: 12.5),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Expanded(
                    child: Text(
                      (it.description != null &&
                              it.description!.trim().isNotEmpty)
                          ? it.description!
                          : 'No synopsis available',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12.5,
                        height: 1.3,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      _SheetButton(
                        label: 'Play',
                        icon: Icons.play_arrow_rounded,
                        onSelect: onPlay ?? () {},
                      ),
                      const SizedBox(width: 12),
                      if (onToggleFavorite != null)
                        _FavoriteStar(
                          isFavorite: isFavorite,
                          onToggle: onToggleFavorite!,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Inline error with retry ─────────────────────────────────────────────────

class _InlineError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _InlineError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 32),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              message,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 13.5),
            ),
          ),
          const SizedBox(height: 12),
          _SheetButton(label: 'Retry', icon: Icons.refresh, onSelect: onRetry),
        ],
      ),
    );
  }
}

// ─── Focusable button used in sheets and error states ────────────────────────

class _SheetButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final bool autofocus;
  final VoidCallback onSelect;

  const _SheetButton({
    required this.label,
    required this.icon,
    this.autofocus = false,
    required this.onSelect,
  });

  @override
  State<_SheetButton> createState() => _SheetButtonState();
}

class _SheetButtonState extends State<_SheetButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: widget.autofocus,
      onKeyEvent: (node, event) => handleOneShotSelect(event, widget.onSelect),
      onFocusChange: (f) => setState(() => _focused = f),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onSelect,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: _focused ? _LiveTvPalette.accent : _LiveTvPalette.chip,
            borderRadius: const BorderRadius.all(Radius.circular(8)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon,
                  size: 18, color: _focused ? Colors.black : Colors.white),
              const SizedBox(width: 8),
              Text(
                widget.label,
                style: TextStyle(
                  color: _focused ? Colors.black : Colors.white,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Live channel detail bottom sheet ────────────────────────────────────────

class _LiveChannelSheet extends StatefulWidget {
  final VoltixIptvRepository repo;
  final IptvContentItem item;
  final bool isFavorite;
  final Future<bool> Function() onToggleFavorite;
  final VoidCallback onWatch;

  const _LiveChannelSheet({
    required this.repo,
    required this.item,
    required this.isFavorite,
    required this.onToggleFavorite,
    required this.onWatch,
  });

  @override
  State<_LiveChannelSheet> createState() => _LiveChannelSheetState();
}

class _LiveChannelSheetState extends State<_LiveChannelSheet> {
  List<IptvEpgEntry>? _epg; // null while loading
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _epg = null;
      _failed = false;
    });
    try {
      final epg = await widget.repo
          .getSimpleEpg(widget.item, window: const Duration(hours: 2));
      if (!mounted) return;
      setState(() => _epg = epg);
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  static String _fmtTime(int epochSeconds) {
    // Render in SAST (UTC+2) regardless of device timezone — Voltix DStv EPG
    // is South African and SA has no daylight saving.
    final dt = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000,
            isUtc: true)
        .add(const Duration(hours: 2));
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final epg = _epg;
    IptvEpgEntry? current;
    final upcoming = <IptvEpgEntry>[];
    if (epg != null) {
      for (final e in epg) {
        if (current == null && e.isAiringAt(now)) {
          current = e;
        } else if (e.startTimestamp != null && e.startTimestamp! > now) {
          upcoming.add(e);
        }
      }
    }
    current ??= item.currentProgram;
    // XMLTV thumbnail for the current programme (used in the modal header).
    final headerThumb = current?.icon;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Programme thumbnail from the XMLTV guide for what's on now
                  // (16:9), falling back to the channel logo when absent.
                  if (headerThumb != null && headerThumb.isNotEmpty)
                    ClipRRect(
                      borderRadius: const BorderRadius.all(Radius.circular(6)),
                      child: CachedNetworkImage(
                        imageUrl: headerThumb,
                        width: 150,
                        height: 84,
                        fit: BoxFit.cover,
                        memCacheWidth: 300,
                        errorWidget: (_, _, _) => SizedBox(
                          width: 150,
                          height: 84,
                          child: ColoredBox(
                            color: _LiveTvPalette.panel,
                            child: Icon(Icons.live_tv_rounded,
                                color: Colors.white24, size: 34),
                          ),
                        ),
                      ),
                    )
                  else
                    SizedBox(
                      width: 84,
                      height: 84,
                      child: item.poster == null || item.poster!.isEmpty
                          ? ColoredBox(
                              color: _LiveTvPalette.panel,
                              child: Icon(Icons.live_tv_rounded,
                                  color: Colors.white24, size: 34),
                            )
                          : CachedNetworkImage(
                              imageUrl: item.poster!,
                              fit: BoxFit.contain,
                              memCacheWidth: 168,
                              errorWidget: (_, _, _) => const Icon(
                                  Icons.live_tv_rounded,
                                  color: Colors.white24,
                                  size: 34),
                            ),
                    ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.channelNumber != null
                              ? '${item.channelNumber}  ${_cleanChannelName(item.title)}'
                              : _cleanChannelName(item.title),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (current != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            current.hasTimes
                                ? '${_fmtTime(current.startTimestamp!)} – ${_fmtTime(current.stopTimestamp!)}  ${current.title}'
                                : current.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (current.hasTimes) ...[
                            const SizedBox(height: 6),
                            _ProgressBar(progress: current.progressAt(now)),
                          ],
                          // Synopsis of the current programme.
                          if (current.description.trim().isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Text(
                              current.description.trim(),
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  _SheetButton(
                    label: 'Watch',
                    icon: Icons.play_arrow_rounded,
                    autofocus: true,
                    onSelect: widget.onWatch,
                  ),
                  const SizedBox(width: 12),
                  _FavoriteStar(
                    isFavorite: widget.isFavorite,
                    onToggle: widget.onToggleFavorite,
                  ),
                ],
              ),
              // Live countdown to the next programme.
              if (upcoming.isNotEmpty && upcoming.first.startTimestamp != null)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: _NextProgrammeCountdown(
                    startTimestamp: upcoming.first.startTimestamp!,
                    title: upcoming.first.title,
                  ),
                ),
              const SizedBox(height: 18),
              Text(
                'Next 2 hours',
                style: TextStyle(
                  color: _LiveTvPalette.accent,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Flexible(child: _buildEpgList(upcoming)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEpgList(List<IptvEpgEntry> upcoming) {
    if (_epg == null && !_failed) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ),
      );
    }
    if (upcoming.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text(
          'No upcoming guide information',
          style: TextStyle(color: Colors.white54, fontSize: 13.5),
        ),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: upcoming.length,
      itemBuilder: (context, index) {
        final e = upcoming[index];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 52,
                child: Text(
                  e.hasTimes ? _fmtTime(e.startTimestamp!) : '',
                  style: TextStyle(
                    color: _LiveTvPalette.accentSoft,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              // DSTV programme thumbnail (EPG icon) when available.
              if (e.icon != null && e.icon!.isNotEmpty) ...[
                ClipRRect(
                  borderRadius: const BorderRadius.all(Radius.circular(4)),
                  child: CachedNetworkImage(
                    imageUrl: e.icon!,
                    width: 64,
                    height: 36,
                    fit: BoxFit.cover,
                    memCacheWidth: 128,
                    fadeInDuration: Duration.zero,
                    errorWidget: (_, _, _) => const SizedBox(width: 64, height: 36),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  e.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 13.5),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─── Movie detail bottom sheet ───────────────────────────────────────────────

class _MovieDetailSheet extends StatelessWidget {
  final IptvContentItem item;
  final bool isFavorite;
  final Future<bool> Function() onToggleFavorite;
  final VoidCallback onPlay;

  const _MovieDetailSheet({
    required this.item,
    required this.isFavorite,
    required this.onToggleFavorite,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    final metaParts = <String>[
      if (item.year != null && item.year!.isNotEmpty) item.year!,
      if (item.genre != null && item.genre!.isNotEmpty) item.genre!,
      if (item.displayRating != null) '★ ${item.displayRating}',
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 110,
                  height: 165,
                  child: item.poster == null || item.poster!.isEmpty
                      ? ColoredBox(
                          color: _LiveTvPalette.panel,
                          child: Icon(Icons.movie_rounded,
                              color: Colors.white24, size: 36),
                        )
                      : CachedNetworkImage(
                          imageUrl: item.poster!,
                          fit: BoxFit.cover,
                          memCacheWidth: 220,
                          errorWidget: (_, _, _) => ColoredBox(
                            color: _LiveTvPalette.panel,
                            child: Icon(Icons.movie_rounded,
                                color: Colors.white24, size: 36),
                          ),
                        ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (metaParts.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          metaParts.join('  ·  '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: _LiveTvPalette.accentSoft, fontSize: 13),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Text(
                        (item.description != null &&
                                item.description!.trim().isNotEmpty)
                            ? item.description!
                            : 'No synopsis available',
                        maxLines: 6,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13.5,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                _SheetButton(
                  label: 'Play',
                  icon: Icons.play_arrow_rounded,
                  autofocus: true,
                  onSelect: onPlay,
                ),
                const SizedBox(width: 12),
                _FavoriteStar(isFavorite: isFavorite, onToggle: onToggleFavorite),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Series detail bottom sheet ──────────────────────────────────────────────

class _SeriesDetailSheet extends StatefulWidget {
  final VoltixIptvRepository repo;
  final IptvContentItem item;
  final bool isFavorite;
  final bool isAdmin;
  final Future<bool> Function() onToggleFavorite;
  final void Function(IptvEpisode episode) onPlayEpisode;

  const _SeriesDetailSheet({
    required this.repo,
    required this.item,
    required this.isFavorite,
    this.isAdmin = false,
    required this.onToggleFavorite,
    required this.onPlayEpisode,
  });

  @override
  State<_SeriesDetailSheet> createState() => _SeriesDetailSheetState();
}

class _SeriesDetailSheetState extends State<_SeriesDetailSheet> {
  IptvSeriesInfo? _info;
  String? _error;
  int? _selectedSeason;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _info = null;
      _error = null;
    });
    try {
      final seriesId = widget.item.seriesId?.toString() ?? widget.item.id;
      final info = await widget.repo
          .getSeriesInfo(seriesId, seriesName: widget.item.title);
      if (!mounted) return;
      setState(() {
        _info = info;
        _selectedSeason =
            info.seasonNumbers.isNotEmpty ? info.seasonNumbers.first : null;
      });
    } on VoltixIptvException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: _error != null
              ? SizedBox(
                  height: 200,
                  child: _InlineError(message: _error!, onRetry: _load),
                )
              : _info == null
                  ? const SizedBox(
                      height: 200,
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : _buildLoaded(_info!),
        ),
      ),
    );
  }

  void _showDownloadDialog(IptvSeriesInfo info) {
    final seriesId = widget.item.seriesId?.toString() ?? widget.item.id;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SeriesDownloadDialog(
        repo: widget.repo,
        seriesId: seriesId,
        seriesName: info.name.isNotEmpty ? info.name : widget.item.title,
      ),
    );
  }

  /// "Season 1 (15)" — episode count appended when known.
  String _seasonLabel(IptvSeriesInfo info, int season) {
    final count = info.episodesBySeason[season]?.length ?? 0;
    return count > 0 ? 'Season $season ($count)' : 'Season $season';
  }

  Widget _buildLoaded(IptvSeriesInfo info) {
    final metaParts = <String>[
      if (info.releaseDate != null && info.releaseDate!.isNotEmpty)
        info.releaseDate!.length >= 4 ? info.releaseDate!.substring(0, 4) : info.releaseDate!,
      if (info.genre != null && info.genre!.isNotEmpty) info.genre!,
      if (info.rating != null && info.rating!.isNotEmpty) '★ ${info.rating}',
    ];
    final poster = info.cover ?? widget.item.poster;
    final episodes = _selectedSeason != null
        ? (info.episodesBySeason[_selectedSeason] ?? const <IptvEpisode>[])
        : const <IptvEpisode>[];

    // Cast and director, parsed from get_series_info but previously unused.
    final credits = <String>[
      if (info.director != null && info.director!.trim().isNotEmpty)
        'Director: ${info.director!.trim()}',
      if (info.cast != null && info.cast!.trim().isNotEmpty)
        'Cast: ${info.cast!.trim()}',
    ];

    // backdropPath is an array; empties are already filtered out when parsed.
    final backdrop =
        info.backdropPath.isNotEmpty ? info.backdropPath.first : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (backdrop != null)
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            child: SizedBox(
              height: 108,
              width: double.infinity,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CachedNetworkImage(
                    imageUrl: backdrop,
                    fit: BoxFit.cover,
                    memCacheWidth: 640,
                    fadeInDuration: Duration.zero,
                    fadeOutDuration: Duration.zero,
                    errorWidget: (_, _, _) => const SizedBox.shrink(),
                  ),
                  // Scrim so the poster and title below stay legible against
                  // whatever the artwork happens to be.
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x33000000), _LiveTvPalette.bg.withValues(alpha: 0.9)],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 92,
              height: 138,
              child: poster == null || poster.isEmpty
                  ? ColoredBox(
                      color: _LiveTvPalette.panel,
                      child: Icon(Icons.video_library_rounded,
                          color: Colors.white24, size: 32),
                    )
                  : CachedNetworkImage(
                      imageUrl: poster,
                      fit: BoxFit.cover,
                      memCacheWidth: 184,
                      errorWidget: (_, _, _) => ColoredBox(
                        color: _LiveTvPalette.panel,
                        child: Icon(Icons.video_library_rounded,
                            color: Colors.white24, size: 32),
                      ),
                    ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          info.name.isNotEmpty ? info.name : widget.item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      _FavoriteStar(
                        isFavorite: widget.isFavorite,
                        onToggle: widget.onToggleFavorite,
                      ),
                    ],
                  ),
                  if (metaParts.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      metaParts.join('  ·  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: _LiveTvPalette.accentSoft, fontSize: 12.5),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    (info.plot != null && info.plot!.trim().isNotEmpty)
                        ? info.plot!
                        : 'No synopsis available',
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      height: 1.3,
                    ),
                  ),
                  for (final credit in credits) ...[
                    const SizedBox(height: 4),
                    Text(
                      credit,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        if (widget.isAdmin) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: _SheetButton(
              label: 'Download Series',
              icon: Icons.download_rounded,
              onSelect: () => _showDownloadDialog(info),
            ),
          ),
        ],
        const SizedBox(height: 14),
        if (info.seasonNumbers.length > 1)
          SizedBox(
            height: 46,
            // Chips size to their own label (no fixed extent), so "Season 10"
            // and episode counts are never clipped.
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final season in info.seasonNumbers)
                    _RailTile(
                      label: _seasonLabel(info, season),
                      selected: _selectedSeason == season,
                      dense: true,
                      compact: true,
                      onSelect: () => setState(() => _selectedSeason = season),
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        Flexible(
          child: episodes.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'No episodes found',
                    style: TextStyle(color: Colors.white54, fontSize: 13.5),
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: episodes.length,
                  // Fixed extent keeps scrolling cheap on entry-level TVs; the
                  // row below is laid out to exactly this height.
                  itemExtent: 88,
                  // ignore: deprecated_member_use
                  cacheExtent: 300,
                  itemBuilder: (context, index) {
                    final episode = episodes[index];
                    return _EpisodeRow(
                      episode: episode,
                      autofocus: index == 0,
                      onSelect: () => widget.onPlayEpisode(episode),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// ─── Episode row ─────────────────────────────────────────────────────────────

/// One episode in the series detail sheet: still image, S/E + title, air date
/// and duration, and the episode's own synopsis.
///
/// All of this already arrives from `get_series_info` and is parsed into
/// [IptvEpisode] - it was simply never displayed, so every episode looked
/// identical apart from its title.
class _EpisodeRow extends StatefulWidget {
  final IptvEpisode episode;
  final bool autofocus;
  final VoidCallback onSelect;

  const _EpisodeRow({
    required this.episode,
    required this.autofocus,
    required this.onSelect,
  });

  @override
  State<_EpisodeRow> createState() => _EpisodeRowState();
}

class _EpisodeRowState extends State<_EpisodeRow> {
  bool _focused = false;

  /// "S1 E4" when numbered, otherwise empty.
  String get _code {
    final s = widget.episode.seasonNumber;
    final e = widget.episode.episodeNumber;
    if (s == null && e == null) return '';
    if (s == null) return 'E$e';
    if (e == null) return 'S$s';
    return 'S$s E$e';
  }

  /// Air date and rating, whichever are present.
  ///
  /// No runtime here: IptvEpisode carries no duration field, only what
  /// /api/iptv/series-info maps (id, title, numbering, containerExtension,
  /// poster, plot, rating, airDate).
  String get _meta {
    final parts = <String>[];
    final air = widget.episode.airDate;
    if (air != null && air.trim().isNotEmpty) parts.add(air.trim());
    final rating = widget.episode.rating;
    if (rating != null && rating > 0) parts.add('★ ${rating.toStringAsFixed(1)}');
    return parts.join('  ·  ');
  }

  @override
  Widget build(BuildContext context) {
    final episode = widget.episode;
    final still = episode.poster;
    final plot = episode.plot;
    final code = _code;
    final meta = _meta;

    return Focus(
      autofocus: widget.autofocus,
      onKeyEvent: (node, event) => handleOneShotSelect(event, widget.onSelect),
      onFocusChange: (f) => setState(() => _focused = f),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onSelect,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: _focused ? _LiveTvPalette.panelFocused : Colors.transparent,
            borderRadius: const BorderRadius.all(Radius.circular(8)),
            border: Border.all(
              color: _focused ? _LiveTvPalette.accent : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Episode still. Falls back to a play glyph so rows stay aligned
              // when the provider supplies no image.
              ClipRRect(
                borderRadius: const BorderRadius.all(Radius.circular(5)),
                child: SizedBox(
                  width: 106,
                  height: 60,
                  child: (still == null || still.isEmpty)
                      ? Container(
                          color: _LiveTvPalette.panel,
                          child: const Icon(Icons.play_arrow_rounded,
                              color: Colors.white24, size: 22),
                        )
                      : CachedNetworkImage(
                          imageUrl: still,
                          fit: BoxFit.cover,
                          memCacheWidth: 220,
                          fadeInDuration: Duration.zero,
                          fadeOutDuration: Duration.zero,
                          errorWidget: (_, _, _) => Container(
                            color: _LiveTvPalette.panel,
                            child: const Icon(Icons.play_arrow_rounded,
                                color: Colors.white24, size: 22),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        if (code.isNotEmpty) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: _LiveTvPalette.accent.withValues(alpha: 0.15),
                              borderRadius:
                                  BorderRadius.all(Radius.circular(3)),
                            ),
                            child: Text(
                              code,
                              style: TextStyle(
                                color: _LiveTvPalette.accentSoft,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(
                            episode.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (meta.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 10.5),
                      ),
                    ],
                    if (plot != null && plot.trim().isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        plot.trim(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Admin series download dialog (request → poll → 24h link) ────────────────

class _SeriesDownloadDialog extends StatefulWidget {
  final VoltixIptvRepository repo;
  final String seriesId;
  final String seriesName;

  const _SeriesDownloadDialog({
    required this.repo,
    required this.seriesId,
    required this.seriesName,
  });

  @override
  State<_SeriesDownloadDialog> createState() => _SeriesDownloadDialogState();
}

class _SeriesDownloadDialogState extends State<_SeriesDownloadDialog> {
  String? _jobId;
  IptvDownloadStatus? _status;
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _status = null;
      _jobId = null;
    });
    try {
      final jobId = await widget.repo.requestSeriesDownload(
        widget.seriesId,
        seriesName: widget.seriesName,
      );
      if (!mounted) return;
      setState(() => _jobId = jobId);
      _poll = Timer.periodic(const Duration(seconds: 3), (_) => _tick());
      _tick();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error =
          e is VoltixIptvException ? e.message : 'Download request failed');
    }
  }

  Future<void> _tick() async {
    final jobId = _jobId;
    if (jobId == null) return;
    try {
      final s = await widget.repo.getDownloadStatus(jobId);
      if (!mounted) return;
      setState(() => _status = s);
      if (s.isReady || s.isFailed) _poll?.cancel();
    } catch (_) {
      // Transient poll error — keep trying until ready/failed.
    }
  }

  static String _fmtExpiry(int epochSeconds) {
    final dt =
        DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000).toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    Widget content;
    if (_error != null) {
      content = Text(_error!,
          style: const TextStyle(color: Colors.white70, fontSize: 13.5));
    } else if (s != null && s.isReady) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Ready. This link is valid for 24 hours, then the file is purged '
            'from the server.',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 10),
          SelectableText(
            s.downloadUrl!,
            style: TextStyle(color: _LiveTvPalette.accentSoft, fontSize: 13),
          ),
          if (s.expiresAt != null) ...[
            const SizedBox(height: 8),
            Text('Expires: ${_fmtExpiry(s.expiresAt!)}',
                style: const TextStyle(color: Colors.white38, fontSize: 12)),
          ],
        ],
      );
    } else if (s != null && s.isFailed) {
      content = Text(s.error ?? 'Download failed',
          style: const TextStyle(color: Colors.white70, fontSize: 13.5));
    } else {
      final pct = s != null ? (s.progress.clamp(0.0, 1.0) * 100).round() : null;
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            pct != null ? 'Preparing download… $pct%' : 'Requesting download…',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: s != null && s.progress > 0 ? s.progress.clamp(0.0, 1.0) : null,
          ),
        ],
      );
    }
    return AlertDialog(
      backgroundColor: _LiveTvPalette.bg,
      title: Text(
        'Download • ${widget.seriesName}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontSize: 16),
      ),
      content: content,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

// ─── Countdown to the next programme ─────────────────────────────────────────

/// Ticks once a second showing how long until the next programme starts, e.g.
/// "Starts in 12:34 · MasterChef Australia". Self-contained so only this widget
/// rebuilds (keeps the modal cheap on entry-level TVs).
class _NextProgrammeCountdown extends StatefulWidget {
  final int startTimestamp; // epoch seconds
  final String title;

  const _NextProgrammeCountdown({
    required this.startTimestamp,
    required this.title,
  });

  @override
  State<_NextProgrammeCountdown> createState() =>
      _NextProgrammeCountdownState();
}

class _NextProgrammeCountdownState extends State<_NextProgrammeCountdown> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  static String _fmtRemaining(int seconds) {
    if (seconds <= 0) return 'Starting now';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return h > 0
        ? 'Starts in $h:${two(m)}:${two(s)}'
        : 'Starts in ${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final remaining = widget.startTimestamp - now;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0x1A1E90FF),
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        border: Border.all(color: _LiveTvPalette.accent.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(Icons.schedule_rounded,
              size: 16, color: _LiveTvPalette.accentSoft),
          const SizedBox(width: 8),
          Text(
            _fmtRemaining(remaining),
            style: TextStyle(
              color: _LiveTvPalette.accentSoft,
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
