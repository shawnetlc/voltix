part of '../settings_side_panel.dart';

class _CustomizationCategoryScreen extends StatelessWidget {
  const _CustomizationCategoryScreen();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return withCleanSettingsTypography(
      context,
      Scaffold(
        appBar: buildSettingsAppBar(
          context,
          Text(l10n.settingsPersonalization),
        ),
        body: ListView(
          children: [
            adaptiveListSection(
              children: [
              _TvSettingsListTile(
                autofocus: true,
                leading: const Icon(Icons.style),
                title: Text(l10n.settingsGeneralStyle),
                subtitle: Text(l10n.settingsGeneralStyleSubtitle),
                onTap: () =>
                    context.pushSettingsScreen(const _GeneralStyleScreen()),
              ),
              _TvSettingsListTile(
                leading: const Icon(Icons.article_outlined),
                title: const Text('Details Screen'),
                subtitle: const Text(
                  'Background blur, recommendations and action buttons',
                ),
                onTap: () => context.pushSettingsScreen(
                  const _DetailsScreenSettingsScreen(),
                ),
              ),
              _TvSettingsListTile(
                leading: const Icon(Icons.view_sidebar),
                title: Text(l10n.navigation),
                subtitle: Text(l10n.navbarStyleToolbarAppearance),
                onTap: () =>
                    context.pushSettingsScreen(const _NavigationCategoryScreen()),
              ),
              _TvSettingsListTile(
                leading: const Icon(Icons.home),
                title: Text(l10n.homeScreen),
                subtitle: Text(l10n.settingsHomePageSubtitle),
                onTap: () =>
                    context.pushSettingsScreen(const _HomeScreenCategoryScreen()),
              ),
              _TvSettingsListTile(
                leading: const Icon(Icons.video_library),
                title: Text(l10n.libraries),
                subtitle: Text(l10n.settingsLibrariesSubtitle),
                onTap: () =>
                    context.pushSettingsScreen(const _LibrariesCategoryScreen()),
              ),
              _TvSettingsListTile(
                leading: const Icon(Icons.music_note),
                title: Text(l10n.themeMusic),
                subtitle: const Text('Playback, volume and looping'),
                onTap: () =>
                    context.pushSettingsScreen(const _ThemeMusicScreen()),
              ),
              if (PlatformDetection.isTV)
                _TvSettingsListTile(
                  leading: const Icon(Icons.wallpaper),
                  title: Text(l10n.screensaver),
                  subtitle: Text(l10n.enableBuiltInScreensaver),
                  onTap: () => context.pushSettingsScreen(
                    const ScreensaverSettingsScreen(),
                  ),
                ),
                        ],
            ),
],
        ),
      ),
    );
  }
}

void _pushPersonalizationSync() {
  final syncService = GetIt.instance<PluginSyncService>();
  if (syncService.pluginAvailable) {
    syncService.pushSettings(GetIt.instance<MediaServerClient>());
  }
}
