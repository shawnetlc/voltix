import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:playback_core/playback_core.dart';

import '../../auth/repositories/session_repository.dart';
import '../../auth/repositories/user_repository.dart';
import '../../auth/store/voltix_session_store.dart';
import '../../data/services/connectivity_service.dart';
import '../../data/services/media_server_client_factory.dart';
import '../../di/injection.dart';
import '../../playback/external_player_policy.dart';
import '../../preference/user_preferences.dart';
import '../../syncplay/syncplay_manager.dart';
import '../../util/platform_detection.dart';
import '../screens/notifications/notifications_screen.dart';
import '../screens/auth/emby_connect_screen.dart';
import '../screens/auth/login_screen.dart';
import '../screens/auth/server_screen.dart';
import '../screens/auth/server_select_screen.dart';
import '../screens/auth/startup_screen.dart';
import '../screens/web_diagnostics_screen.dart';
import '../screens/auth/voltix_login_screen.dart';
import '../screens/auth/profile_select_screen.dart';
import '../screens/auth/profile_edit_screen.dart';

import '../../data/models/voltix_profile.dart';
import '../screens/auth/voltix_register_screen.dart';
import '../screens/browse/all_genres_screen.dart';
import '../screens/browse/collection_screen.dart';
import '../screens/browse/favorites_screen.dart';
import '../screens/browse/folder_browse_screen.dart';
import '../screens/browse/folder_view_screen.dart';
import '../screens/browse/library_browse_screen.dart';
import '../screens/browse/library_genres_screen.dart';
import '../screens/browse/library_letters_screen.dart';
import '../screens/browse/library_suggestions_screen.dart';
import '../screens/browse/music_browse_screen.dart';
import '../screens/detail/item_detail_screen.dart';
import '../screens/detail/item_list_screen.dart';
import '../screens/detail/music_favorites_screen.dart';
import '../screens/home/home_screen.dart';
import '../screens/seerr/seerr_browse_screen.dart';
import '../screens/seerr/seerr_collection_screen.dart';
import '../screens/seerr/seerr_discover_screen.dart';

import '../screens/seerr/seerr_person_screen.dart';
import '../screens/seerr/seerr_requests_screen.dart';
import '../screens/livetv/dstv/dstv_guide_screen.dart';
import '../screens/livetv/dstv/dstv_schedule_screen.dart';
import '../screens/livetv/live_tv_guide_screen.dart';
import '../screens/livetv/live_tv_player_screen.dart';
import '../../data/viewmodels/live_tv_guide_view_model.dart';
import '../screens/livetv/live_tv_recordings_screen.dart';
import '../screens/livetv/live_tv_screen.dart';
import '../screens/livetv/live_tv_series_recordings_screen.dart';
import '../screens/livetv/voltix_live_tv_screen.dart';
import '../screens/playback/audio_player_screen.dart';
import '../screens/playback/book_reader_screen.dart';
import '../screens/playback/external_player_host_screen.dart';
import '../screens/playback/next_up_screen.dart';
import '../screens/playback/photo_player_screen.dart';
import '../screens/playback/still_watching_screen.dart';
import '../screens/playback/trailer_player_screen.dart';
import '../screens/playback/video_player_screen.dart';
import '../screens/playback/appletv_player_host_screen.dart';
import '../screens/playback/appletv_livetv_player_host_screen.dart';
import '../screens/search/search_screen.dart';
import '../screens/settings/settings_side_panel.dart';
import '../screens/setup/setup_wizard_gate.dart';
import '../screens/setup/setup_wizard_screen.dart';
import '../screens/admin/admin_shell_screen.dart';
import '../screens/admin/admin_content_analytics_screen.dart';
import '../screens/admin/admin_dashboard_screen.dart';
import '../screens/admin/users/admin_users_screen.dart';
import '../screens/admin/users/admin_user_add_screen.dart';
import '../screens/admin/users/admin_user_edit_screen.dart';
import '../screens/admin/libraries/admin_libraries_screen.dart';
import '../screens/admin/libraries/admin_library_add_screen.dart';
import '../screens/admin/libraries/admin_library_edit_screen.dart';
import '../screens/admin/libraries/admin_library_display_screen.dart';
import '../screens/admin/libraries/admin_library_metadata_screen.dart';
import '../screens/admin/libraries/admin_library_nfo_screen.dart';
import '../screens/admin/tasks/admin_tasks_screen.dart';
import '../screens/admin/tasks/admin_task_detail_screen.dart';
import '../screens/admin/activity/admin_activity_screen.dart';
import '../screens/admin/settings/admin_general_settings_screen.dart';
import '../screens/admin/settings/admin_branding_screen.dart';
import '../screens/admin/settings/admin_networking_screen.dart';
import '../screens/admin/settings/admin_playback_settings_screen.dart';
import '../screens/admin/settings/admin_resume_settings_screen.dart';
import '../screens/admin/settings/admin_streaming_screen.dart';
import '../screens/admin/settings/admin_trickplay_screen.dart';
import '../screens/admin/plugins/admin_plugins_screen.dart';
import '../screens/admin/plugins/admin_plugin_detail_screen.dart';
import '../screens/admin/plugins/admin_repositories_screen.dart';
import '../screens/admin/devices/admin_devices_screen.dart';
import '../screens/admin/keys/admin_api_keys_screen.dart';
import '../screens/admin/backups/admin_backups_screen.dart';
import '../screens/admin/logs/admin_logs_screen.dart';
import '../screens/admin/logs/admin_log_viewer_screen.dart';
import '../screens/admin/livetv/admin_live_tv_screen.dart';
import '../screens/admin/metadata/admin_metadata_edit_screen.dart';
import '../screens/downloads/saved_media_screen.dart';
import '../screens/downloads/saved_album_screen.dart';
import '../screens/downloads/saved_season_screen.dart';
import '../screens/downloads/saved_series_screen.dart';
import '../screens/downloads/storage_management_screen.dart';
import '../../data/services/retro_artwork/retro_artwork_activity_gate.dart';
import '../../util/game_cores.dart';
import '../../data/models/tmdb_item_ref.dart';
import '../screens/browse/book_browse_screen.dart';
import '../screens/games/game_library_screen.dart';
import '../screens/games/game_system_screen.dart';
import '../screens/games/game_detail_screen.dart';
import '../screens/playback/game_emulator_screen.dart';
import '../screens/playback/native_game_player_screen.dart';
import '../screens/livetv/live_tv_channel_player_loader.dart';
import 'destinations.dart';
import 'focus_route_observer.dart';
import 'route_lifecycle_observer.dart';

