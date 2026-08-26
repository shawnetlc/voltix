part of '../settings_side_panel.dart';

/// Switches and ordering for the buttons around the playback controls.
/// Only the buttons this kind of device can draw are listed, and the
/// arrangement it writes to is the one for this kind of device.
///
/// Copy is inline for the same reason as [_DetailButtonsScreen].
class _OsdButtonsScreen extends StatelessWidget {
  const _OsdButtonsScreen();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return RequestInitialFocus(
      child: withCleanSettingsTypography(
        context,
        Scaffold(
          appBar: buildSettingsAppBar(context, const Text('Player Buttons')),
          body: ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(
                  'Choose which buttons appear around the playback controls.',
                  style: hint,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  PlatformDetection.isTV
                      ? 'Press left or right to move a button.'
                      : 'Use the arrows to move a button.',
                  style: hint,
                ),
              ),
              ButtonLayoutList(
                layout: osdButtonLayout,
                entries: [
                  for (final button in OsdButton.values.where(
                    (button) => button.isOffered,
                  ))
                    ButtonLayoutEntry(
                      id: button.id,
                      title: button.label(l10n),
                      icon: button.icon,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
