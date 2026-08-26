part of '../settings_side_panel.dart';

// The section list below is hand-written, but every leaf title was lifted
// straight out of the panel screens by script, so each one is an expression
// that already compiles in this library. Re-run the extractor after adding
// settings rather than hand-editing leaves.

/// One thing the settings search can surface: a screen or a single setting.
/// Opening a leaf lands on the screen that holds it, so [subtitle] carries the
/// breadcrumb that tells the user where they are about to go.
class _SettingsSearchEntry {
  _SettingsSearchEntry({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onOpen,
    required String matchText,
  }) : titleLower = title.toLowerCase(),
       haystack = matchText.toLowerCase();

  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onOpen;
  final String titleLower;
  final String haystack;
}

/// One source screen worth of entries. Every setting on a screen shares its
/// breadcrumb and the screen it opens, so declaring the screen once keeps each
/// setting below down to a title and a few keywords.
class _SearchSection {
  _SearchSection({
    required this.slug,
    required this.path,
    required this.icon,
    required this.open,
  });

  final String slug;

  /// Breadcrumb segments ending with this screen's own title.
  final List<String> path;
  final IconData icon;
  final VoidCallback open;

  _SettingsSearchEntry screen({List<String> keywords = const []}) =>
      _SettingsSearchEntry(
        id: slug,
        title: path.last,
        subtitle: path.length > 1
            ? path.sublist(0, path.length - 1).join(' > ')
            : '',
        icon: icon,
        onOpen: open,
        matchText: [...path, ...keywords].join(' '),
      );

  _SettingsSearchEntry leaf(
    String id,
    String title, {
    String? subtitle,
    List<String> keywords = const [],
    String? header,
  }) => _SettingsSearchEntry(
    id: '$slug.$id',
    title: title,
    subtitle: header == null
        ? path.join(' > ')
        : '${path.join(' > ')} > $header',
    icon: icon,
    onOpen: open,
    matchText: [title, ?subtitle, ...keywords, ...path].join(' '),
  );
}

/// Ranks [index] against [query]. Every word has to appear somewhere in an
/// entry, and entries whose title starts with or contains the whole query
/// outrank keyword only hits. Ties keep the order the panel lists things in.
List<_SettingsSearchEntry> _filterSettingsIndex(
  List<_SettingsSearchEntry> index,
  String query,
) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];
  final tokens = q.split(RegExp(r'\s+'));

  final scored = <({int score, int order, _SettingsSearchEntry entry})>[];
  for (var i = 0; i < index.length; i++) {
    final entry = index[i];
    if (!tokens.every(entry.haystack.contains)) continue;
    final score = entry.titleLower.startsWith(q)
        ? 3
        : entry.titleLower.contains(q)
        ? 2
        : 1;
    scored.add((score: score, order: i, entry: entry));
  }
  scored.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    return byScore != 0 ? byScore : a.order.compareTo(b.order);
  });
  return [for (final match in scored.take(30)) match.entry];
}