const _authRoutes = {
  Destinations.startup,
  Destinations.voltixLogin,
  Destinations.profileSelect,
  Destinations.register,
  Destinations.serverSelect,
  Destinations.embyConnect,
  Destinations.webDiagnostics,
  Destinations.server,
  Destinations.login,
};

bool _shouldRunSetupWizard() {
  try {
    final client = GetIt.instance<MediaServerClientFactory>().getActiveClient();
    return GetIt.instance<SetupWizardGate>().shouldRun(client);
  } catch (_) {
    return false;
  }
}

bool _isOfflineAllowed(String path) {
  if (path.startsWith('/settings')) return true;
  if (path == Destinations.videoPlayer ||
      path == Destinations.externalPlayer ||
      path == Destinations.audioPlayer) {
    return true;
  }
  // Live TV (both the Voltix IPTV screen and the Jellyfin/Emby EPG guide) is
  // exempted for the same reason the player routes are: a stream buffering
  // or a token refresh can make the connectivity check blink offline for a
  // moment mid-session. Without this, popping back out of a channel while
  // that blink is in flight got rewritten by this redirect to Downloads --
  // a screen with nothing beneath it on the stack, whose own back button
  // then has nowhere to go but Home. That is what "exiting a channel dumps
  // me on the home page instead of the channel list" turned out to be.
  if (path.startsWith('/live-tv')) return true;
  return false;
}

bool _shouldRedirectVideoToExternalPlayer(String path) {
  if (path != Destinations.videoPlayer) {
    return false;
  }

  final manager = GetIt.instance<PlaybackManager>();
  if (manager.consumeSkipExternalRoutingOnce()) {
    return false;
  }

  if (!(PlatformDetection.isAndroid && PlatformDetection.isTV)) {
    return false;
  }

  final prefs = GetIt.instance<UserPreferences>();
  if (!prefs.get(UserPreferences.useExternalPlayer)) {
    return false;
  }

  if (GetIt.instance.isRegistered<SyncPlayManager>()) {
    final syncPlay = GetIt.instance<SyncPlayManager>();
    if (syncPlay.state.enabled) {
      return false;
    }
  }

  return ExternalPlayerPolicy.isEligibleItem(manager.queueService.currentItem);
}

CustomTransitionPage<T> _opaqueFullScreenPage<T>({
  required GoRouterState state,
  required Widget child,
}) {
  return CustomTransitionPage<T>(
    key: state.pageKey,
    name: state.name ?? state.uri.path,
    opaque: true,
    barrierColor: Colors.black,
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    transitionsBuilder: (context, animation, secondaryAnimation, child) =>
        child,
    child: child,
  );
}

