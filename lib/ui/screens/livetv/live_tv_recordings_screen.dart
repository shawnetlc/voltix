import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:voltix_design/voltix_design.dart';
import 'package:playback_core/playback_core.dart';

import '../../../data/models/aggregated_item.dart';
import '../../../data/models/iptv_models.dart';
import '../../../data/repositories/voltix_iptv_repository.dart';
import '../../../util/focus/key_event_utils.dart';
import '../../../util/user_facing_error.dart';
import '../../navigation/destinations.dart';
import '../../widgets/focus/request_initial_focus.dart';
import '../playback/playback_takeover.dart';

/// Catch-up TV — replays recent programmes on archive-enabled live channels.
///
/// Reached from the "Recordings" entry on the Jellyfin/Emby "LT" menu
/// ([LiveTvScreen]). That menu is for the server's own native Live TV
/// feature, which is separate from Voltix's IPTV integration — but on a
/// Voltix IPTV setup there's usually nothing recorded there, while the IPTV
/// provider's own catch-up ("archive") channels are the thing people
/// actually want to open from "Recordings". This screen serves that content:
/// category -> channel -> individual catch-up programmes, most recent first.
class LiveTvRecordingsScreen extends StatefulWidget {
  const LiveTvRecordingsScreen({super.key});

  @override
  State<LiveTvRecordingsScreen> createState() =>
      _LiveTvRecordingsScreenState();
}

class _LiveTvRecordingsScreenState extends State<LiveTvRecordingsScreen> {
  final _repo = VoltixIptvRepository();

  List<IptvCategory>? _categories;
  String _selectedCategoryId = 'all';
  bool _loadingCategories = true;
  String? _categoriesError;

