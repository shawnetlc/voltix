import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:voltix_design/voltix_design.dart';

import '../../../../data/repositories/dstv_epg_repository.dart';
import '../../../widgets/focus/request_initial_focus.dart';
import 'dstv_epg_grid.dart';

/// LT > Guide: the full 14-day DStv EPG. Only one day's programme data is
/// ever fetched/held at a time -- "a 14 day breakdown, but not all at the
/// same time" -- picking a date here just swaps which day [DstvEpgGrid]
/// asks the repository for.
class DstvGuideScreen extends StatefulWidget {
  const DstvGuideScreen({super.key});

  @override
  State<DstvGuideScreen> createState() => _DstvGuideScreenState();
}

class _DstvGuideScreenState extends State<DstvGuideScreen> {
  late final List<DateTime> _dates = DstvEpgRepository.guideDates();
  late DateTime _selected = _dates.first;

  @override
  Widget build(BuildContext context) {
    return RequestInitialFocus(
      child: Scaffold(
        backgroundColor: AppColorScheme.background,
        appBar: AppBar(
          title: const Text('Guide'),
          backgroundColor: AppColorScheme.background,
        ),
        body: Column(
          children: [
            _DateTabBar(
              dates: _dates,
              selected: _selected,
              onSelected: (date) => setState(() => _selected = date),
            ),
            Expanded(child: DstvEpgGrid(date: _selected)),
          ],
        ),
      ),
    );
  }
}

class _DateTabBar extends StatelessWidget {
  final List<DateTime> dates;
  final DateTime selected;
  final ValueChanged<DateTime> onSelected;

  const _DateTabBar({
    required this.dates,
    required this.selected,
    required this.onSelected,
  });

  bool _isSameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Widget build(BuildContext context) {
    final dayFmt = DateFormat('EEE');
    final dateFmt = DateFormat('MMM dd');
    return Container(
      height: 76,
      color: AppColorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: dates.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final date = dates[index];
          final isToday = index == 0;
          final isSelected = _isSameDate(date, selected);
          return _DateChip(
            label: isToday ? 'Today' : dayFmt.format(date),
            sublabel: dateFmt.format(date),
            selected: isSelected,
            onTap: () => onSelected(date),
          );
        },
      ),
    );
  }
}

class _DateChip extends StatelessWidget {
  final String label;
  final String sublabel;
  final bool selected;
  final VoidCallback onTap;

  const _DateChip({
    required this.label,
    required this.sublabel,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? AppColorScheme.accent
          : AppColorScheme.onSurface.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          width: 96,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                  color: selected
                      ? AppColorScheme.onAccent
                      : AppColorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                sublabel,
                style: TextStyle(
                  fontSize: 11.5,
                  color: selected
                      ? AppColorScheme.onAccent.withValues(alpha: 0.85)
                      : AppColorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
