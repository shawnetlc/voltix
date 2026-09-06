part of '../settings_side_panel.dart';

class _LibrariesCategoryScreen extends StatelessWidget {
  const _LibrariesCategoryScreen();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: buildSettingsAppBar(context, Text(l10n.libraries)),
      body: ListView(
        children: [
          _SectionHeader(l10n.general),
          adaptiveListSection(
            children: [
              _TvSettingsListTile(
                leading: const Icon(Icons.visibility),
                title: Text(l10n.libraryVisibility),
                subtitle: Text(l10n.settingsLibraryVisibilitySubtitle),
                onTap: () =>
                    context.pushSettingsScreen(const LibraryVisibilityScreen()),
              ),
              SwitchPreferenceTile(
                preference: UserPreferences.enableFolderView,
                title: l10n.enableFolderView,
                subtitle: l10n.showFolderBrowsingOption,
                icon: Icons.folder,
                onChanged: _pushPersonalizationSync,
              ),
              SwitchPreferenceTile(
                preference: UserPreferences.enableMultiServerLibraries,
                title: l10n.multiServerLibraries,
                subtitle: l10n.showLibrariesFromAllServers,
                icon: Icons.dns,
                onChanged: _pushPersonalizationSync,
              ),
              SwitchPreferenceTile(
                preference: UserPreferences.enableMultiServerSearch,
                title: 'Enable multi-server search',
                subtitle:
                    'Search every server you are signed in to and label results '
                    'with their server and quality',
                icon: Icons.travel_explore,
                onChanged: _pushPersonalizationSync,
              ),
              SwitchPreferenceTile(
                preference: UserPreferences.mergeRecentRowsByType,
                // Not yet in app_en.arb -- ported from upstream 2.5.0 as a
                // literal to avoid hand-editing every locale's .arb file
                // without flutter gen-l10n available in this environment.
                title: 'Merge recent rows by type',
                subtitle:
                    'Show one "Recently added" row per media type instead of '
                    'mixing movies, series and music together',
                icon: Icons.library_books,
                onChanged: _pushPersonalizationSync,
              ),
              EnumPreferenceTile<RecentlyReleasedSeriesType>(
                preference: UserPreferences.recentlyReleasedSeriesType,
                title: 'Recently released grouping',
                description:
                    'Group the Recently Released row by series, by season, '
                    'or show every new episode on its own',
                icon: Icons.ondemand_video,
                labelOf: (v) => switch (v) {
                  RecentlyReleasedSeriesType.series => l10n.series,
                  RecentlyReleasedSeriesType.season => l10n.season,
                  RecentlyReleasedSeriesType.episode => l10n.episode,
                },
                onChanged: _pushPersonalizationSync,
              ),
            ],
          ),
          _SectionHeader('Library view'),
          adaptiveListSection(
            children: [
              SwitchPreferenceTile(
                preference: UserPreferences.groupItemsIntoCollections,
                title: 'Group items into collections',
                subtitle: 'Hide items that already appear inside a collection',
                icon: Icons.collections_bookmark,
                onChanged: () async {
                  _pushPersonalizationSync();
                  final prefs = GetIt.instance<UserPreferences>();
                  final isEnabled = prefs.get(
                    UserPreferences.groupItemsIntoCollections,
                  );
                  if (isEnabled) {
                    final client = GetIt.instance<MediaServerClient>();
                    try {
                      final config = await client.adminSystemApi
                          .getServerConfiguration();
                      final groupMovies =
                          (config['EnableGroupingMoviesIntoCollections']
                              as bool?) ??
                          (config['EnableGroupingIntoCollections'] as bool?) ??
                          false;
                      final groupShows =
                          (config['EnableGroupingShowsIntoCollections']
                              as bool?) ??
                          (config['EnableGroupingIntoCollections'] as bool?) ??
                          false;
                      if (groupMovies && groupShows) {
                        return;
                      }
                    } catch (_) {}

                    if (!context.mounted) return;
                    showFocusRestoringDialog(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('Server setting required'),
                        content: const Text(
                          'Ask your server admin to enable "Group movies/shows '
                          'into collections" in the server\'s library settings '
                          'for this to take full effect.',
                        ),
                        actions: [
                          TextButton(
                            autofocus: true,
                            onPressed: () => Navigator.pop(dialogContext),
                            child: Text(l10n.ok),
                          ),
                        ],
                      ),
                    );
                  }
                },
              ),
              SwitchPreferenceTile(
                preference: UserPreferences.showMediaDetailsOnLibraryPage,
                title: l10n.showMediaDetailsOnLibraryPage,
                subtitle: l10n.showMediaDetailsOnLibraryPageDescription,
                icon: Icons.info_outline,
                onChanged: _pushPersonalizationSync,
              ),
              SwitchPreferenceTile(
                preference: UserPreferences.useDetailedSubHeadings,
                title: l10n.useDetailedSubHeadings,
                subtitle: l10n.useDetailedSubHeadingsDescription,
                icon: Icons.subtitles,
                onChanged: _pushPersonalizationSync,
              ),
              SwitchPreferenceTile(
                preference: UserPreferences.hideBackdropsInLibraries,
                title: 'Hide backdrops in libraries',
                icon: Icons.hide_image_outlined,
                onChanged: _pushPersonalizationSync,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