  // Channels (with archive) for the selected category.
  List<IptvContentItem>? _archiveChannels;
  bool _loadingChannels = false;
  String? _channelsError;
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    setState(() {
      _loadingCategories = true;
      _categoriesError = null;
    });
    try {
      final cats = await _repo.getLiveCategories();
      if (!mounted) return;
      setState(() {
        _categories = cats;
        // Open on movies, per the chip order in _orderedCategories. Falls
        // back to "All" for an account whose provider has no movies folder.
        final movies = _orderedCategories(cats).firstWhereOrNull(
          (c) => !c.isAll && _categoryRank(c.name) == 0,
        );
        if (movies != null) _selectedCategoryId = movies.id;
        _loadingCategories = false;
      });
      unawaited(_loadArchiveChannels());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _categoriesError = userFacingError(e);
        _loadingCategories = false;
      });
    }
  }

  Future<void> _loadArchiveChannels() async {
    final token = ++_loadToken;
    setState(() {
      _loadingChannels = true;
      _channelsError = null;
      _archiveChannels = null;
    });
    try {
      // One request to the same endpoint the website's Catch Up section uses,
      // so the two agree on which channels have catch-up. See
      // VoltixIptvRepository.getCatchupChannels for why the client no longer
      // works this out for itself.
      final channels = await _repo.getCatchupChannels();
      if (!mounted || token != _loadToken) return;
      setState(() {
        _archiveChannels = _sortForDisplay(channels);
        _loadingChannels = false;
      });
    } catch (e) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _channelsError = userFacingError(e);
        _loadingChannels = false;
      });
    }
  }

  // ── Category ordering ──────────────────────────────────────────────────────
  //
  // Catch Up opens on movies. Sports comes second: it is the other category
  // people reach for a replay of, and both should be in front of the general
  // entertainment folders rather than wherever the provider's own ordering
  // happens to put them.
  //
  // Matched on the category name rather than an id because the provider's
  // category ids are not stable between accounts, and the names vary in
  // punctuation and case ("DSTV - Movies", "DStv Movies", "DSTV TV [MOVIES]").

  /// 0 for movies, 1 for sport, 2 for everything else. Lower sorts first.
  static int _categoryRank(String name) {
    final n = name.toLowerCase();
    if (n.contains('movie')) return 0;
    if (n.contains('sport')) return 1;
    return 2;
  }

  /// The category chips in display order: movies, then sport, then the rest
  /// alphabetically, with "All" kept at the end so the two named categories
  /// are the first things focus lands on.
  List<IptvCategory> _orderedCategories(List<IptvCategory> cats) {
    final all = cats.where((c) => c.isAll).toList();
    final rest = cats.where((c) => !c.isAll && !c.isFavorites).toList()
      ..sort((a, b) {
        final byRank = _categoryRank(a.name).compareTo(_categoryRank(b.name));
        return byRank != 0 ? byRank : a.name.compareTo(b.name);
      });
    return [...rest, ...all];
  }

  /// Channels sorted so the "All" view leads with movies and then sport,
  /// matching the chip order, and is alphabetical within each category.
  List<IptvContentItem> _sortForDisplay(List<IptvContentItem> channels) {
    final nameById = {
      for (final c in _categories ?? const <IptvCategory>[]) c.id: c.name,
    };
    final sorted = channels.toList()
      ..sort((a, b) {
        final rankA = _categoryRank(nameById[a.categoryId] ?? '');
        final rankB = _categoryRank(nameById[b.categoryId] ?? '');
        if (rankA != rankB) return rankA.compareTo(rankB);
        return _cleanChannelName(a.title)
            .toLowerCase()
            .compareTo(_cleanChannelName(b.title).toLowerCase());
      });
    return sorted;
  }

  void _selectCategory(String categoryId) {
    if (categoryId == _selectedCategoryId) return;
    setState(() => _selectedCategoryId = categoryId);
  }

  Future<void> _playCatchup(IptvContentItem channel, IptvEpgEntry program) async {
    try {
      await _repo.ensureTokenFresh();
    } catch (_) {
      // Proceed anyway — the backend may still accept the current token.
    }
    String? url;
    try {
      url = await _repo.fetchCatchupStreamUrl(channel, program);
    } catch (e) {
      url = null;
    }
    if (!mounted) return;
    if (url == null || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This programme is not available to replay'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }
    // Hand the decoder the memory this screen is sitting on before asking it
    // to start. Catch Up holds more decoded artwork than anywhere else in the
    // app -- a row of programme cards for every archive channel -- and those
    // bitmaps are live, so no cache limit will drop them on its own. The
    // video decoder's buffers are a large native allocation made right here,
    // and on a low-RAM TV box losing that race is not an exception the app can
    // catch: the OS kills the process, which is what "it crashes when the
    // stream loads" looks like from the outside.
    //
    // releaseImageMemoryForPlayback exists for exactly this and was written
    // against two such reports (a 2 GB onn box, a 3 GB Shield) but had never
    // been called from anywhere. Nothing artwork-backed is visible behind a
    // full-screen player, so the only cost is re-decoding this screen when the
    // viewer comes back to it.
    releaseImageMemoryForPlayback();

    final manager = GetIt.instance<PlaybackManager>();
    final itemId = 'catchup_${channel.id}_${program.startTimestamp ?? 0}';
    final playbackItem = AggregatedItem(
      id: itemId,
      serverId: 'iptv',
      rawData: {
        'Id': itemId,
        'url': url,
        'Name': '${_cleanChannelName(channel.title)} • ${program.title}',
        'isLive': false,
        'Type': 'Video',
        'container': 'ts',
        'mediaType': 'video',
      },
    );
    try {
      await manager.playItems([playbackItem]);
      if (mounted) await context.push(Destinations.videoPlayer);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Catch-up playback failed: $e'),
          backgroundColor: Colors.redAccent,
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  String _cleanChannelName(String raw) =>
      raw.replaceAll(RegExp(r'\s*\[.*?\]\s*'), '').trim();

  @override
  Widget build(BuildContext context) =>
      RequestInitialFocus(child: _buildContent(context));

  Widget _buildContent(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              const Color(0xFF07111F),
              const Color(0xFF0F2238),
              AppColorScheme.accent.withValues(alpha: 0.18),
            ],
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1400),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(40, 22, 40, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildHeader(context),
                        const SizedBox(height: 16),
                        _buildCategoryBar(context),
                        const SizedBox(height: 14),
                        Expanded(child: _buildBody(context)),
                      ],
                    ),
                  ),
                ),
              ),
              // Brand mark in the corner, matching the small static bolt
              // logo used elsewhere in the app (e.g. the Voltix Live TV
              // rail header).
              Positioned(
                top: 18,
                right: 40,
                child: Image.asset(
                  'assets/images/voltix_bolt.png',
                  width: 56,
                  height: 56,
                  fit: BoxFit.contain,
                  cacheWidth: 112,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final loaded = _archiveChannels;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Voltix Catch Up',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.2,
              ),
        ),
        const SizedBox(height: 2),
        Text(
          'Replay recent programmes from your archive-enabled channels',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.62),
              ),
        ),
        if (loaded != null) ...[
          const SizedBox(height: 8),
          Text(
            '${loaded.length} ${loaded.length == 1 ? 'channel' : 'channels'}'
            '  ·  last 24 hours',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.38),
              fontSize: 11.5,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildCategoryBar(BuildContext context) {
    if (_loadingCategories) {
      return const SizedBox(
        height: 38,
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      );
    }
    if (_categoriesError != null) {
      return _InlineError(
        message: 'Could not load categories: $_categoriesError',
        onRetry: _loadCategories,
      );
    }
    final cats = _orderedCategories(_categories ?? const <IptvCategory>[]);
    final allChannels = _archiveChannels;
    // Counts (and hiding categories with none) match the reference catch-up
    // layout: "DSTV TV [MOVIES] (16)" etc, "All" showing the grand total.
    // Left blank until channels finish loading rather than flashing 0s.
    final counts = <String, int>{};
    if (allChannels != null) {
      for (final c in allChannels) {
        counts[c.categoryId] = (counts[c.categoryId] ?? 0) + 1;
      }
    }
    final total = allChannels?.length ?? 0;
    final visibleCats = allChannels == null
        ? cats
        : cats.where((c) => c.isAll || (counts[c.id] ?? 0) > 0).toList();
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: visibleCats.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final cat = visibleCats[index];
          final baseName = cat.name.isNotEmpty
              ? cat.name
              : (cat.isAll ? 'All Channels' : cat.id);
          final label = allChannels == null
              ? baseName
              : '$baseName (${cat.isAll ? total : (counts[cat.id] ?? 0)})';
          return _CategoryChip(
            label: label,
            selected: cat.id == _selectedCategoryId,
            autofocus: index == 0,
            onTap: () => _selectCategory(cat.id),
          );
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loadingCategories) return const SizedBox.shrink();
    if (_loadingChannels) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_channelsError != null) {
      return _InlineError(
        message: 'Could not load channels: $_channelsError',
        onRetry: _loadArchiveChannels,
      );
    }
    final allChannels = _archiveChannels ?? const <IptvContentItem>[];
    final channels = _selectedCategoryId == 'all'
        ? allChannels
        : allChannels
            .where((c) => c.categoryId == _selectedCategoryId)
            .toList();
    if (channels.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.tv_off,
                color: Colors.white.withValues(alpha: 0.4), size: 40),
            const SizedBox(height: 12),
            Text(
              'No catch-up channels in this category',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      // Every channel section fetches its own guide and mounts a row of
      // artwork the moment it is built, so how far ahead this list builds is
      // directly how much memory the screen holds.
      //
      // The default cache extent (250px) is left alone deliberately. An
      // earlier version of this set 400, which was meant to reduce the extent
      // and in fact raised it above the default -- more off-screen sections
      // built, not fewer. Keeping the default is the smaller number.
      //
      // addAutomaticKeepAlives is what actually matters here: without it a
      // section that scrolls out of view stays alive, holding its guide and
      // its row of decoded artwork for as long as the screen is open.
      addAutomaticKeepAlives: false,
      itemCount: channels.length,
      separatorBuilder: (_, __) => const SizedBox(height: 14),
      itemBuilder: (context, index) => _ChannelCatchupSection(
        channel: channels[index],
        repo: _repo,
        onPlay: _playCatchup,
        cleanName: _cleanChannelName,
      ),
    );
  }
}

