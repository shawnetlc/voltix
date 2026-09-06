part of '../settings_side_panel.dart';

class _PlaybackCategoryScreen extends StatelessWidget {
  const _PlaybackCategoryScreen();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return withCleanSettingsTypography(
      context,
      Scaffold(
        appBar: buildSettingsAppBar(
          context,
          Text(l10n.settingsPlaybackSyncplay),
        ),
        // Rebuild on preference changes so the Emulator Cores tile appears or
        // disappears the moment the emulator backend toggle flips.
        body: ListenableBuilder(
          listenable: GetIt.instance<UserPreferences>(),
          builder: (context, _) => ListView(
            children: [
              _SectionHeader(l10n.playback),
              adaptiveListSection(
                children: [
                  _TvSettingsListTile(
                    autofocus: true,
                    leading: const Icon(Icons.play_circle),
                    title: Text(l10n.settingsVideoPlaybackPreferences),
                    subtitle:
                        Text(l10n.settingsVideoPlaybackPreferencesSubtitle),
                    onTap: () =>
                        context.pushSettingsScreen(const _VideoPlaybackScreen()),
                  ),
                  _TvSettingsListTile(
                    leading: const Icon(Icons.volume_up),
                    title: Text(l10n.settingsAudioPreferences),
                    subtitle: Text(l10n.settingsAudioPreferencesSubtitle),
                    onTap: () => context.pushSettingsScreen(
                      const _AudioPreferencesScreen(),
                    ),
                  ),
                  _TvSettingsListTile(
                    leading: const Icon(Icons.schedule),
                    title: const Text('Playback Time Layout'),
                    subtitle: const Text(
                      'Choose what each clock around the seek bar shows',
                    ),
                    onTap: () => context.pushSettingsScreen(
                      const _PlaybackTimeLayoutScreen(),
                    ),
                  ),
                  _TvSettingsListTile(
                    leading: const Icon(Icons.smart_button),
                    title: const Text('Player Buttons'),
                    subtitle: const Text(
                      'Reorder or hide the buttons around the playback controls',
                    ),
                    onTap: () =>
                        context.pushSettingsScreen(const _OsdButtonsScreen()),
                  ),
                  _TvSettingsListTile(
                    leading: const Icon(Icons.subtitles),
                    title: Text(l10n.subtitles),
                    subtitle: Text(l10n.languageSizeAppearance),
                    onTap: () => context.pushSettingsScreen(
                      const SubtitleSettingsScreen(),
                    ),
                  ),
                ],
              ),
              _SectionHeader(l10n.general),
              adaptiveListSection(
                children: [
                  _TvSettingsListTile(
                    leading: const Icon(Icons.queue_play_next),
                    title: Text(l10n.settingsAutomationAndQueue),
                    subtitle: Text(l10n.settingsAutomationAndQueueSubtitle),
                    onTap: () => context.pushSettingsScreen(
                      const _AutomationQueueScreen(),
                    ),
                  ),
                  if (!PlatformDetection.isTV && !PlatformDetection.isWeb)
                    _TvSettingsListTile(
                      leading: const Icon(Icons.download),
                      title: Text(l10n.settingsOfflineDownloads),
                      subtitle: Text(l10n.settingsOfflineDownloadsSubtitle),
                      onTap: () => context.pushSettingsScreen(
                        const _OfflineDownloadsScreen(),
                      ),
                    ),
                  if (canToggleGameBackend)
                    SwitchPreferenceTile(
                      preference: UserPreferences.useNativeEmulator,
                      // Not yet in app_en.arb -- ported from upstream 2.5.0
                      // as a literal to avoid hand-editing every locale's
                      // .arb file without flutter gen-l10n available here.
                      title: 'Use native emulator',
                      subtitle:
                          'Play retro games with a built-in emulator instead of '
                          'the server-side one',
                      icon: Icons.sports_esports,
                    ),
                  if (supportsCoreDownloads && usesNativeGameBackend)
                    _TvSettingsListTile(
                      leading: const Icon(Icons.videogame_asset),
                      title: Text(l10n.emulatorCores),
                      // Not yet in app_en.arb -- see note above.
                      subtitle: const Text(
                        'Download the emulator cores games need to run',
                      ),
                      onTap: () => context.pushSettingsScreen(
                        const EmulatorCoresScreen(),
                      ),
                    ),
                  if (usesNativeGameBackend)
                    _TvSettingsListTile(
                      leading: const Icon(Icons.sd_storage),
                      title: Text(l10n.downloadedGames),
                      // Not yet in app_en.arb -- see note above.
                      subtitle: const Text(
                        'Manage games saved for offline play',
                      ),
                      onTap: () => context.pushSettingsScreen(
                        const DownloadedGamesScreen(),
                      ),
                    ),
                  _TvSettingsListTile(
                    leading: const Icon(Icons.groups),
                    title: Text(l10n.syncPlay),
                    subtitle: Text(l10n.settingsSyncplaySubtitle),
                    onTap: () => context.pushSettingsScreen(
                      const _SyncPlaySettingsScreen(),
                    ),
                  ),
                  _TvSettingsListTile(
                    leading: const Icon(Icons.settings),
                    title: Text(l10n.advancedOptions),
                    subtitle: Text(l10n.settingsAdvancedOptionsSubtitle),
                    onTap: () => context.pushSettingsScreen(
                      const _AdvancedOptionsScreen(),
                    ),
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
