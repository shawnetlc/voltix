import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:voltix_design/voltix_design.dart';

import '../../../../data/models/dstv/dstv_epg_models.dart';
import '../../../../data/repositories/dstv_epg_repository.dart';
import '../../../../data/repositories/programme_reminder_repository.dart';
import '../../../navigation/destinations.dart';

/// The channel sheet: what is on, what is coming, and what you can do about it.
///
/// Opened by tapping a channel in the TV Guide or the Schedule. Before this, a
/// channel in the guide was inert — the grid could tell you a film started at
/// 20:00 and gave you no way to watch it, and tapping a programme produced a
/// bare dialog with a title and two times.
///
/// One rule decides the whole screen: a programme is either on now or it is not.
/// On now gets **Play**, which tunes to the channel. Later gets **Remind me**,
/// which has the server push a notification shortly before it starts. There is
/// deliberately no third state — "record", "watch later" and the rest are
/// promises this platform cannot keep for live DStv.
Future<void> showDstvChannelModal(
  BuildContext context, {
  required DstvChannel channel,
  required List<DstvProgramme> programmes,
  /// Programme to scroll to and expand, when opened from a specific one.
  DstvProgramme? focus,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _DstvChannelSheet(
      channel: channel,
      programmes: programmes,
      focus: focus,
    ),
  );
}

class _DstvChannelSheet extends StatefulWidget {
  final DstvChannel channel;
  final List<DstvProgramme> programmes;
  final DstvProgramme? focus;

  const _DstvChannelSheet({
    required this.channel,
    required this.programmes,
    this.focus,
  });

  @override
  State<_DstvChannelSheet> createState() => _DstvChannelSheetState();
}

class _DstvChannelSheetState extends State<_DstvChannelSheet> {
  final _reminders = ProgrammeReminderRepository();

  /// Null while the lookup is in flight, so the Play button can show a spinner
  /// rather than appearing and then vanishing.
  String? _streamId;
  String? _providerChannelName;
  bool _resolving = true;
  bool _inLineup = true;

  /// Set when the line-up could not be checked at all. Distinct from
  /// [_inLineup] being false, which means it *was* checked and the channel is
  /// genuinely not carried. Telling a viewer "not in your package" because the
  /// provider's channel list failed to load is a lie they cannot act on.
  bool _lookupFailed = false;

  /// Programme start times the viewer has a reminder for, so the button can say
  /// "Reminder set" instead of offering it again.
  final Set<DateTime> _remindered = {};
  final Set<DateTime> _busy = {};

  @override
  void initState() {
    super.initState();
    _resolveStream();
    _loadExistingReminders();
  }

  Future<void> _resolveStream() async {
    ResolvedChannel? resolved;
    var failed = false;
    try {
      resolved = await _reminders.resolveChannel(
        channelName: widget.channel.name,
        channelNumber: widget.channel.number,
      );
    } on LineupCheckException catch (e) {
      failed = true;
      debugPrint('[DStv modal] line-up check failed for '
          '${widget.channel.number} ${widget.channel.name}: $e');
    }
    if (!mounted) return;
    setState(() {
      _streamId = resolved?.streamId;
      _providerChannelName = resolved?.channelName;
      _inLineup = resolved != null;
      _lookupFailed = failed;
      _resolving = false;
    });
  }

  Future<void> _loadExistingReminders() async {
    final existing = await _reminders.listReminders();
    if (!mounted) return;
    setState(() {
      for (final r in existing) {
        if (r.channelName == widget.channel.name ||
            r.channelNumber == widget.channel.number) {
          _remindered.add(r.startsAt.toLocal());
        }
      }
    });
  }

  void _play() {
    final id = _streamId;
    if (id == null) return;
    Navigator.of(context).pop();
    context.go(
      Destinations.voltixLiveTvChannel(id, channelName: _providerChannelName),
    );
  }