class _CategoryChip extends StatefulWidget {
  final String label;
  final bool selected;
  final bool autofocus;
  final VoidCallback onTap;

  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.autofocus,
    required this.onTap,
  });

  @override
  State<_CategoryChip> createState() => _CategoryChipState();
}

class _CategoryChipState extends State<_CategoryChip> {
  bool _focused = false;

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    return handleOneShotSelect(event, widget.onTap);
  }

  @override
  Widget build(BuildContext context) {
    final highlight = widget.selected || _focused;
    return Focus(
      autofocus: widget.autofocus,
      onKeyEvent: _onKeyEvent,
      onFocusChange: (f) {
        if (_focused != f) setState(() => _focused = f);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: widget.selected
                ? AppColorScheme.accent
                : const Color(0xCC101822),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _focused
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.12),
              width: _focused ? 2 : 1,
            ),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              color: widget.selected
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.72),
              fontSize: 12.5,
              fontWeight: highlight ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// Physical-pixel width to decode an image at, for a box [logicalWidth] wide.
///
/// Without this every picture on this screen is decoded at whatever size the
/// feed happens to ship -- DStv programme artwork is typically 1280x720 or
/// larger, which is 3.7 MB of ARGB_8888 bitmap for a card 188 logical pixels
/// across that needs about 0.3 MB. Roughly a 12x overspend, per thumbnail.
///
/// That is not absorbed by the image cache limits set in main.dart. Those cap
/// *cached* images; a bitmap referenced by a mounted widget is a "live" image,
/// exempt from the byte cap and not evictable. Catch Up mounts a great many at
/// once (a row of programme cards for every archive channel), so the live set
/// alone can run to hundreds of megabytes -- and the moment that matters is
/// pressing play, when the video decoder asks the OS for its own large native
/// buffers and there is nothing left to give. The app does not throw, it is
/// killed.
///
/// Capped at 2x rather than the true ratio because past that the extra detail
/// is invisible at this size and only costs memory.
int _decodeWidth(BuildContext context, double logicalWidth) {
  final ratio = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 2.0);
  return (logicalWidth * ratio).round();
}

