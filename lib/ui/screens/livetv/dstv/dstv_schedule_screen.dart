import 'package:flutter/material.dart';
import 'package:voltix_design/voltix_design.dart';

import '../../../../data/repositories/dstv_epg_repository.dart';
import '../../../widgets/focus/request_initial_focus.dart';
import 'dstv_epg_grid.dart';

/// LT > Schedule: today's DStv EPG only, in the compact grid layout with no
/// date picker -- "display only the day's EPG data".
class DstvScheduleScreen extends StatelessWidget {
  const DstvScheduleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return RequestInitialFocus(
      child: Scaffold(
        backgroundColor: AppColorScheme.background,
        appBar: AppBar(
          title: const Text('Schedule'),
          backgroundColor: AppColorScheme.background,
        ),
        body: DstvEpgGrid(date: DstvEpgRepository.nowSast()),
      ),
    );
  }
}