/// The whole settings tree flattened for search. Rebuilt on every query so
/// titles follow the language and the gates follow the device.
List<_SettingsSearchEntry> _buildSettingsSearchIndex({
  required AppLocalizations l10n,
  required bool showAdmin,
  required bool showThemeEditor,
  required void Function(Widget screen) push,
  required VoidCallback openAdmin,
  required VoidCallback openThemeEditor,
}) {
  final seerrAvailable = GetIt.instance<PluginSyncService>().seerrAvailable;
  final tmdbAvailable = GetIt.instance<PluginSyncService>().tmdbAvailable;
  final account = _SearchSection(
    slug: 'account',
    path: [l10n.settingsAccountSecurity],
    icon: Icons.lock,
    open: () => push(const _AuthenticationCategoryScreen()),
  );
  final personalization = _SearchSection(
    slug: 'personalization',
    path: [l10n.settingsPersonalization],
    icon: Icons.palette,
    open: () => push(const _CustomizationCategoryScreen()),
  );
  final style = _SearchSection(
    slug: 'style',
    path: [l10n.settingsPersonalization, l10n.settingsGeneralStyle],
    icon: Icons.style,
    open: () => push(const _GeneralStyleScreen()),
  );
  final details = _SearchSection(
    slug: 'details',
    path: [l10n.settingsPersonalization, 'Details Screen'],
    icon: Icons.article_outlined,
    open: () => push(const _DetailsScreenSettingsScreen()),
  );
  final detailButtons = _SearchSection(
    slug: 'detail-buttons',
    path: [l10n.settingsPersonalization, 'Details Screen', 'Detail Buttons'],
    icon: Icons.smart_button,
    open: () => push(const _DetailButtonsScreen()),
  );
  final navigation = _SearchSection(
    slug: 'navigation',
    path: [l10n.settingsPersonalization, l10n.navigation],
    icon: Icons.view_sidebar,
    open: () => push(const _NavigationCategoryScreen()),
  );
  final home = _SearchSection(
    slug: 'home',
    path: [l10n.settingsPersonalization, l10n.homeScreen],
    icon: Icons.home,
    open: () => push(const _HomeScreenCategoryScreen()),
  );
  final externalLists = _SearchSection(
    slug: 'external-lists',
    path: [l10n.integrations, l10n.externalLists],
    icon: Icons.playlist_add,
    open: () => push(const _ExternalListsScreen()),
  );
  final imdbLists = _SearchSection(
    slug: 'imdb',
    path: [l10n.integrations, l10n.externalLists, 'IMDb Lists'],
    icon: Icons.list_alt,
    open: () => push(const _ImdbListsScreen()),
  );
  final tmdbLists = _SearchSection(
    slug: 'tmdb',
    path: [l10n.integrations, l10n.externalLists, 'TMDB Lists'],
    icon: Icons.list_alt,
    open: () => push(const _TmdbListsScreen()),
  );
  final calendars = _SearchSection(
    slug: 'calendars',
    path: [l10n.integrations, l10n.externalLists, 'Upcoming Calendars'],
    icon: Icons.calendar_month,
    open: () => push(const _UpcomingCalendarsScreen()),
  );
  final seerrLists = _SearchSection(
    slug: 'seerr-lists',
    path: [l10n.integrations, l10n.externalLists, 'Seerr Lists'],
    icon: Icons.list_alt,
    open: () => push(const _SeerrListsScreen()),
  );
  final customRows = _SearchSection(
    slug: 'custom-rows',
    path: [l10n.integrations, l10n.externalLists, 'Custom Home Rows Wizard'],
    icon: Icons.dashboard_customize,
    open: () => push(const _CustomListsScreen()),
  );
  final libraries = _SearchSection(
    slug: 'libraries',
    path: [l10n.settingsPersonalization, l10n.libraries],
    icon: Icons.video_library,
    open: () => push(const _LibrariesCategoryScreen()),
  );
  final themeMusic = _SearchSection(
    slug: 'theme-music',
    path: [l10n.settingsPersonalization, l10n.themeMusic],
    icon: Icons.music_note,
    open: () => push(const _ThemeMusicScreen()),
  );
  final seasonal = _SearchSection(
    slug: 'seasonal',
    path: [l10n.settingsPersonalization, l10n.seasonalEffects],
    icon: Icons.auto_awesome,
    open: () => push(const _SeasonalEffectsScreen()),
  );
  final dynamicContent = _SearchSection(
    slug: 'dynamic-content',
    path: [l10n.settingsDynamicContent],
    icon: Icons.featured_play_list,
    open: () => push(const _PluginCategoryScreen()),
  );
  final playback = _SearchSection(
    slug: 'playback',
    path: [l10n.settingsPlaybackSyncplay],
    icon: Icons.play_circle,
    open: () => push(const _PlaybackCategoryScreen()),
  );
  final video = _SearchSection(
    slug: 'video',
    path: [l10n.settingsPlaybackSyncplay, l10n.settingsVideoPlaybackPreferences],
    icon: Icons.play_circle,
    open: () => push(const _VideoPlaybackScreen()),
  );
  final audio = _SearchSection(
    slug: 'audio',
    path: [l10n.settingsPlaybackSyncplay, l10n.settingsAudioPreferences],
    icon: Icons.volume_up,
    open: () => push(const _AudioPreferencesScreen()),
  );
  final osdButtons = _SearchSection(
    slug: 'osd-buttons',
    path: [l10n.settingsPlaybackSyncplay, 'Player Buttons'],
    icon: Icons.smart_button,
    open: () => push(const _OsdButtonsScreen()),
  );
  final automation = _SearchSection(
    slug: 'automation',
    path: [l10n.settingsPlaybackSyncplay, l10n.settingsAutomationAndQueue],
    icon: Icons.queue_play_next,
    open: () => push(const _AutomationQueueScreen()),
  );
  final downloads = _SearchSection(
    slug: 'downloads',
    path: [l10n.settingsPlaybackSyncplay, l10n.settingsOfflineDownloads],
    icon: Icons.download,
    open: () => push(const _OfflineDownloadsScreen()),
  );
  final syncplay = _SearchSection(
    slug: 'syncplay',
    path: [l10n.settingsPlaybackSyncplay, l10n.syncPlay],
    icon: Icons.groups,
    open: () => push(const _SyncPlaySettingsScreen()),
  );
  final advanced = _SearchSection(
    slug: 'advanced',
    path: [l10n.settingsPlaybackSyncplay, l10n.advancedOptions],
    icon: Icons.settings,
    open: () => push(const _AdvancedOptionsScreen()),
  );
  final integrations = _SearchSection(
    slug: 'integrations',
    path: [l10n.integrations],
    icon: Icons.hub,
    open: () => push(const _IntegrationsScreen()),
  );
  final metadata = _SearchSection(
    slug: 'metadata',
    path: [l10n.integrations, 'Metadata & Ratings'],
    icon: Icons.star,
    open: () => push(const _MetadataRatingsScreen()),
  );
  final plugin = _SearchSection(
    slug: 'plugin',
    path: [l10n.integrations, 'Plugin'],
    icon: Icons.extension,
    open: () => push(const _PluginScreen()),
  );
  final seerr = _SearchSection(
    slug: 'seerr',
    path: [l10n.integrations, 'Seerr'],
    icon: Icons.request_page,
    open: () => push(const SeerrConfigScreen()),
  );
  final about = _SearchSection(
    slug: 'about',
    path: [l10n.aboutTitle],
    icon: Icons.info_outline,
    open: () => push(const _AboutCategoryScreen()),
  );
  final licenses = _SearchSection(
    slug: 'licenses',
    path: [l10n.aboutTitle, 'Licenses'],
    icon: Icons.description,
    open: () => push(const _LicensesScreen()),
  );
  final themes = _SearchSection(
    slug: 'themes',
    path: [l10n.settingsPersonalization, l10n.settingsGeneralStyle, 'Appearance & Theme'],
    icon: Icons.color_lens,
    open: () => push(const AppearanceThemeScreen()),
  );
  final themeStore = _SearchSection(
    slug: 'theme-store',
    path: [l10n.settingsPersonalization, l10n.settingsGeneralStyle, 'Theme Store'],
    icon: Icons.storefront,
    open: () => push(const ThemeStoreScreen()),
  );
  final savedThemes = _SearchSection(
    slug: 'saved-themes',
    path: [l10n.settingsPersonalization, l10n.settingsGeneralStyle, 'Saved Themes'],
    icon: Icons.bookmark,
    open: () => push(const SavedThemesScreen()),
  );
  final homeSections = _SearchSection(
    slug: 'home-sections',
    path: [l10n.settingsPersonalization, l10n.homeScreen, l10n.homeSections],
    icon: Icons.list,
    open: () => push(const HomeSectionsScreen(showGeneralOptions: false)),
  );
  final homeRowToggles = _SearchSection(
    slug: 'home-row-toggles',
    path: [l10n.settingsPersonalization, l10n.homeScreen, l10n.homeRowToggles],
    icon: Icons.tune,
    open: () => push(const HomeRowTogglesScreen()),
  );
  final rowImageType = _SearchSection(
    slug: 'row-image-type',
    path: [l10n.settingsPersonalization, l10n.homeScreen, 'Per-Row Image Type'],
    icon: Icons.image_outlined,
    open: () => push(const HomeRowsImageTypeScreen()),
  );
  final libraryVisibility = _SearchSection(
    slug: 'library-visibility',
    path: [l10n.settingsPersonalization, l10n.libraries, 'Library Visibility'],
    icon: Icons.visibility,
    open: () => push(const LibraryVisibilityScreen()),
  );
  final mediaBar = _SearchSection(
    slug: 'media-bar',
    path: [l10n.settingsDynamicContent, l10n.mediaBar],
    icon: Icons.featured_play_list,
    open: () => push(const MediaBarSettingsScreen()),
  );
  final parental = _SearchSection(
    slug: 'parental',
    path: [l10n.settingsAccountSecurity, 'Blocked Ratings'],
    icon: Icons.shield,
    open: () => push(const ParentalSettingsScreen()),
  );
  final pin = _SearchSection(
    slug: 'pin',
    path: [l10n.settingsAccountSecurity, 'PIN Code'],
    icon: Icons.pin,
    open: () => push(const PinCodeSettingsScreen()),
  );
  final profile = _SearchSection(
    slug: 'profile',
    path: [l10n.settingsAccountSecurity, 'Profile'],
    icon: Icons.person,
    open: () => push(const ProfileSettingsScreen()),
  );
  final ratings = _SearchSection(
    slug: 'ratings',
    path: [l10n.integrations, 'Metadata & Ratings', 'Ratings'],
    icon: Icons.star_half,
    open: () => push(const RatingsConfigScreen()),
  );
  final diagnostics = _SearchSection(
    slug: 'diagnostics',
    path: [l10n.aboutTitle, 'Diagnostics'],
    icon: Icons.bug_report,
    open: () => push(const DiagnosticsSettingsScreen()),
  );
  final subtitles = _SearchSection(
    slug: 'subtitles',
    path: [l10n.settingsPlaybackSyncplay, l10n.subtitles],
    icon: Icons.subtitles,
    open: () => push(const SubtitleSettingsScreen()),
  );

  return [
    if (showAdmin)
      _SettingsSearchEntry(
        id: 'admin',
        title: l10n.administration,
        subtitle: '',
        icon: Icons.admin_panel_settings,
        onOpen: openAdmin,
        matchText: '${l10n.administration} admin server users dashboard',
      ),
    if (showThemeEditor)
      _SettingsSearchEntry(
        id: 'theme-editor',
        title: l10n.themeEditor,
        subtitle: '',
        icon: Icons.brush,
        onOpen: openThemeEditor,
        matchText: '${l10n.themeEditor} theme editor web',
      ),
    account.screen(keywords: const ['security','login','password','account']),
    account.leaf('0', 'Use Local Test Server'),
    account.leaf('1', l10n.autoLogin),
    account.leaf('2', l10n.alwaysAuthenticate),
    account.leaf('3', l10n.interfaceLanguage),
    account.leaf('4', l10n.settingsSortServersBy),
    account.leaf('5', l10n.confirmExit),
    personalization.screen(keywords: const ['appearance','theme','look','customise','customize']),
    style.screen(keywords: const ['style','blur','poster','card']),
    style.leaf('0', l10n.focusBorderColor),
    style.leaf('1', l10n.keyboardPreferSystemIme),
    style.leaf('2', l10n.clockDisplay),
    style.leaf('3', l10n.settingsTwentyFourHourClock),
    style.leaf('4', l10n.focusExpansionAnimation),
    style.leaf('5', l10n.desktopUiScale),
    style.leaf('6', l10n.backgroundBackdrops),
    style.leaf('7', l10n.browsingBackgroundBlur),
    style.leaf('8', l10n.watchedIndicators),
    details.screen(keywords: const ['detail','recommend','blur']),
    details.leaf('0', l10n.detailsBackgroundBlur),
    details.leaf('1', 'Recommendation system'),
    details.leaf('2', 'Cap recommendations by parental rating'),
    detailButtons.screen(keywords: const ['button','reorder','hide','action']),
    navigation.screen(keywords: const ['navbar','toolbar','sidebar','tabs']),
    navigation.leaf('0', l10n.navigationStyle),
    navigation.leaf('1', l10n.navbarOpacity),
    navigation.leaf('2', l10n.showShuffleButton),
    navigation.leaf('3', l10n.showGenresButton),
    navigation.leaf('4', l10n.showFavoritesButton),
    navigation.leaf('5', l10n.showLibrariesInToolbar),
    navigation.leaf('6', l10n.showSeerrButton),
    home.screen(keywords: const ['home','rows','sections']),
    home.leaf('0', 'Hide Shared Server Continue Watching Items'),
    home.leaf('1', 'Hide Extra Server items'),
    home.leaf('2', 'Hide 4K Server items'),
    home.leaf('3', l10n.rowsType),
    home.leaf('4', l10n.mergeContinueWatchingAndNextUp),
    home.leaf('5', l10n.seriesThumbnails),
    home.leaf('6', l10n.fullScreenRows),
    home.leaf('7', l10n.cardSize),
    home.leaf('8', l10n.homeRowInfoOverlay),
    if (seerrAvailable) ...[
      externalLists.screen(keywords: [
        'external home rows',
        'imdb',
        'tmdb',
        'letterboxd',
      ]),
      imdbLists.screen(keywords: ['top 250', 'popular', 'charts']),
      imdbLists.leaf('imdb_top_250_movies_enabled', l10n.imdbTop250Movies),
      imdbLists.leaf('imdb_top_250_tv_shows_enabled', l10n.imdbTop250TvShows),
      imdbLists.leaf(
        'imdb_most_popular_movies_enabled',
        l10n.imdbMostPopularMovies,
      ),
      imdbLists.leaf(
        'imdb_most_popular_tv_shows_enabled',
        l10n.imdbMostPopularTvShows,
      ),
      imdbLists.leaf(
        'imdb_lowest_rated_movies_enabled',
        l10n.imdbLowestRatedMovies,
      ),
      imdbLists.leaf(
        'imdb_top_english_movies_enabled',
        l10n.imdbTopEnglishMovies,
      ),
      if (tmdbAvailable) ...[
        tmdbLists.screen(keywords: ['popular', 'top rated', 'trending']),
        tmdbLists.leaf('tmdb_popular_movies_enabled', 'Popular Movies'),
        tmdbLists.leaf('tmdb_top_rated_movies_enabled', 'Top Rated Movies'),
        tmdbLists.leaf('tmdb_now_playing_movies_enabled', 'Now Playing Movies'),
        tmdbLists.leaf('tmdb_upcoming_movies_enabled', 'Upcoming Movies'),
        tmdbLists.leaf('tmdb_popular_tv_enabled', 'Popular TV'),
        tmdbLists.leaf('tmdb_top_rated_tv_enabled', 'Top Rated TV'),
        tmdbLists.leaf('tmdb_airing_today_tv_enabled', 'Airing Today TV'),
        tmdbLists.leaf('tmdb_on_the_air_tv_enabled', 'On The Air TV'),
        tmdbLists.leaf(
          'tmdb_trending_movie_daily_enabled',
          'Trending Movies (Daily)',
        ),
        tmdbLists.leaf(
          'tmdb_trending_movie_weekly_enabled',
          'Trending Movies (Weekly)',
        ),
        tmdbLists.leaf('tmdb_trending_tv_daily_enabled', 'Trending TV (Daily)'),
        tmdbLists.leaf(
          'tmdb_trending_tv_weekly_enabled',
          'Trending TV (Weekly)',
        ),
        tmdbLists.leaf(
          'tmdb_trending_all_weekly_enabled',
          'Trending All (Weekly)',
        ),
      ],
      calendars.screen(keywords: ['radarr', 'sonarr', 'upcoming releases']),
      calendars.leaf(
        'merge_radarr_sonarr_calendars',
        'Merge Sonarr and Radarr Calendars?',
      ),
      calendars.leaf(
        'enable_radarr_calendar',
        "Enable Radarr's Upcoming Calendar",
        keywords: ['movies'],
      ),
      calendars.leaf(
        'radarr_calendar_show_cinema',
        'Show Upcoming Cinema Releases',
        header: 'Radarr',
      ),
      calendars.leaf(
        'radarr_calendar_show_digital',
        'Show Upcoming Digital Releases',
        header: 'Radarr',
      ),
      calendars.leaf(
        'radarr_calendar_show_physical',
        'Show Upcoming Physical Releases',
        header: 'Radarr',
      ),
      calendars.leaf(
        'radarr_calendar_show_date',
        'Show Release Date on Home Screen?',
        header: 'Radarr',
      ),
      calendars.leaf(
        'enable_sonarr_calendar',
        "Enable Sonarr's Upcoming Calendar",
        keywords: ['shows', 'episodes'],
      ),
      calendars.leaf(
        'sonarr_calendar_show_episode_info',
        'Display Episode Information?',
        header: 'Sonarr',
      ),
      calendars.leaf(
        'sonarr_calendar_show_date',
        'Show Release Date on Home Screen?',
        header: 'Sonarr',
      ),
      seerrLists.screen(keywords: ['discovery rows', 'watchlist', 'trending']),
      customRows.screen(keywords: ['letterboxd', 'mdblist', 'tmdb', 'custom']),
    ],
    libraries.screen(keywords: const ['library','libraries','visibility']),
    libraries.leaf('0', l10n.enableFolderView),
    libraries.leaf('1', l10n.multiServerLibraries),
    libraries.leaf('2', 'Enable multi-server search'),
    libraries.leaf('3', l10n.showMediaDetailsOnLibraryPage),
    libraries.leaf('4', l10n.useDetailedSubHeadings),
    themeMusic.screen(keywords: const ['music','theme','loop','volume']),
    themeMusic.leaf('0', l10n.themeMusic),
    themeMusic.leaf('1', l10n.themeMusicVolume),
    themeMusic.leaf('2', l10n.themeMusicOnHomeRows),
    themeMusic.leaf('3', 'Loop Theme Music'),
    seasonal.screen(keywords: const ['seasonal','snow','effects']),
    seasonal.leaf('0', l10n.settingsSeasonalSurprise),
    dynamicContent.screen(keywords: const ['media bar','previews','dynamic']),
    playback.screen(keywords: const ['playback','player','syncplay']),
    video.screen(keywords: const ['video','quality','bitrate','transcode']),
    video.leaf('0', l10n.showDescriptionOnPause),
    video.leaf('1', l10n.playerZoomMode),
    video.leaf('2', l10n.trickPlay),
    video.leaf('3', l10n.settingsScrollWheelAction),
    video.leaf('4', l10n.resumeRewind),
    video.leaf('5', l10n.unpauseRewind),
    video.leaf('6', l10n.skipBackLength),
    video.leaf('7', l10n.skipForwardLength),
    video.leaf('8', l10n.osdLockButton),
    video.leaf('9', l10n.settingsDolbyVisionFallback),
    video.leaf('10', l10n.settingsDolbyVisionProfile7DirectPlay),
    video.leaf('11', l10n.hardwareDecoding),
    video.leaf('12', l10n.refreshRateSwitching),
    video.leaf('13', l10n.autoHdrSwitching),
    video.leaf('14', l10n.settingsLiveTvDirect),
    video.leaf('15', l10n.maxStreamingBitrate),
    video.leaf('16', l10n.maxResolution),
    audio.screen(keywords: const ['audio','passthrough','atmos','bitstream']),
    audio.leaf('0', l10n.nightMode),
    audio.leaf('1', l10n.defaultAudioLanguage),
    audio.leaf('2', 'Audio Output'),
    audio.leaf('3', l10n.settingsAudioOutputMode),
    audio.leaf('4', l10n.settingsMaxAudioChannels),
    audio.leaf('5', l10n.settingsAudioFallbackCodec),
    audio.leaf('6', l10n.ac3Passthrough),
    audio.leaf('7', l10n.settingsAudioEac3Passthrough),
    audio.leaf('8', l10n.settingsAudioEac3JocPassthrough),
    audio.leaf('9', l10n.settingsAudioDtsCorePassthrough),
    audio.leaf('10', l10n.settingsAudioDtsHdPassthrough),
    audio.leaf('11', l10n.settingsAudioDtsXPassthrough),
    audio.leaf('12', l10n.settingsAudioTrueHdPassthrough),
    audio.leaf('13', l10n.settingsAudioTrueHdJocPassthrough),
    osdButtons.screen(keywords: const ['button','osd','reorder','hide','controls']),
    automation.screen(keywords: const ['autoplay','queue','skip','intro']),
    automation.leaf('0', l10n.settingsCinemaMode),
    automation.leaf('1', l10n.settingsSkipIntrosAndOutros),
    automation.leaf('2', l10n.settingsMediaSegmentCountdown),
    automation.leaf('3', l10n.autoplayNextEpisode),
    automation.leaf('4', l10n.nextUpDisplay),
    automation.leaf('5', l10n.nextUpTimeout),
    automation.leaf('6', l10n.replaceSkipOutroWithNextUpDisplay),
    automation.leaf('7', l10n.stillWatchingPrompt),
    downloads.screen(keywords: const ['download','offline','storage']),
    downloads.leaf('0', l10n.defaultDownloadQuality),
    downloads.leaf('1', l10n.wifiOnlyDownloads),
    downloads.leaf('2', l10n.storageLimit),
    downloads.leaf('3', l10n.settingsConcurrentDownloads),
    syncplay.screen(keywords: const ['syncplay','together','group','watch party']),
    syncplay.leaf('0', 'Show remote control in main menu'),
    syncplay.leaf('1', 'Show D-pad on remote'),
    syncplay.leaf('2', l10n.settingsSyncplayEnabled),
    syncplay.leaf('3', l10n.settingsSyncplayButton),
    syncplay.leaf('4', l10n.settingsSyncplayAdvancedCorrection),
    syncplay.leaf('5', l10n.settingsSyncplaySyncCorrection),
    syncplay.leaf('6', l10n.settingsSyncplaySpeedToSync),
    syncplay.leaf('7', l10n.settingsSyncplaySkipToSync),
    advanced.screen(keywords: const ['advanced','external player','debug']),
    advanced.leaf('0', l10n.settingsVideoStartDelay),
    advanced.leaf('1', l10n.preferSoftwareDecoders),
    advanced.leaf('2', l10n.skipSilenceTitle),
    advanced.leaf('3', l10n.allowExternalAudioEffectsTitle),
    advanced.leaf('4', l10n.enableTunnelingTitle),
    advanced.leaf('5', l10n.mapDolbyVisionP7Title),
    advanced.leaf('6', l10n.useExternalPlayer),
    advanced.leaf('7', l10n.enableCustomMpvConf),
    advanced.leaf('8', l10n.unsafeAdvancedMpvOptions),
    integrations.screen(keywords: const ['integration','plugin','seerr','jellyseerr']),
    metadata.screen(keywords: const ['rating','metadata','imdb','tmdb']),
    metadata.leaf('0', l10n.additionalRatings),
    metadata.leaf('1', l10n.episodeRatings),
    metadata.leaf('2', l10n.ratingLabels),
    metadata.leaf('3', l10n.ratingBadges),
    plugin.screen(keywords: const ['plugin','moonbase']),
    seerr.screen(keywords: const ['seerr','jellyseerr','request','overseerr']),
    about.screen(keywords: const ['about','version','update','licence','license']),
    licenses.screen(keywords: const ['licence','license','open source']),
    themes.screen(keywords: const ['theme','colour','color','dark','light']),
    themeStore.screen(keywords: const ['theme','store','download']),
    savedThemes.screen(keywords: const ['theme','saved']),
    homeSections.screen(keywords: const ['rows','reorder','sections','order']),
    homeRowToggles.screen(keywords: const ['rows','toggle','rewatch','since you watched','recommend']),
    rowImageType.screen(keywords: const ['image','thumbnail','poster','backdrop','row']),
    libraryVisibility.screen(keywords: const ['library','hide','visibility','show']),
    mediaBar.screen(keywords: const ['media bar','featured','hero','trailer']),
    parental.screen(keywords: const ['parental','rating','block','kids','age']),
    pin.screen(keywords: const ['pin','lock','code','passcode']),
    profile.screen(keywords: const ['profile','user','avatar']),
    ratings.screen(keywords: const ['rating','imdb','tomatoes','metacritic','stars']),
    diagnostics.screen(keywords: const ['log','diagnostic','debug','report']),
    subtitles.screen(keywords: const ['subtitle','caption','language','srt']),
  ];
}
