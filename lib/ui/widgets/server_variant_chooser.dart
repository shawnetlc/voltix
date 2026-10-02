import 'package:flutter/material.dart';
import 'package:voltix_design/voltix_design.dart';

import '../../data/models/aggregated_item.dart';

/// Label for one server variant, e.g. "Voltix 4K · 2160p".
String serverVariantLabel(AggregatedItem variant) {
  final name = variant.serverName ?? '';
  final quality = variant.videoResolution;
  if (name.isEmpty) return quality ?? variant.name;
  return quality != null && quality.isNotEmpty ? '$name · $quality' : name;
}

/// Shows the multi-server chooser so the user can pick which server to watch
/// [title] from. Returns the chosen variant, or null when dismissed.
Future<AggregatedItem?> showServerVariantChooser(
  BuildContext context, {
  required String title,
  required List<AggregatedItem> variants,
}) {
  return showDialog<AggregatedItem>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      backgroundColor: AppColorScheme.surface,
      title: Text(title, style: TextStyle(color: AppColorScheme.onSurface)),
      children: [
        for (var i = 0; i < variants.length; i++)
          SimpleDialogOption(
            onPressed: () => Navigator.of(dialogContext).pop(variants[i]),
            child: Text(
              serverVariantLabel(variants[i]),
              style: TextStyle(color: AppColorScheme.onSurface, fontSize: 18),
            ),
          ),
      ],
    ),
  );
}