class _ChannelCatchupSection extends StatefulWidget {
  final IptvContentItem channel;
  final VoltixIptvRepository repo;
  final void Function(IptvContentItem channel, IptvEpgEntry program) onPlay;
  final String Function(String raw) cleanName;

  const _ChannelCatchupSection({
    required this.channel,
    required this.repo,
    required this.onPlay,
    required this.cleanName,
  });

  @override
  State<_ChannelCatchupSection> createState() =>
      _ChannelCatchupSectionState();
}

class _ChannelCatchupSectionState extends State<_ChannelCatchupSection> {
  List<IptvEpgEntry>? _programs;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final programs = await widget.repo.getCatchupEpg(widget.channel);
      if (mounted) setState(() => _programs = programs);
    } catch (e) {
      if (mounted) setState(() => _error = userFacingError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0x66101822),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildChannelHeader(context),
          const SizedBox(height: 10),
          _buildPrograms(context),
        ],
      ),
    );
  }

  Widget _buildChannelHeader(BuildContext context) {
    final poster = (widget.channel.poster != null && widget.channel.poster!.isNotEmpty)
        ? widget.channel.poster
        : VoltixIptvRepository.getCachedThumbnail(widget.channel.title);

    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 24,
            height: 24,
            color: Colors.white.withValues(alpha: 0.06),
            child: poster != null && poster.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: poster,
                    fit: BoxFit.contain,
                    memCacheWidth: _decodeWidth(context, 24),
                    maxWidthDiskCache: 96,
                    errorWidget: (_, __, ___) =>
                        const Icon(Icons.live_tv, color: Colors.white54, size: 14),
                  )
                : const Icon(Icons.live_tv, color: Colors.white54, size: 14),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            widget.cleanName(widget.channel.title),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: AppColorScheme.accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            'ARCHIVE',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 8.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPrograms(BuildContext context) {
    if (_error != null) {
      return Text(
        'Could not load catch-up programmes for this channel',
        style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
      );
    }
    final programs = _programs;
    if (programs == null) {
      return const SizedBox(
        height: 132,
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          ),
        ),
      );
    }
    if (programs.isEmpty) {
      return Text(
        'No recent catch-up programmes available',
        style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
      );
    }
    final fallback = (widget.channel.poster != null && widget.channel.poster!.isNotEmpty)
        ? widget.channel.poster
        : VoltixIptvRepository.getCachedThumbnail(widget.channel.title);

    return SizedBox(
      height: 132,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: programs.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) => _CatchupItemCard(
          program: programs[index],
          fallbackImage: fallback,
          onTap: () => widget.onPlay(widget.channel, programs[index]),
        ),
      ),
    );
  }
}