  Future<void> _remindMe(DstvProgramme programme) async {
    setState(() => _busy.add(programme.start));

    final deepLink = _streamId != null
        ? Destinations.voltixLiveTvChannel(_streamId!, channelName: _providerChannelName)
        : null;

    final result = await _reminders.setReminder(
      channelName: widget.channel.name,
      channelNumber: widget.channel.number,
      providerChannelName: _providerChannelName,
      streamId: _streamId,
      actionUrl: deepLink,
      programmeTitle: programme.title,
      description: programme.description,
      imageUrl: programme.iconUrl,
      startsAt: programme.start,
      endsAt: programme.end,
    );

    if (!mounted) return;
    setState(() {
      _busy.remove(programme.start);
      if (result.ok) _remindered.add(programme.start);
    });

    final messenger = ScaffoldMessenger.maybeOf(context);
    if (result.ok) {
      final when = result.notifyAt?.toLocal();
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            result.alreadySet
                ? 'You already have a reminder for ${programme.title}.'
                : when != null
                    ? 'We will notify you at ${DateFormat('HH:mm').format(when)}.'
                    : 'Reminder set for ${programme.title}.',
          ),
        ),
      );
    } else {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Could not set that reminder. Please try again.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DstvEpgRepository.nowSast();

    // Everything that has already finished is dropped. A guide is for what is
    // coming; a list that opens on this morning's repeats makes the viewer
    // scroll past the past to reach the present.
    final upcoming = widget.programmes
        .where((p) => p.end.isAfter(now))
        .toList(growable: false);

    return DraggableScrollableSheet(
      initialChildSize: 0.82,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: AppColorScheme.background,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border.all(
            color: AppColorScheme.onSurface.withValues(alpha: 0.08),
          ),
        ),
        child: Column(
          children: [
            _grabHandle(),
            _header(context),
            const Divider(height: 1),
            Expanded(
              child: upcoming.isEmpty
                  ? _emptyState()
                  : ListView.separated(
                      controller: scrollController,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      itemCount: upcoming.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final programme = upcoming[index];
                        return _ProgrammeTile(
                          programme: programme,
                          isNow: programme.isAiringAt(now),
                          canPlay: _inLineup && _streamId != null,
                          resolving: _resolving,
                          lookupFailed: _lookupFailed,
                          onRetryLookup: _retryLookup,
                          hasReminder: _remindered.contains(programme.start),
                          busy: _busy.contains(programme.start),
                          onPlay: _play,
                          onRemind: () => _remindMe(programme),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _grabHandle() => Container(
        width: 40,
        height: 4,
        margin: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: AppColorScheme.onSurface.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(2),
        ),
      );

  Widget _header(BuildContext context) {
    final logo = widget.channel.logo ?? widget.channel.thumbnailUrl;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: Row(
        children: [
          if (logo != null && logo.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(6),
                child: Image.network(
                  logo,
                  width: 48,
                  height: 34,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const SizedBox(width: 48, height: 34),
                ),
              ),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.channel.name,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: AppColorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _subtitle(),
                  style: TextStyle(
                    fontSize: 12.5,
                    color: AppColorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  String _subtitle() {
    final number = widget.channel.number;
    if (_resolving) return 'Channel $number · checking your line-up…';
    if (_lookupFailed) return "Channel $number · couldn't check your line-up";
    if (!_inLineup) return 'Channel $number · not in your package';
    return 'Channel $number';
  }

  /// The failed lookup is not cached, so simply asking again is enough.
  Future<void> _retryLookup() async {
    if (_resolving) return;
    setState(() {
      _resolving = true;
      _lookupFailed = false;
    });
    await _resolveStream();
  }

  Widget _emptyState() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            'Nothing more scheduled on this channel today.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
      );
}

/// One programme: artwork, times, synopsis, and the single action that applies.
class _ProgrammeTile extends StatelessWidget {
  final DstvProgramme programme;
  final bool isNow;
  final bool canPlay;
  final bool resolving;
  final bool lookupFailed;
  final VoidCallback onRetryLookup;
  final bool hasReminder;
  final bool busy;
  final VoidCallback onPlay;
  final VoidCallback onRemind;

  const _ProgrammeTile({
    required this.programme,
    required this.isNow,
    required this.canPlay,
    required this.resolving,
    required this.lookupFailed,
    required this.onRetryLookup,
    required this.hasReminder,
    required this.busy,
    required this.onPlay,
    required this.onRemind,
  });

  @override
  Widget build(BuildContext context) {
    final timeFmt = DateFormat('HH:mm');
    final image = programme.iconUrl;

    return Container(
      decoration: BoxDecoration(
        color: isNow
            ? AppColorScheme.accent.withValues(alpha: 0.10)
            : AppColorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isNow
              ? AppColorScheme.accent.withValues(alpha: 0.5)
              : AppColorScheme.onSurface.withValues(alpha: 0.08),
        ),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (image != null && image.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    image,
                    width: 104,
                    height: 59, // 16:9
                    fit: BoxFit.cover,
                    // XMLTV artwork is third-party and frequently missing. A
                    // failed load leaves the space blank rather than throwing a
                    // broken-image glyph into the middle of the list.
                    errorBuilder: (_, _, _) => Container(
                      width: 104,
                      height: 59,
                      color: AppColorScheme.onSurface.withValues(alpha: 0.06),
                      child: Icon(
                        Icons.tv_rounded,
                        size: 20,
                        color: AppColorScheme.onSurface.withValues(alpha: 0.3),
                      ),
                    ),
                  ),
                ),
              if (image != null && image.isNotEmpty) const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        if (isNow) ...[
                          _nowPill(),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(
                            '${timeFmt.format(programme.start)} – ${timeFmt.format(programme.end)}',
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColorScheme.onSurface.withValues(alpha: 0.6),
                            ),
                          ),
                        ),
                        if (programme.rating != null) _ratingPill(programme.rating!),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      programme.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColorScheme.onSurface,
                      ),
                    ),
                    if (programme.description != null &&
                        programme.description!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        programme.description!,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.4,
                          color: AppColorScheme.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(width: double.infinity, child: _action(context)),
        ],
      ),
    );
  }

  Widget _action(BuildContext context) {
    if (isNow) {
      if (resolving) {
        return const FilledButton(
          onPressed: null,
          child: SizedBox(
            height: 16,
            width: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      }
      if (lookupFailed) {
        // We do not know whether this channel is carried — say so, and give the
        // viewer the one thing that might help.
        return OutlinedButton.icon(
          onPressed: onRetryLookup,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: const Text("Couldn't check — tap to retry"),
        );
      }
      if (!canPlay) {
        // Honest rather than hopeful: the guide lists every DStv channel, the
        // viewer's package does not carry every DStv channel, and a Play button
        // that fails is worse than one that is not there.
        return OutlinedButton.icon(
          onPressed: null,
          icon: const Icon(Icons.block_rounded, size: 18),
          label: const Text('Not in your package'),
        );
      }
      return FilledButton.icon(
        onPressed: onPlay,
        icon: const Icon(Icons.play_arrow_rounded),
        label: const Text('Play live stream'),
      );
    }

    if (hasReminder) {
      return OutlinedButton.icon(
        onPressed: null,
        icon: const Icon(Icons.notifications_active_rounded, size: 18),
        label: const Text('Reminder set'),
      );
    }

    return OutlinedButton.icon(
      onPressed: busy ? null : onRemind,
      icon: busy
          ? const SizedBox(
              height: 14,
              width: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.notifications_none_rounded, size: 18),
      label: const Text('Remind me'),
    );
  }

  Widget _nowPill() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: AppColorScheme.accent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Text(
          'ON NOW',
          style: TextStyle(
            fontSize: 9.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.5,
            color: Colors.black,
          ),
        ),
      );

  Widget _ratingPill(String rating) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: AppColorScheme.onSurface.withValues(alpha: 0.25),
          ),
        ),
        child: Text(
          rating,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: AppColorScheme.onSurface.withValues(alpha: 0.7),
          ),
        ),
      );
}
