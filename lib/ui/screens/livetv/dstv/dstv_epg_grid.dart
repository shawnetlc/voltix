import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:intl/intl.dart';
import 'package:voltix_design/voltix_design.dart';

import '../../../../data/models/dstv/dstv_epg_models.dart';
import '../../../../data/repositories/dstv_epg_repository.dart';
import '../../../widgets/bounded_network_image.dart';
import 'dstv_channel_modal.dart';

const _kChannelColumnWidth = 148.0;
const _kTimeHeaderHeight = 56.0;
const _kRowHeight = 100.0;
const _kPixelsPerMinute = 5.2;

/// The DStv EPG timeline grid: a fixed channel column on the left, a
/// horizontally-scrolling time ruler + programme timeline on the right, both
/// scrolling vertically together, plus a live "now" line. Shared by the
/// Guide screen (which adds a date picker above it) and the Schedule screen
/// (today only).
class DstvEpgGrid extends StatefulWidget {
  final DateTime date;
  final ScrollController? verticalController;

  const DstvEpgGrid({super.key, required this.date, this.verticalController});

  @override
  State<DstvEpgGrid> createState() => _DstvEpgGridState();
}

class _DstvEpgGridState extends State<DstvEpgGrid> {
  late final ScrollController _channelVController;
  late final ScrollController _gridVController;
  final _headerHController = ScrollController();
  final _gridHController = ScrollController();
  bool _syncingV = false;
  bool _syncingH = false;

  Future<List<DstvGuideRow>>? _rowsFuture;
  Timer? _nowTimer;
  DateTime _now = DstvEpgRepository.nowSast();


  bool _didScrollToNow = false;