/// Card width, named because [_decodeWidth] is derived from it: change one
/// and the decode size follows, instead of quietly staying wrong.
const double _cardWidth = 188;

class _CatchupItemCard extends StatefulWidget {
  final IptvEpgEntry program;
  final String? fallbackImage;
  final VoidCallback onTap;

  const _CatchupItemCard({
    required this.program,
    required this.fallbackImage,
    required this.onTap,
  });

  @override
  State<_CatchupItemCard> createState() => _CatchupItemCardState();
}

class _CatchupItemCardState extends State<_CatchupItemCard> {
  bool _focused = false;

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    return handleOneShotSelect(event, widget.onTap);
  }

  String _timeLabel() {
    final start = widget.program.startTimestamp;
    final stop = widget.program.stopTimestamp;
    if (start == null) return '';
    final startTime =
        DateTime.fromMillisecondsSinceEpoch(start * 1000).toLocal();
    final now = DateTime.now();
    final isToday = startTime.year == now.year &&
        startTime.month == now.month &&
        startTime.day == now.day;
    final yesterday = now.subtract(const Duration(days: 1));
    final isYesterday = startTime.year == yesterday.year &&
        startTime.month == yesterday.month &&
        startTime.day == yesterday.day;
    final hm =
        '${startTime.hour.toString().padLeft(2, '0')}:${startTime.minute.toString().padLeft(2, '0')}';
    String dayLabel;
    if (isToday) {
      dayLabel = 'Today';
    } else if (isYesterday) {
      dayLabel = 'Yesterday';
    } else {
      const weekdays = [
        'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun', //
      ];
      dayLabel = '${weekdays[startTime.weekday - 1]} ${startTime.day}';
    }
    if (stop == null) return '$dayLabel, $hm';
    final durationMin =
        ((stop - start) / 60).round().clamp(0, 24 * 60);
    return '$dayLabel, $hm • ${durationMin}m';
  }

  @override
  Widget build(BuildContext context) {
    final image = (widget.program.icon != null &&
            widget.program.icon!.isNotEmpty)
        ? widget.program.icon
        : widget.fallbackImage;
    return Focus(
      onKeyEvent: _onKeyEvent,
      onFocusChange: (f) {
        if (_focused != f) setState(() => _focused = f);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: _cardWidth,
          decoration: BoxDecoration(
            color: const Color(0xCC0C1420),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _focused
                  ? AppColorScheme.accent
                  : Colors.white.withValues(alpha: 0.08),
              width: _focused ? 2 : 1,
            ),
            boxShadow: _focused
                ? [
                    BoxShadow(
                      color: AppColorScheme.accent.withValues(alpha: 0.3),
                      blurRadius: 18,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(10)),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(color: Colors.white.withValues(alpha: 0.05)),
                      if (image != null && image.isNotEmpty)
                        CachedNetworkImage(
                          imageUrl: image,
                          fit: BoxFit.cover,
                          memCacheWidth: _decodeWidth(context, _cardWidth),
                          maxWidthDiskCache: 640,
                          errorWidget: (_, __, ___) => const Icon(
                              Icons.live_tv,
                              color: Colors.white24,
                              size: 28),
                        )
                      else
                        const Center(
                          child: Icon(Icons.live_tv,
                              color: Colors.white24, size: 28),
                        ),
                      Positioned(
                        right: 6,
                        bottom: 6,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.play_arrow,
                              color: Colors.white, size: 16),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(9, 6, 9, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.program.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _timeLabel(),
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 10.5,
                      ),
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

class _InlineError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _InlineError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.error_outline,
            color: Colors.redAccent.withValues(alpha: 0.8), size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(message,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.7))),
        ),
        TextButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    );
  }
}
