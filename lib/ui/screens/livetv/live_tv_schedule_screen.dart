import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:voltix_design/voltix_design.dart';
import 'package:server_core/server_core.dart';

import '../../../data/viewmodels/recordings_view_model.dart';
import '../../../data/viewmodels/schedule_view_model.dart';
import '../../../l10n/app_localizations.dart';
import '../../../preference/user_preferences.dart';
import '../../../ui/mixins/focus_state_mixin.dart';
import '../../../util/focus/key_event_utils.dart';
import '../../navigation/destinations.dart';
import '../../../util/platform_detection.dart';
import 'epg/widgets/epg_hero_preview.dart';
import '../../widgets/overlay_sheet.dart';
import '../../widgets/focus/request_initial_focus.dart';
import 'widgets/live_tv_section_header.dart';

class LiveTvScheduleScreen extends StatefulWidget {
  const LiveTvScheduleScreen({super.key});

  @override
  State<LiveTvScheduleScreen> createState() => _LiveTvScheduleScreenState();
}

class _LiveTvScheduleScreenState extends State<LiveTvScheduleScreen>
    with WidgetsBindingObserver {
  late final ScheduleViewModel _vm;
  // The schedule is a list of things that happen at a time, so a list loaded
  // hours ago is wrong in a way the user can see. Reload on resume, and on a
  // slow tick while the screen is open.
  Timer? _refreshTicker;

  // Same settling rule as the guide: moving through the list only arms the
  // preview, and nothing is published (so no artwork is fetched) until the
  // remote stops. Flying past twenty timers costs one image, not twenty.
  static const _settleDelay = Duration(milliseconds: 220);
  Timer? _settleTimer;
  RecordingItem? _pendingFocus;

  void _armPreview(RecordingItem item) {
    _pendingFocus = item;
    _settleTimer?.cancel();
    _settleTimer = Timer(_settleDelay, () {
      final settled = _pendingFocus;
      if (!mounted || settled == null) return;
      _vm.setFocusedItem(settled);
    });
  }

  @override
  void initState() {
    super.initState();
    _vm = ScheduleViewModel(GetIt.instance<MediaServerClient>());
    _vm.addListener(_onChanged);
    _vm.load();
    WidgetsBinding.instance.addObserver(this);
    _refreshTicker = Timer.periodic(
      const Duration(minutes: 5),
      (_) {
        if (mounted) unawaited(_vm.load());
      },
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed && mounted) {
      unawaited(_vm.load());
    }
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _refreshTicker?.cancel();
    _settleTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _vm.removeListener(_onChanged);
    _vm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      RequestInitialFocus(child: _buildScreenContent(context));

  Widget _buildScreenContent(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    return Column(
      children: [
        _buildHeader(),
        _buildPreview(),
        Expanded(child: _buildBody()),
      ],
    );
  }

  /// The same preview band the guide uses, so moving through scheduled
  /// recordings shows what each one actually is -- artwork, synopsis and a
  /// way straight to the channel -- instead of a title and a time.
  Widget _buildPreview() {
    final item = _vm.focusedItem;
    if (item == null) return const SizedBox.shrink();
    final tag = (item.imageTags?['Primary'] ?? item.imageTags?['Thumb'])
        ?.toString();
    final imageId = tag != null ? item.id : item.parentThumbItemId;
    final imageTag = tag ?? item.parentThumbImageTag;
    final url = (imageId != null && imageTag != null)
        ? _vm.imageApi.getPrimaryImageUrl(imageId, maxHeight: 240, tag: imageTag)
        : null;
    final start = item.startDate;
    final end = item.endDate;
    String two(int v) => v.toString().padLeft(2, '0');
    final timeLabel = start == null
        ? null
        : end == null
            ? '${two(start.hour)}:${two(start.minute)}'
            : '${two(start.hour)}:${two(start.minute)} - '
                '${two(end.hour)}:${two(end.minute)}';
    final now = DateTime.now();
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
      child: EpgHeroPreview(
        title: item.name,
        timeLabel: timeLabel,
        genreLabel: item.seriesName,
        synopsis: item.overview,
        channelLogoUrl: null,
        channelName: item.channelName,
        channelNumber: null,
        isLive: start != null &&
            end != null &&
            now.isAfter(start) &&
            now.isBefore(end),
        apple: PlatformDetection.isApple,
        imageUrl: url,
        onPlay: () => _watchChannel(item),
        playLabel: 'Watch channel',
      ),
    );
  }

  Widget _buildHeader() {
    return LiveTvSectionHeader(
      title: 'Voltix Schedule',
      details: _FocusedItemHud(item: _vm.focusedItem),
    );
  }

  Widget _buildBody() {
    if (_vm.state == ScheduleState.loading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF0066CC)),
      );
    }

    if (_vm.state == ScheduleState.error) {
      return Center(
        child: Text(
          AppLocalizations.of(context).failedToLoadSchedule,
          style: const TextStyle(color: Colors.white54),
        ),
      );
    }

    if (_vm.groups.isEmpty) {
      return Center(
        child: Text(
          AppLocalizations.of(context).noScheduledRecordings,
          style: TextStyle(
            fontSize: 16,
            color: Colors.white.withValues(alpha: 0.5),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        for (final group in _vm.groups)
          _ScheduleGroupRow(
            group: group,
            vm: _vm,
            onCancelTimer: _cancelTimer,
            onWatchChannel: _watchChannel,
            onFocused: _armPreview,
          ),
      ],
    );
  }

  /// Selecting a scheduled programme tunes straight to that channel --
  /// the same stream the user would get from Live TV -- instead of making
  /// them find the channel themselves. Cancelling the timer, which used to
  /// be what a plain tap did, moves to long press.
  void _watchChannel(RecordingItem item) {
    final channelId = item.rawData['ChannelId']?.toString() ?? '';
    if (channelId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No channel is linked to this scheduled recording'),
        ),
      );
      return;
    }
    context.push(Destinations.liveTvChannel(channelId));
  }

  Future<void> _cancelTimer(RecordingItem item) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showFocusRestoringDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A2E),
        title: Text(
          l10n.cancelRecording,
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          l10n.cancelScheduledRecordingOf(item.name),
          style: TextStyle(color: Colors.white.withValues(alpha: 0.8)),
        ),
        actions: [
          TextButton(
            onPressed:
                () => Navigator.of(ctx, rootNavigator: true).pop(false),
            child: Text(l10n.no),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(l10n.yesCancel),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _vm.cancelTimer(item.id);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.failedToCancelRecording)),
          );
        }
      }
    }
  }
}

