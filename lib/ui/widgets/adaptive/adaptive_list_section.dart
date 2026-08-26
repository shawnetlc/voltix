import 'package:flutter/material.dart';
import 'package:voltix_design/voltix_design.dart';

import '../../../util/idiom/app_ui_idiom.dart';
import 'adaptive_glass.dart';

/// Wraps settings rows in an inset grouped card on Apple idioms, and leaves
/// them edge to edge everywhere else.
///
/// The non-Apple branch returns exactly the plain `Column` the settings screens
/// used before this existed, so Android, TV, Windows and Linux render
/// identically.
Widget adaptiveListSection({required List<Widget> children}) {
  if (AppUiIdiomResolver.isApple) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(
          Divider(
            height: 0.5,
            thickness: 0.5,
            indent: 16,
            color: AppColorScheme.onSurface.withValues(alpha: 0.12),
          ),
        );
      }
      rows.add(children[i]);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
      child: Builder(
        builder: (context) => adaptiveGlass(
          context: context,
          cornerRadius: 12,
          blur: 18,
          tint: AppColorScheme.onSurface.withValues(alpha: 0.05),
          fallbackColor: AppColorScheme.onSurface.withValues(alpha: 0.12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: rows,
          ),
        ),
      ),
    );
  }

  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: children,
  );
}