  @override
  void initState() {
    super.initState();
    _channelVController = widget.verticalController ?? ScrollController();
    _gridVController = ScrollController();
    _channelVController.addListener(_onChannelScroll);
    _gridVController.addListener(_onGridVScroll);
    _headerHController.addListener(_onHeaderScroll);
    _gridHController.addListener(_onGridHScroll);
    _load();
    _nowTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() => _now = DstvEpgRepository.nowSast());
    });
  }

  @override
  void didUpdateWidget(covariant DstvEpgGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isSameDate(oldWidget.date, widget.date)) {
      _load();
    }
  }

  bool _isSameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  void _load() {
    _didScrollToNow = false;
    final future =
        GetIt.instance<DstvEpgRepository>().getGuideRows(widget.date);
    setState(() {
      _rowsFuture = future;
    });
    future.then((_) {
      if (mounted) _scheduleScrollToNow();
    });
  }

  void _onChannelScroll() {
    if (_syncingV || !_gridVController.hasClients) return;
    _syncingV = true;
    _gridVController.jumpTo(_channelVController.offset);
    _syncingV = false;
  }

  void _onGridVScroll() {
    if (_syncingV || !_channelVController.hasClients) return;
    _syncingV = true;
    _channelVController.jumpTo(_gridVController.offset);
    _syncingV = false;
  }

  void _onHeaderScroll() {
    if (_syncingH || !_gridHController.hasClients) return;
    _syncingH = true;
    _gridHController.jumpTo(_headerHController.offset);
    _syncingH = false;
  }

  void _onGridHScroll() {
    if (_syncingH || !_headerHController.hasClients) return;
    _syncingH = true;
    _headerHController.jumpTo(_gridHController.offset);
    _syncingH = false;
  }

  void _scheduleScrollToNow([int attempt = 0]) {
    if (!mounted || _didScrollToNow || !_isSameDate(widget.date, _now)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _didScrollToNow || !_isSameDate(widget.date, _now)) return;
      if (!_gridHController.hasClients ||
          _gridHController.position.maxScrollExtent <= 0) {
        if (attempt < 10) {
          _scheduleScrollToNow(attempt + 1);
        }
        return;
      }
      _scrollToNow();
    });
  }

  void _scrollToNow() {
    if (!_isSameDate(widget.date, _now)) return;
    if (!_gridHController.hasClients) return;
    final maxExtent = _gridHController.position.maxScrollExtent;
    if (maxExtent <= 0) return;

    final midnight = DateTime(_now.year, _now.month, _now.day);
    final minutesSinceMidnight = _now.difference(midnight).inMinutes;
    final offset =
        (minutesSinceMidnight * _kPixelsPerMinute) - 80;
    final clamped = offset.clamp(0.0, maxExtent).toDouble();

    _gridHController.jumpTo(clamped);
    if (_headerHController.hasClients) {
      _headerHController.jumpTo(clamped);
    }
    _didScrollToNow = true;
  }

  @override
  void dispose() {
    _nowTimer?.cancel();
    _channelVController.removeListener(_onChannelScroll);
    _gridVController.removeListener(_onGridVScroll);
    if (widget.verticalController == null) _channelVController.dispose();
    _gridVController.dispose();
    _headerHController.dispose();
    _gridHController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<DstvGuideRow>>(
      future: _rowsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _ErrorState(onRetry: _load);
        }
        final rows = snapshot.data ?? const [];
        if (rows.isEmpty) {
          return const _ErrorState(
            message: 'No channel guide available for this day.',
          );
        }
        final midnight = DateTime(
          widget.date.year,
          widget.date.month,
          widget.date.day,
        );
        final gridWidth = (24 * 60 * _kPixelsPerMinute);
        final showNowLine = _isSameDate(widget.date, _now);
        final nowOffset =
            _now.difference(midnight).inMinutes * _kPixelsPerMinute;

        return Column(
          children: [
            SizedBox(
              height: _kTimeHeaderHeight,
              child: Row(
                children: [
                  Container(
                    width: _kChannelColumnWidth,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColorScheme.surface,
                      border: Border(
                        right: BorderSide(
                          color: AppColorScheme.onSurface.withValues(alpha: 0.08),
                        ),
                      ),
                    ),
                    child: Text(
                      'Channels',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      controller: _headerHController,
                      scrollDirection: Axis.horizontal,
                      physics: const ClampingScrollPhysics(),
                      child: _TimeRuler(width: gridWidth),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: _kChannelColumnWidth,
                    child: ListView.builder(
                      controller: _channelVController,
                      physics: const ClampingScrollPhysics(),
                      itemCount: rows.length,
                      itemExtent: _kRowHeight,
                      itemBuilder: (context, i) =>
                          _ChannelCell(
                            channel: rows[i].channel,
                            onTap: () => showDstvChannelModal(
                              context,
                              channel: rows[i].channel,
                              programmes: rows[i].programmes,
                            ),
                          ),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      controller: _gridHController,
                      scrollDirection: Axis.horizontal,
                      physics: const ClampingScrollPhysics(),
                      child: SizedBox(
                        width: gridWidth,
                        child: Stack(
                          children: [
                            ListView.builder(
                              controller: _gridVController,
                              physics: const ClampingScrollPhysics(),
                              itemCount: rows.length,
                              itemExtent: _kRowHeight,
                              itemBuilder: (context, i) => _ProgrammeRow(
                                row: rows[i],
                                midnight: midnight,
                                now: _now,
                              ),
                            ),
                            if (showNowLine)
                              Positioned(
                                left: nowOffset,
                                top: 0,
                                bottom: 0,
                                child: IgnorePointer(
                                  child: Container(
                                    width: 2,
                                    decoration: BoxDecoration(
                                      color: AppColorScheme.accent,
                                      boxShadow: [
                                        BoxShadow(
                                          color: AppColorScheme.accent
                                              .withValues(alpha: 0.55),
                                          blurRadius: 8,
                                          spreadRadius: 0.5,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TimeRuler extends StatelessWidget {
  final double width;
  const _TimeRuler({required this.width});

  @override
  Widget build(BuildContext context) {
    final slots = (width / (30 * _kPixelsPerMinute)).ceil();
    final fmt = DateFormat('HH:mm');
    return SizedBox(
      width: width,
      height: _kTimeHeaderHeight,
      child: Stack(
        children: [
          for (var i = 0; i < slots; i++)
            Positioned(
              left: i * 30 * _kPixelsPerMinute,
              top: 0,
              bottom: 0,
              child: Container(
                width: 1,
                color: AppColorScheme.onSurface.withValues(alpha: 0.06),
              ),
            ),
          for (var i = 0; i < slots; i += 2)
            Positioned(
              left: i * 30 * _kPixelsPerMinute + 10,
              top: 0,
              bottom: 0,
              child: Align(
                alignment: Alignment.center,
                child: Text(
                  fmt.format(DateTime(2000, 1, 1).add(Duration(minutes: i * 30))),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ChannelCell extends StatelessWidget {
  final DstvChannel channel;
  final VoidCallback? onTap;
  const _ChannelCell({required this.channel, this.onTap});

  @override
  Widget build(BuildContext context) {
    final logo = channel.logo ?? channel.thumbnailUrl;
    // Wrapped rather than restyled: the cell keeps the exact look it had, and
    // only gains the tap. Selecting the channel is the whole point of the
    // guide, and until now the column was decoration.
    return InkWell(
      onTap: onTap,
      child: _cell(context, logo),
    );
  }

  Widget _cell(BuildContext context, String? logo) {
    return Container(
      height: _kRowHeight,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: AppColorScheme.surface,
        border: Border(
          right: BorderSide(color: AppColorScheme.onSurface.withValues(alpha: 0.08)),
          bottom: BorderSide(color: AppColorScheme.onSurface.withValues(alpha: 0.06)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(6),
                child: AspectRatio(
                  aspectRatio: 1.6,
                  child: logo == null || logo.isEmpty
                      ? const Icon(Icons.live_tv_rounded, color: Colors.black45)
                      : BoundedNetworkImage(
                          imageUrl: logo,
                          fit: BoxFit.contain,
                          fadeInDuration: const Duration(milliseconds: 150),
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.live_tv_rounded,
                            color: Colors.black45,
                          ),
                        ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Icon(Icons.star_border_rounded,
                  size: 16,
                  color: AppColorScheme.onSurface.withValues(alpha: 0.4)),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColorScheme.accent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  channel.number,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProgrammeRow extends StatelessWidget {
  final DstvGuideRow row;
  final DateTime midnight;
  final DateTime now;

  const _ProgrammeRow({
    required this.row,
    required this.midnight,
    required this.now,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: _kRowHeight,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColorScheme.onSurface.withValues(alpha: 0.06)),
        ),
      ),
      child: Stack(
        children: [
          for (final programme in row.programmes)
            Positioned(
              left: programme.start.difference(midnight).inMinutes *
                  _kPixelsPerMinute,
              width: (programme.duration.inMinutes * _kPixelsPerMinute)
                  .clamp(40.0, double.infinity)
                  .toDouble(),
              top: 6,
              bottom: 6,
              child: _ProgrammeBlock(
                programme: programme,
                isNow: programme.isAiringAt(now),
                row: row,
              ),
            ),
        ],
      ),
    );
  }
}

class _ProgrammeBlock extends StatelessWidget {
  final DstvProgramme programme;
  final bool isNow;
  final DstvGuideRow row;

  const _ProgrammeBlock({
    required this.programme,
    required this.isNow,
    required this.row,
  });

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('HH:mm');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: Material(
        color: isNow
            ? AppColorScheme.accent.withValues(alpha: 0.22)
            : AppColorScheme.onSurface.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _openChannel(context),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isNow
                    ? AppColorScheme.accent.withValues(alpha: 0.7)
                    : AppColorScheme.onSurface.withValues(alpha: 0.08),
                width: isNow ? 1.4 : 1,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        programme.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: isNow ? FontWeight.w800 : FontWeight.w600,
                          color: isNow
                              ? AppColorScheme.onSurface
                              : AppColorScheme.onSurface.withValues(alpha: 0.85),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.info_outline_rounded,
                      size: 14,
                      color: AppColorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  fmt.format(programme.start),
                  style: TextStyle(
                    fontSize: 11.5,
                    color: AppColorScheme.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Opens the channel sheet, scrolled to this programme.
  ///
  /// Replaces a dialog that showed the title and two times and offered nothing
  /// to do — no artwork, no synopsis, no way to watch or be reminded.
  void _openChannel(BuildContext context) {
    showDstvChannelModal(
      context,
      channel: row.channel,
      programmes: row.programmes,
      focus: programme,
    );
  }

}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  const _ErrorState({
    this.message = "Couldn't load the DStv guide. Check your connection.",
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded,
                size: 40, color: AppColorScheme.onSurface.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ],
        ),
      ),
    );
  }
}
