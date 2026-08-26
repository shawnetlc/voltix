part of '../settings_side_panel.dart';

/// Lets the user pick what each of the six video time slots shows, or hide it.
class _PlaybackTimeLayoutScreen extends StatefulWidget {
  const _PlaybackTimeLayoutScreen();

  @override
  State<_PlaybackTimeLayoutScreen> createState() =>
      _PlaybackTimeLayoutScreenState();
}

class _PlaybackTimeLayoutScreenState extends State<_PlaybackTimeLayoutScreen> {
  static const _previewPosition = Duration(minutes: 42, seconds: 10);
  static const _previewDuration = Duration(hours: 1, minutes: 58, seconds: 33);

  late final UserPreferences _prefs;

  @override
  void initState() {
    super.initState();
    _prefs = GetIt.instance<UserPreferences>();
    _prefs.addListener(_onPreferencesChanged);
  }

  @override
  void dispose() {
    _prefs.removeListener(_onPreferencesChanged);
    super.dispose();
  }

  void _onPreferencesChanged() {
    if (!mounted) return;
    setState(() {});
  }

  String _slotLabel(AppLocalizations l10n, PlaybackTimeSlot value) {
    return switch (value) {
      PlaybackTimeSlot.none => l10n.none,
      PlaybackTimeSlot.elapsed => 'Elapsed',
      PlaybackTimeSlot.totalDuration => 'Total',
      PlaybackTimeSlot.timeRemaining => 'Remaining',
      PlaybackTimeSlot.endsAt => 'Ends at',
    };
  }

  String _preview(EnumPreference<PlaybackTimeSlot> preference) {
    return formatPlaybackTimeSlot(
      context,
      slot: _prefs.get(preference),
      position: _previewPosition,
      duration: _previewDuration,
      use24Hour: _prefs.get(UserPreferences.use24HourClock),
    );
  }

  Widget _buildPreview() {
    final above = PlaybackTimeRow(
      left: _preview(UserPreferences.playbackTimeAboveLeft),
      center: _preview(UserPreferences.playbackTimeAboveCenter),
      right: _preview(UserPreferences.playbackTimeAboveRight),
      bold: true,
    );
    final below = PlaybackTimeRow(
      left: _preview(UserPreferences.playbackTimeBelowLeft),
      center: _preview(UserPreferences.playbackTimeBelowCenter),
      right: _preview(UserPreferences.playbackTimeBelowRight),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.spaceLg,
        vertical: AppSpacing.spaceSm,
      ),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.spaceMd),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: AppRadius.circular(AppSpacing.spaceSm),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            above,
            const SizedBox(height: AppSpacing.spaceXs),
            ClipRRect(
              borderRadius: AppRadius.circular(2),
              child: LinearProgressIndicator(
                value:
                    _previewPosition.inMilliseconds /
                    _previewDuration.inMilliseconds,
                backgroundColor: AppColorScheme.rangeTrack,
                valueColor: AlwaysStoppedAnimation(
                  AppColorScheme.rangeProgress,
                ),
                minHeight: 4,
              ),
            ),
            const SizedBox(height: AppSpacing.spaceXs),
            below,
          ],
        ),
      ),
    );
  }

  EnumPreferenceTile<PlaybackTimeSlot> _slotTile(
    AppLocalizations l10n,
    EnumPreference<PlaybackTimeSlot> preference,
    String title,
    IconData icon, {
    bool autofocus = false,
  }) {
    return EnumPreferenceTile<PlaybackTimeSlot>(
      preference: preference,
      title: title,
      description: 'Choose what each clock around the seek bar shows.',
      icon: icon,
      autofocus: autofocus,
      labelOf: (v) => _slotLabel(l10n, v),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: buildSettingsAppBar(context, Text('Playback time display')),
      body: ListView(
        children: [
          _SectionHeader('Video'),
          _buildPreview(),
          adaptiveListSection(
            children: [
              _slotTile(
                l10n,
                UserPreferences.playbackTimeAboveLeft,
                'Above bar, left',
                Icons.align_horizontal_left,
                        ),
              _slotTile(
                l10n,
                UserPreferences.playbackTimeAboveCenter,
                'Above bar, centre',
                Icons.align_horizontal_center,
              ),
              _slotTile(
                l10n,
                UserPreferences.playbackTimeAboveRight,
                'Above bar, right',
                Icons.align_horizontal_right,
              ),
              _slotTile(
                l10n,
                UserPreferences.playbackTimeBelowLeft,
                'Below bar, left',
                Icons.align_horizontal_left,
              ),
              _slotTile(
                l10n,
                UserPreferences.playbackTimeBelowCenter,
                'Below bar, centre',
                Icons.align_horizontal_center,
              ),
              _slotTile(
                l10n,
                UserPreferences.playbackTimeBelowRight,
                'Below bar, right',
                Icons.align_horizontal_right,
              ),
            ],
          ),
          _SectionHeader('Music'),
          adaptiveListSection(
            children: [
              EnumPreferenceTile<PlaybackTimeDisplay>(
                preference: UserPreferences.musicPlaybackTimeDisplay,
                title: 'Playback time display',
                description: 'What the clock shows while music plays.',
                icon: Icons.music_note,
                labelOf: (v) => switch (v) {
                  PlaybackTimeDisplay.totalDuration => 'Total',
                  PlaybackTimeDisplay.timeRemaining =>
                    'Remaining',
                  PlaybackTimeDisplay.endsAt => 'Ends at',
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