final appRouter = GoRouter(
  initialLocation: Destinations.startup,
  observers: [
    FocusRouteObserver(),
    RetroArtworkRouteObserver.instance,
    routeLifecycleObserver,
    PlayerRouteObserver.instance,
  ],
  redirect: (context, state) {
    final path = state.uri.path;
    if (_authRoutes.contains(path)) return null;

    if (path.startsWith('/downloads')) return null;

    final session = GetIt.instance<SessionRepository>();
    if (session.activeUserId == null) {
      return Destinations.startup;
    }

    // Has to sit above every other rule and below the signed-out one: the
    // wizard needs a user to set up, and nothing else is worth showing until
    // it has had its turn. Exempting its own path is what stops it
    // redirecting to itself forever. By the time this fires, Voltix's own
    // taste-onboarding dialog has already been awaited and dismissed in
    // _navigatePostLogin — that's a modal shown before any context.go() call,
    // so it never trips this redirect itself, and the wizard only ever
    // appears afterwards.
    if (path != Destinations.setup && _shouldRunSetupWizard()) {
      return Destinations.setup;
    }

    if (path.startsWith('/admin')) {
      final user = getIt.isRegistered<UserRepository>()
          ? getIt<UserRepository>().currentUser
          : null;
      final voltixStore = getIt.isRegistered<VoltixSessionStore>()
          ? getIt<VoltixSessionStore>()
          : null;
      final isAdmin = (user != null &&
              (user.isAdministrator ||
                  user.name.toLowerCase() == 'voltixadmin' ||
                  user.name.toLowerCase() == 'admin' ||
                  user.name.toLowerCase().contains('admin'))) ||
          (voltixStore != null &&
              voltixStore.hasSession &&
              (voltixStore.isAdmin ||
                  (voltixStore.username?.toLowerCase() == 'voltixadmin') ||
                  (voltixStore.username?.toLowerCase() == 'admin') ||
                  (voltixStore.username?.toLowerCase().contains('admin') ?? false)));
      if (!isAdmin) {
        return Destinations.home;
      }
    }

    final connectivity = GetIt.instance<ConnectivityService>();
    if (!connectivity.isOnline && !_isOfflineAllowed(path)) {
      return Destinations.downloads;
    }

    if (_shouldRedirectVideoToExternalPlayer(path)) {
      return Destinations.externalPlayer;
    }

    return null;
  },
  routes: [
    // Auth
    GoRoute(
      path: Destinations.startup,
      builder: (context, state) {
        final bootstrap = state.uri.queryParameters['bootstrap'] == '1';
        return StartupScreen(bootstrapActiveSession: bootstrap);
      },
    ),
    GoRoute(
      path: Destinations.voltixLogin,
      builder: (context, state) => const VoltixLoginScreen(),
    ),
    GoRoute(
      path: Destinations.profileSelect,
      builder: (context, state) => const ProfileSelectScreen(),
    ),
    GoRoute(
      path: Destinations.profileEdit,
      builder: (context, state) {
        final profile = state.extra as VoltixProfile?;
        return ProfileEditScreen(profile: profile);
      },
    ),
    GoRoute(
      path: Destinations.register,
      builder: (context, state) => const VoltixRegisterScreen(),
    ),
    GoRoute(
      path: Destinations.serverSelect,
      builder: (context, state) => const ServerSelectScreen(),
    ),
    GoRoute(
      path: Destinations.setup,
      builder: (context, state) => const SetupWizardScreen(),
    ),
    GoRoute(
      path: Destinations.embyConnect,
      builder: (context, state) => const EmbyConnectScreen(),
    ),
    GoRoute(
      path: Destinations.webDiagnostics,
      builder: (context, state) => WebDiagnosticsScreen(
        reason: state.uri.queryParameters['reason'],
        targetUrl: state.uri.queryParameters['url'],
        detail: state.uri.queryParameters['detail'],
      ),
    ),
    GoRoute(
      path: Destinations.server,
      builder: (context, state) {
        final serverId = state.uri.queryParameters['serverId'] ?? '';
        return ServerScreen(serverId: serverId);
      },
    ),
    GoRoute(
      path: Destinations.login,
      builder: (context, state) {
        final serverId = state.uri.queryParameters['serverId'] ?? '';
        final username = state.uri.queryParameters['username'];
        final hasPassword =
            state.uri.queryParameters['hasPassword']?.toLowerCase() != 'false';
        return LoginScreen(
          serverId: serverId,
          prefillUsername: username,
          hasPassword: hasPassword,
        );
      },
    ),

    // General
    GoRoute(
      path: Destinations.home,
      builder: (context, state) {
        final session = GetIt.instance<SessionRepository>();
        return HomeScreen(key: ValueKey(session.activeUserId ?? ''));
      },
    ),
    GoRoute(
      path: Destinations.search,
      builder: (context, state) => SearchScreen(
        initialQuery: state.uri.queryParameters['query'],
        scopedLibraryId: state.uri.queryParameters['libraryId'],
      ),
    ),

    // Browsing
    GoRoute(
      path: Destinations.libraryBrowse,
      builder: (context, state) {
        final libraryId = state.pathParameters['libraryId']!;
        final serverId = state.uri.queryParameters['serverId'];
        final typesParam = state.uri.queryParameters['types'];
        final bookUiParam = state.uri.queryParameters['bookUi'];
        final includeItemTypes = typesParam
            ?.split(',')
            .map(Uri.decodeComponent)
            .toList();
        return LibraryBrowseScreen(
          libraryId: libraryId,
          serverId: serverId,
          includeItemTypes: includeItemTypes,
          forceBookExperience:
              bookUiParam == '1' || bookUiParam?.toLowerCase() == 'true',
        );
      },
      routes: [
        GoRoute(
          path: 'genres',
          builder: (context, state) {
            final libraryId = state.pathParameters['libraryId']!;
            final serverId = state.uri.queryParameters['serverId'];
            return LibraryGenresScreen(libraryId: libraryId, serverId: serverId);
          },
        ),
        GoRoute(
          path: 'letters',
          builder: (context, state) {
            final libraryId = state.pathParameters['libraryId']!;
            return LibraryLettersScreen(libraryId: libraryId);
          },
        ),
        GoRoute(
          path: 'suggestions',
          builder: (context, state) {
            final libraryId = state.pathParameters['libraryId']!;
            return LibrarySuggestionsScreen(libraryId: libraryId);
          },
        ),
      ],
    ),
    GoRoute(
      path: Destinations.allGenres,
      builder: (context, state) => const AllGenresScreen(),
    ),
    GoRoute(
      path: Destinations.allFavorites,
      builder: (context, state) => const FavoritesScreen(),
    ),
    GoRoute(
      path: Destinations.folderView,
      builder: (context, state) => const FolderViewScreen(),
    ),
    GoRoute(
      path: Destinations.folderBrowse,
      builder: (context, state) {
        final folderId = state.pathParameters['folderId']!;
        final serverId = state.uri.queryParameters['serverId'];
        return FolderBrowseScreen(folderId: folderId, serverId: serverId);
      },
    ),
    GoRoute(
      path: Destinations.collectionBrowse,
      builder: (context, state) {
        final collectionId = state.pathParameters['collectionId']!;
        return CollectionScreen(collectionId: collectionId);
      },
    ),
    GoRoute(
      path: Destinations.musicBrowse,
      builder: (context, state) {
        final libraryId = state.pathParameters['libraryId']!;
        final serverId = state.uri.queryParameters['serverId'];
        return MusicBrowseScreen(libraryId: libraryId, serverId: serverId);
      },
    ),
    GoRoute(
      path: Destinations.bookBrowse,
      builder: (context, state) {
        final libraryId = state.pathParameters['libraryId']!;
        final collectionType = state.uri.queryParameters['collectionType'];
        return BookBrowseScreen(
          libraryId: libraryId,
          collectionType: collectionType,
        );
      },
    ),
    GoRoute(
      path: Destinations.studioBrowse,
      builder: (context, state) {
        final studioName = state.pathParameters['studioName']!;
        return LibraryBrowseScreen(libraryId: '', studioName: studioName);
      },
    ),
    GoRoute(
      path: Destinations.genreBrowse,
      builder: (context, state) {
        final genreName = state.pathParameters['genreName']!;
        final genreId = state.uri.queryParameters['genreId']!;
        final parentId = state.uri.queryParameters['parentId'];
        final includeType = state.uri.queryParameters['includeType'];
        return LibraryBrowseScreen(
          libraryId: parentId ?? '',
          genreId: genreId,
          genreName: Uri.decodeComponent(genreName),
          includeItemTypes: includeType != null ? [includeType] : null,
        );
      },
    ),

    // Item details
    GoRoute(
      path: Destinations.itemDetail,
      builder: (context, state) {
        final itemId = state.pathParameters['itemId']!;
        final serverId = state.uri.queryParameters['serverId'];
        final autoPlay = state.uri.queryParameters['autoPlay'] == 'true';
        final contextSeasonId = state.uri.queryParameters['seasonContext'];
        return ItemDetailScreen(
          key: ValueKey('$itemId|${contextSeasonId ?? ''}'),
          itemId: itemId,
          serverId: serverId,
          autoPlay: autoPlay,
          contextSeasonId: contextSeasonId,
        );
      },
      routes: [
        GoRoute(
          path: 'list',
          builder: (context, state) {
            final itemId = state.pathParameters['itemId']!;
            return ItemListScreen(itemId: itemId);
          },
        ),
      ],
    ),
    GoRoute(
      path: Destinations.musicFavorites,
      builder: (context, state) {
        final parentId = state.pathParameters['parentId']!;
        return MusicFavoritesScreen(parentId: parentId);
      },
    ),

    // Games
    GoRoute(
      path: Destinations.gameSystem,
      builder: (context, state) {
        final libraryId = state.pathParameters['libraryId']!;
        final systemId = state.pathParameters['systemId']!;
        return GameSystemScreen(
          key: ValueKey('game-system-$libraryId-$systemId'),
          libraryId: libraryId,
          systemId: systemId,
          systemName: state.uri.queryParameters['name'],
        );
      },
    ),
    GoRoute(
      path: Destinations.gameLibrary,
      builder: (context, state) {
        final libraryId = state.pathParameters['libraryId']!;
        return GameLibraryScreen(
          key: ValueKey('game-lib-$libraryId'),
          libraryId: libraryId,
          title: state.uri.queryParameters['title'],
        );
      },
    ),
    GoRoute(
      path: Destinations.gameDetail,
      builder: (context, state) {
        final libraryId = state.pathParameters['libraryId']!;
        final gameId = state.pathParameters['gameId']!;
        return GameDetailScreen(
          key: ValueKey('game-$gameId'),
          libraryId: libraryId,
          gameId: gameId,
        );
      },
    ),
    GoRoute(
      path: Destinations.gamePlayer,
      pageBuilder: (context, state) {
        final libraryId = state.pathParameters['libraryId']!;
        final gameId = state.pathParameters['gameId']!;
        final core = state.uri.queryParameters['core'] ?? 'nes';
        final startFresh = state.uri.queryParameters['fresh'] == '1';
        final forceEmulatorJs =
            state.uri.queryParameters['backend'] == 'emulatorjs';
        return _opaqueFullScreenPage<void>(
          state: state,
          // Native libretro or the EmulatorJS WebView: forced where only one
          // backend works (tvOS and Linux native), the user's choice elsewhere,
          // and per game where native can't play the system but the WebView can
          // (a PSP or N64 title on the bundled Apple targets).
          child: !forceEmulatorJs && usesNativeGameBackendFor(core)
              ? NativeGamePlayerScreen(
                  libraryId: libraryId,
                  gameId: gameId,
                  core: core,
                  gameName: state.uri.queryParameters['name'],
                  startFresh: startFresh,
                )
              : GameEmulatorScreen(
                  libraryId: libraryId,
                  gameId: gameId,
                  core: core,
                  romFileName: state.uri.queryParameters['romFile'],
                  biosId: state.uri.queryParameters['bios'],
                  gameName: state.uri.queryParameters['name'],
                  startFresh: startFresh,
                ),
        );
      },
    ),

    // Live TV
    GoRoute(
      path: Destinations.liveTv,
      builder: (context, state) => const LiveTvScreen(),
      routes: [
        GoRoute(
          path: 'guide',
          builder: (context, state) {
            final extra = state.extra;
            final extraMap = extra is Map<String, dynamic>
                ? extra
                : const <String, dynamic>{};
            // Embedded mode is the in-player "switch channel" overlay, which
            // has to stay on the server's own actually-playable Live TV
            // channels -- only the standalone Guide tile (no extra) becomes
            // the DStv guide.
            if (extraMap['miniPlayerMode'] == true) {
              return LiveTvGuideScreen(
                miniPlayerMode: true,
                currentChannel: extraMap['currentChannel'] as GuideChannel?,
              );
            }
            return const DstvGuideScreen();
          },
        ),
        GoRoute(
          path: 'schedule',
          builder: (context, state) => const DstvScheduleScreen(),
        ),
        GoRoute(
          path: 'recordings',
          builder: (context, state) => const LiveTvRecordingsScreen(),
        ),
        GoRoute(
          path: 'series-recordings',
          builder: (context, state) => const LiveTvSeriesRecordingsScreen(),
        ),
        GoRoute(
          path: 'player',
          pageBuilder: (context, state) {
            final extra = state.extra is Map<String, dynamic>
                ? state.extra as Map<String, dynamic>
                : const <String, dynamic>{};
            final channels = extra['channels'] as List<GuideChannel>?;
            final startIndex = extra['startIndex'] as int? ?? 0;
            final Widget child;
            if (channels != null) {
              child = PlatformDetection.isAppleTV
                  ? AppleTvLiveTvPlayerHostScreen(
                      channels: channels,
                      startIndex: startIndex,
                    )
                  : LiveTvPlayerScreen(
                      channels: channels,
                      startIndex: startIndex,
                    );
            } else {
              // Entered by channel id (favorites, search, deep links). The
              // loader resolves the lineup before showing the player.
              child = LiveTvChannelPlayerLoader(
                channelId: state.uri.queryParameters['channelId'] ?? '',
              );
            }
            return _opaqueFullScreenPage<void>(state: state, child: child);
          },
        ),
        GoRoute(
          path: 'iptv',
          // streamId/channelName arrive from the TV Guide's Play button and
          // from a tapped programme reminder; without them this is the ordinary
          // Live TV entry point.
          builder: (context, state) => VoltixLiveTvScreen(
            initialStreamId: state.uri.queryParameters['streamId'],
            initialChannelName: state.uri.queryParameters['channelName'],
          ),
        ),
      ],
    ),

    // Playback
    GoRoute(
      path: Destinations.videoPlayer,
      pageBuilder: (context, state) => _opaqueFullScreenPage<void>(
        state: state,
        child: PlatformDetection.isAppleTV
            ? const AppleTvPlayerHostScreen()
            : const VideoPlayerScreen(),
      ),
    ),
    GoRoute(
      path: Destinations.externalPlayer,
      pageBuilder: (context, state) => _opaqueFullScreenPage<void>(
        state: state,
        child: const ExternalPlayerHostScreen(),
      ),
    ),
    GoRoute(
      path: Destinations.audioPlayer,
      builder: (context, state) => const AudioPlayerScreen(),
    ),
    GoRoute(
      path: Destinations.bookReader,
      builder: (context, state) {
        final itemId = state.pathParameters['itemId']!;
        final serverId = state.uri.queryParameters['serverId'];
        final extra = state.extra as Map<String, dynamic>?;
        return BookReaderScreen(
          itemId: itemId,
          serverId: serverId,
          initialPosition: extra?['initialPosition'] as int?,
          initialMode: extra?['initialMode'] as String?,
        );
      },
    ),
    GoRoute(
      path: Destinations.photoPlayer,
      builder: (context, state) {
        final itemId = state.pathParameters['itemId']!;
        return PhotoPlayerScreen(itemId: itemId);
      },
    ),
    GoRoute(
      path: Destinations.trailerPlayer,
      builder: (context, state) {
        final videoId = state.uri.queryParameters['videoId'];
        final url = state.uri.queryParameters['url'];
        return TrailerPlayerScreen(videoId: videoId, trailerUrl: url);
      },
    ),
    GoRoute(
      path: Destinations.nextUp,
      builder: (context, state) {
        final itemId = state.pathParameters['itemId']!;
        return NextUpScreen(itemId: itemId);
      },
    ),
    GoRoute(
      path: Destinations.stillWatching,
      builder: (context, state) {
        final itemId = state.pathParameters['itemId']!;
        return StillWatchingScreen(itemId: itemId);
      },
    ),

    // Admin
    ShellRoute(
      builder: (context, state, child) => AdminShellScreen(child: child),
      routes: [
        GoRoute(
          path: Destinations.admin,
          builder: (context, state) => const AdminDashboardScreen(),
        ),
        GoRoute(
          path: Destinations.adminAnalytics,
          builder: (context, state) => const AdminContentAnalyticsScreen(),
        ),
        GoRoute(
          path: Destinations.adminUsers,
          builder: (context, state) => const AdminUsersScreen(),
        ),
        GoRoute(
          path: Destinations.adminUsersAdd,
          builder: (context, state) => const AdminUserAddScreen(),
        ),
        GoRoute(
          path: Destinations.adminUsersEdit,
          builder: (context, state) =>
              AdminUserEditScreen(userId: state.pathParameters['userId']!),
        ),
        GoRoute(
          path: Destinations.adminLibraries,
          builder: (context, state) => const AdminLibrariesScreen(),
        ),
        GoRoute(
          path: Destinations.adminLibrariesAdd,
          builder: (context, state) => const AdminLibraryAddScreen(),
        ),
        GoRoute(
          path: Destinations.adminLibrariesEdit,
          builder: (context, state) => AdminLibraryEditScreen(
            libraryId: state.pathParameters['libraryId']!,
          ),
        ),
        GoRoute(
          path: Destinations.adminSettings,
          builder: (context, state) => const AdminGeneralSettingsScreen(),
        ),
        GoRoute(
          path: Destinations.adminSettingsPlayback,
          builder: (context, state) => const AdminPlaybackSettingsScreen(),
        ),
        GoRoute(
          path: Destinations.adminSettingsResume,
          builder: (context, state) => const AdminResumeSettingsScreen(),
        ),
        GoRoute(
          path: Destinations.adminSettingsStreaming,
          builder: (context, state) => const AdminStreamingScreen(),
        ),
        GoRoute(
          path: Destinations.adminSettingsTrickplay,
          builder: (context, state) => const AdminTrickplayScreen(),
        ),
        GoRoute(
          path: Destinations.adminSettingsNetworking,
          builder: (context, state) => const AdminNetworkingScreen(),
        ),
        GoRoute(
          path: Destinations.adminSettingsBranding,
          builder: (context, state) => const AdminBrandingScreen(),
        ),
        GoRoute(
          path: Destinations.adminSettingsDisplay,
          builder: (context, state) => const AdminLibraryDisplayScreen(),
        ),
        GoRoute(
          path: Destinations.adminSettingsMetadata,
          builder: (context, state) => const AdminLibraryMetadataScreen(),
        ),
        GoRoute(
          path: Destinations.adminSettingsNfo,
          builder: (context, state) => const AdminLibraryNfoScreen(),
        ),
        GoRoute(
          path: Destinations.adminTasks,
          builder: (context, state) => const AdminTasksScreen(),
        ),
        GoRoute(
          path: Destinations.adminTasksDetail,
          builder: (context, state) =>
              AdminTaskDetailScreen(taskId: state.pathParameters['taskId']!),
        ),
        GoRoute(
          path: Destinations.adminPlugins,
          builder: (context, state) => const AdminPluginsScreen(),
        ),
        GoRoute(
          path: Destinations.adminPluginsDetail,
          builder: (context, state) => AdminPluginDetailScreen(
            pluginId: state.pathParameters['pluginId']!,
          ),
        ),
        GoRoute(
          path: Destinations.adminRepositories,
          builder: (context, state) => const AdminRepositoriesScreen(),
        ),
        GoRoute(
          path: Destinations.adminActivity,
          builder: (context, state) => const AdminActivityScreen(),
        ),
        GoRoute(
          path: Destinations.adminDevices,
          builder: (context, state) => const AdminDevicesScreen(),
        ),
        GoRoute(
          path: Destinations.adminKeys,
          builder: (context, state) => const AdminApiKeysScreen(),
        ),
        GoRoute(
          path: Destinations.adminBackups,
          builder: (context, state) => const AdminBackupsScreen(),
        ),
        GoRoute(
          path: Destinations.adminLogs,
          builder: (context, state) => const AdminLogsScreen(),
        ),
        GoRoute(
          path: Destinations.adminLogsFile,
          builder: (context, state) => AdminLogViewerScreen(
            fileName: Uri.decodeComponent(state.pathParameters['fileName']!),
          ),
        ),
        GoRoute(
          path: Destinations.adminLiveTv,
          builder: (context, state) => const AdminLiveTvScreen(),
        ),
        GoRoute(
          path: Destinations.adminMetadataEdit,
          builder: (context, state) =>
              AdminMetadataEditScreen(itemId: state.pathParameters['itemId']!),
        ),
      ],
    ),

    // Notifications
    GoRoute(
      path: Destinations.notifications,
      builder: (context, state) => const NotificationsScreen(),
    ),

    // Settings
    GoRoute(
      path: Destinations.settings,
      builder: (context, state) => const SettingsSidePanel(),
    ),

    // Seerr
    GoRoute(
      path: Destinations.seerrDiscover,
      builder: (context, state) => const SeerrDiscoverScreen(),
    ),
    GoRoute(
      path: Destinations.seerrRequests,
      builder: (context, state) => const SeerrRequestsScreen(),
    ),
    GoRoute(
      path: Destinations.seerrBrowse,
      builder: (context, state) {
        final params = state.uri.queryParameters;
        return SeerrBrowseScreen(
          filterId: params['filterId'],
          filterName: params['filterName'],
          mediaType: params['mediaType'],
          filterType: params['filterType'],
        );
      },
    ),
    GoRoute(
      path: Destinations.seerrMediaDetail,
      builder: (context, state) {
        final tmdbId = state.pathParameters['itemId']!;
        final kind = state.uri.queryParameters['mediaType'] == 'tv'
            ? TmdbItemKind.tv
            : TmdbItemKind.movie;
        final ref = TmdbItemRef(kind, tmdbId);
        return ItemDetailScreen(
          key: ValueKey(ref.itemId),
          itemId: ref.itemId,
          seerrTitle: state.uri.queryParameters['title'],
        );
      },
    ),
    GoRoute(
      path: Destinations.seerrCollectionDetail,
      builder: (context, state) {
        final collectionId = state.pathParameters['collectionId']!;
        return SeerrCollectionScreen(collectionId: collectionId);
      },
    ),
    GoRoute(
      path: Destinations.seerrPersonDetail,
      builder: (context, state) {
        final personId = state.pathParameters['personId']!;
        // Always SeerrPersonScreen here, regardless of the Modern/Classic
        // detail screen preference. Routing this through ItemDetailScreen
        // with itemId 'tmdb:$personId' used to fall through to
        // ItemDetailViewModel's _client.itemsApi.getItem(itemId, ...) --
        // the JELLYFIN item-by-id lookup -- with a non-GUID 'tmdb:...'
        // string, which the media server correctly rejects with HTTP 400.
        // (See the comment in ItemDetailViewModel.load: this fork's
        // server_core has no itemsApi.getPersons, so there is no working
        // "modern" path for a Seerr-only person -- SeerrPersonScreen, which
        // calls Seerr's own /person/{id} API, is the only one that works.)
        return SeerrPersonScreen(personId: personId);
      },
    ),

    // Downloads / Saved Media
    GoRoute(
      path: Destinations.downloads,
      builder: (context, state) => const SavedMediaScreen(),
      routes: [
        GoRoute(
          path: 'music/:albumId',
          builder: (context, state) => SavedAlbumScreen(
            albumId: state.pathParameters['albumId']!,
            albumName: state.uri.queryParameters['name'],
          ),
        ),
        GoRoute(
          path: 'series/:seriesId',
          builder: (context, state) =>
              SavedSeriesScreen(seriesId: state.pathParameters['seriesId']!),
          routes: [
            GoRoute(
              path: 'season/:seasonId',
              builder: (context, state) => SavedSeasonScreen(
                seasonId: state.pathParameters['seasonId']!,
              ),
            ),
          ],
        ),
      ],
    ),
    GoRoute(
      path: Destinations.storageManagement,
      builder: (context, state) => const StorageManagementScreen(),
    ),
  ],
);