class _FocusedItemHud extends StatelessWidget {
  final RecordingItem? item;

  const _FocusedItemHud({required this.item});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: item == null
          ? const SizedBox.shrink()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item!.name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (item!.subtitle.isNotEmpty)
                  Text(
                    item!.subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white.withValues(alpha: 0.6),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
    );
  }
}

class _ScheduleGroupRow extends StatelessWidget {
  final ScheduleGroup group;
  final ScheduleViewModel vm;
  final Future<void> Function(RecordingItem) onCancelTimer;
  final void Function(RecordingItem) onFocused;
  final void Function(RecordingItem) onWatchChannel;

  const _ScheduleGroupRow({
    required this.group,
    required this.vm,
    required this.onCancelTimer,
    required this.onFocused,
    required this.onWatchChannel,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 60, bottom: 8),
            child: Text(
              group.dateLabel,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
          SizedBox(
            height: 160,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 60),
              itemCount: group.items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final item = group.items[index];
                return _ScheduleCard(
                  item: item,
                  imageUrl: item.imageUrl(vm.imageApi),
                  onFocused: () => onFocused(item),
                  onTap: () => onWatchChannel(item),
                  onLongPress: () => onCancelTimer(item),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ScheduleCard extends StatefulWidget {
  final RecordingItem item;
  final String? imageUrl;
  final VoidCallback onFocused;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ScheduleCard({
    required this.item,
    required this.imageUrl,
    required this.onFocused,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  State<_ScheduleCard> createState() => _ScheduleCardState();
}

class _ScheduleCardState extends State<_ScheduleCard> with FocusStateMixin {

  @override
  Widget build(BuildContext context) {
    final cardExpansion =
        GetIt.instance<UserPreferences>().get(UserPreferences.cardFocusExpansion);
    final scale = cardExpansion && showFocusBorder ? 1.08 : 1.0;
    final alpha = showFocusBorder ? 1.0 : 0.75;
    final focusColor = Color(
      GetIt.instance<UserPreferences>().get(UserPreferences.focusColor).colorValue,
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setHovered(true),
      onExit: (_) => setHovered(false),
      child: Focus(
        onKeyEvent: (node, event) =>
            handleOneShotSelect(event, widget.onTap),
        onFocusChange: (focused) {
          setFocused(focused);
          if (focused) widget.onFocused();
        },
        child: GestureDetector(
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          child: AnimatedScale(
            scale: scale,
            duration: const Duration(milliseconds: 150),
            child: Opacity(
              opacity: alpha,
              child: SizedBox(
                width: 200,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 200,
                      height: 112,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(4),
                        border: showFocusBorder
                            ? Border.fromBorderSide(
                                ThemeRegistry.active.borders.focusBorder.copyWith(
                                  color: focusColor,
                                ),
                              )
                            : null,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: _buildImage(),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      widget.item.name,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: Colors.white,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (widget.item.subtitle.isNotEmpty)
                      Text(
                        widget.item.subtitle,
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildImage() {
    if (widget.imageUrl != null) {
      return CachedNetworkImage(
        imageUrl: widget.imageUrl!,
        fit: BoxFit.cover,
        width: 200,
        height: 112,
      );
    }
    return Center(
      child: Icon(
        Icons.schedule,
        size: 48,
        color: Colors.white.withValues(alpha: 0.2),
      ),
    );
  }
}