class PlayerRouteObserver extends NavigatorObserver {
  static final instance = PlayerRouteObserver();
  final ValueNotifier<bool> isPlayerActive = ValueNotifier<bool>(false);
  final List<Route<dynamic>> _playerRoutes = [];

  bool _isPlayer(Route<dynamic> route) {
    final name = route.settings.name;
    return name != null &&
        (name.startsWith('/player/') ||
         name.startsWith('/game-player/') ||
         name == '/live-tv/player' ||
         name == Destinations.audioPlayer ||
         name == Destinations.videoPlayer);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isPlayer(route)) {
      _playerRoutes.add(route);
      isPlayerActive.value = true;
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isPlayer(route)) {
      _playerRoutes.remove(route);
      isPlayerActive.value = _playerRoutes.isNotEmpty;
    }
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (_isPlayer(route)) {
      _playerRoutes.remove(route);
      isPlayerActive.value = _playerRoutes.isNotEmpty;
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null && _isPlayer(oldRoute)) {
      _playerRoutes.remove(oldRoute);
    }
    if (newRoute != null && _isPlayer(newRoute)) {
      _playerRoutes.add(newRoute);
    }
    isPlayerActive.value = _playerRoutes.isNotEmpty;
  }
}

/// Drives the one global artwork coverage blocker from the effective top route.
/// Hidden game screens never clear the blocker themselves, so popping or
/// disposing a lower screen cannot reopen artwork work under gameplay/dialogs.
class RetroArtworkRouteObserver extends NavigatorObserver {
  RetroArtworkRouteObserver({RetroArtworkActivityGate? activityGate})
    : _activityGate = activityGate;

  static final instance = RetroArtworkRouteObserver();

  final RetroArtworkActivityGate? _activityGate;
  final List<Route<dynamic>> _routes = <Route<dynamic>>[];

  RetroArtworkActivityGate? get _gate {
    if (_activityGate != null) return _activityGate;
    if (!GetIt.instance.isRegistered<RetroArtworkActivityGate>()) return null;
    return GetIt.instance<RetroArtworkActivityGate>();
  }

  bool _isArtworkRoute(Route<dynamic>? route) {
    final name = route?.settings.name;
    return name != null &&
        (name.startsWith('/games/') || name.startsWith('/game/'));
  }

  /// Non-opaque routes (dialogs, popups, bottom sheets -- e.g. the "Choose
  /// player" picker) sit on top of the screen beneath without hiding it, so
  /// they must not flip coverage themselves. Only an opaque route (a real
  /// page navigation, including into gameplay) actually covers the artwork
  /// screen.
  bool _isOpaque(Route<dynamic> route) =>
      route is! ModalRoute<dynamic> || route.opaque;

  void _sync() {
    Route<dynamic>? topmostOpaque;
    for (final route in _routes.reversed) {
      if (_isOpaque(route)) {
        topmostOpaque = route;
        break;
      }
    }
    _gate?.setRouteCovered(
      topmostOpaque == null || !_isArtworkRoute(topmostOpaque),
      owner: this,
    );
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    _sync();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _sync();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _sync();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final oldIndex = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (oldIndex >= 0) {
      if (newRoute == null) {
        _routes.removeAt(oldIndex);
      } else {
        _routes[oldIndex] = newRoute;
      }
    } else if (newRoute != null) {
      _routes.add(newRoute);
    }
    _sync();
  }
}

