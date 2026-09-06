import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:playback_core/playback_core.dart';
import 'package:server_core/server_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../auth/repositories/session_repository.dart';
import '../../auth/store/authentication_store.dart';
import '../../auth/store/credential_store.dart';
import '../../data/repositories/dstv_epg_repository.dart';
import '../../data/repositories/mdblist_repository.dart';
import '../../data/repositories/multi_server_repository.dart';
import '../../data/repositories/media_bar_repository.dart';
import '../../data/repositories/offline_repository.dart';
import '../../data/services/media_server_client_factory.dart';
import '../../data/repositories/seerr_repository.dart';
import '../../data/repositories/taste_profile_repository.dart';
import '../../data/services/taste_profile/taste_row_builder.dart';
import '../../data/repositories/tmdb_repository.dart';
import '../../data/repositories/user_views_repository.dart';
import '../../data/repositories/search_repository.dart';
import '../../data/repositories/item_mutation_repository.dart';
import '../../data/services/background_service.dart';
import '../../data/services/app_update_service.dart';
import '../../data/services/user_settings_sync_service.dart';
import '../../data/services/cast/airplay_provider.dart';
import '../../data/services/cast/airplay_command_bridge.dart';
import '../../data/services/cast/cast_service.dart';
import '../../data/services/cast/dlna_provider.dart';
import '../../data/services/cast/native_airplay_channel.dart';
import '../../data/services/cast/native_dlna_channel.dart';
import '../../data/services/cast/google_cast_provider.dart';
import '../../data/services/cast/native_cast_channel.dart';
import '../../data/services/cast/remote_session_cast_provider.dart';
import '../../data/services/home_screen_sections_service.dart';
import '../../data/services/plugin_sync_service.dart';
import '../../data/services/custom_external_lists_service.dart';
import '../../data/services/row_data_source.dart';
import '../../data/services/seerr/seerr_cookie_jar.dart';
import '../../data/services/socket_handler.dart';
import '../../data/services/sync_service.dart';
import '../../data/services/theme_music_service.dart';
import '../../data/services/voltix_watch_registry_service.dart';
import '../../data/viewmodels/media_bar_view_model.dart';
import '../../data/viewmodels/seerr_discover_view_model.dart';
import '../../playback/external_player_service.dart';
import '../../preference/seerr_preferences.dart';
import '../../preference/user_preferences.dart';
import '../../ui/screensaver/screensaver_controller.dart';
import '../../ui/screens/home/home_view_model.dart';
import '../../ui/screens/setup/setup_wizard_gate.dart';

final _getIt = GetIt.instance;

void resetUserScopedSingletons() {
  void unregister<T extends Object>() {
    if (_getIt.isRegistered<T>()) {
      _getIt.unregister<T>();
    }
  }

  // Recommendation candidate pools are memoised per server for the session;
  // a different user must not inherit them.
  RowDataSource.clearRecommendationCache();

  unregister<SeerrDiscoverViewModel>();
  unregister<SeerrRepository>();
  unregister<HomeViewModel>();
  unregister<MediaBarViewModel>();
  unregister<HomeScreenSectionsService>();
  unregister<MultiServerRepository>();
  unregister<ThemeMusicService>();
  unregister<MediaBarRepository>();
  unregister<TmdbRepository>();
  unregister<MdbListRepository>();
  unregister<RowDataSource>();
  unregister<ItemMutationRepository>();
  unregister<SearchRepository>();
  unregister<UserViewsRepository>();
  unregister<VoltixWatchRegistryService>();
  // Registered in _registerUserScopedSingletons below; missing here meant a
  // second sign-in in the same app session (switch user, log out/in again,
  // link a device after already being signed in) hit registerLazySingleton
  // for a type GetIt still had from the first login and threw "already
  // registered" instead of ever reaching the home screen.
  unregister<TasteRowBuilder>();
  unregister<TasteProfileRepository>();

  _registerUserScopedSingletons();
}

void registerAppModule() {
  _getIt.registerLazySingletonAsync(
    () async => SeerrCookieJar(await SharedPreferences.getInstance()),
  );
  _getIt.registerLazySingleton(() => SocketHandler());
  _getIt.registerLazySingleton(
    () => BackgroundService(),
    dispose: (service) => service.dispose(),
  );
  _getIt.registerLazySingleton(
    () =>
        AppUpdateService(_getIt<PreferenceStore>(), _getIt<UserPreferences>()),
  );
  _getIt.registerLazySingleton(() => UserSettingsSyncService());
  _getIt.registerLazySingleton(
    () => ScreensaverController(_getIt<UserPreferences>(), _getIt<PlaybackManager>()),
    dispose: (controller) => controller.dispose(),
  );
  _getIt.registerLazySingleton(() => SetupWizardGate(_getIt<UserPreferences>()));
  _getIt.registerLazySingleton(() => const NativeCastChannel());
  _getIt.registerLazySingleton(() => const NativeDlnaChannel());
  _getIt.registerLazySingleton(() => const NativeAirPlayChannel());
  _getIt.registerLazySingleton(
    () => AirPlayCommandBridge(
      _getIt<NativeAirPlayChannel>(),
      _getIt<PlaybackManager>(),
    ),
    dispose: (bridge) => bridge.dispose(),
  );
  _getIt.registerLazySingleton(
    () => CastService(
      [
        RemoteSessionCastProvider(_getIt<MediaServerClientFactory>()),
        GoogleCastProvider(
          _getIt<NativeCastChannel>(),
          _getIt<MediaServerClientFactory>(),
        ),
        AirPlayProvider(
          _getIt<NativeCastChannel>(),
          _getIt<NativeAirPlayChannel>(),
          _getIt<MediaServerClientFactory>(),
        ),
        DlnaProvider(
          _getIt<NativeDlnaChannel>(),
          _getIt<MediaServerClientFactory>(),
        ),
      ],
      nativeCast: _getIt<NativeCastChannel>(),
      nativeDlna: _getIt<NativeDlnaChannel>(),
      nativeAirPlay: _getIt<NativeAirPlayChannel>(),
    ),
    dispose: (service) => service.dispose(),
  );
  _getIt.registerLazySingleton(
    () => PluginSyncService(_getIt<UserPreferences>(), _getIt()),
  );
  _getIt.registerLazySingleton(() => CustomExternalListsService());
  _getIt.registerLazySingleton(
    () => SeerrPreferences(
      _getIt<PreferenceStore>(),
      _getIt<SessionRepository>(),
    ),
  );
  _getIt.registerLazySingleton<SyncService>(
    () => SyncService(_getIt<OfflineRepository>()),
  );
  _getIt.registerLazySingleton(() => const ExternalPlayerService());
  // Public DStv guide data, unrelated to which server/user is signed
  // in -- registered once here rather than per-session like the
  // user-scoped singletons below.
  _getIt.registerLazySingleton(
    () => DstvEpgRepository(),
    dispose: (repository) => repository.dispose(),
  );

  _registerUserScopedSingletons();
}

void _registerUserScopedSingletons() {
  _getIt.registerLazySingleton(() => VoltixWatchRegistryService());
  // Never registered even though the Settings screen and the setup wizard's
  // taste-onboarding step both call GetIt.instance<TasteProfileRepository>()
  // directly in a field initializer -- with nothing registered that throws
  // immediately on construction, before the screen ever gets to build a
  // Scaffold, which is what showed up as a blank white page rather than a
  // visible error. Every other dependency below PreferenceStore/
  // MediaServerClient is optional and self-constructs inside
  // TasteProfileRepository's own constructor, so this is the whole fix.
  _getIt.registerLazySingleton(
    () => TasteProfileRepository(
      _getIt<PreferenceStore>(),
      _getIt<MediaServerClient>(),
    ),
    dispose: (repository) => repository.dispose(),
  );

  // Not a second instance: this hands out the builder the repository already
  // owns, so RowDataSource can reach it without importing the repository and
  // creating an import cycle, and without a second TasteServerContext that
  // could drift from the first on a session switch.
  _getIt.registerLazySingleton<TasteRowBuilder>(
    () => _getIt<TasteProfileRepository>().rowBuilder,
  );
  _getIt.registerLazySingleton(
    () => MultiServerRepository(
      _getIt<AuthenticationStore>(),
      _getIt<CredentialStore>(),
      _getIt<MediaServerClientFactory>(),
      _getIt<SessionRepository>(),
    ),
  );
  _getIt.registerLazySingleton(
    () => HomeScreenSectionsService(_getIt<MultiServerRepository>()),
    dispose: (s) => s.dispose(),
  );
  _getIt.registerLazySingleton(
    () => UserViewsRepository(_getIt()),
    dispose: (repository) => repository.dispose(),
  );
  _getIt.registerLazySingleton(() => SearchRepository(_getIt()));
  _getIt.registerLazySingleton(() => ItemMutationRepository(_getIt()));
  _getIt.registerLazySingleton(
    () => RowDataSource(_getIt<MediaServerClient>()),
  );
  _getIt.registerLazySingleton(
    () => MdbListRepository(_getIt<MediaServerClient>()),
    dispose: (repository) => repository.dispose(),
  );
  _getIt.registerLazySingleton(
    () => TmdbRepository(_getIt<MediaServerClient>()),
    dispose: (repository) => repository.dispose(),
  );
  _getIt.registerLazySingleton(
    () => MediaBarRepository(
      _getIt<MediaServerClient>(),
      _getIt<UserPreferences>(),
    ),
  );
  _getIt.registerLazySingleton(
    () => MediaBarViewModel(
      _getIt<MediaBarRepository>(),
      _getIt<MdbListRepository>(),
      _getIt<UserPreferences>(),
      _getIt<MediaServerClient>(),
    ),
  );
  _getIt.registerLazySingleton(
    () => HomeViewModel(
      dataSource: _getIt<RowDataSource>(),
      prefs: _getIt<UserPreferences>(),
      client: _getIt<MediaServerClient>(),
      mediaBarViewModel: _getIt<MediaBarViewModel>(),
      multiServerRepo: _getIt<MultiServerRepository>(),
    ),
  );
  _getIt.registerLazySingleton(
    () => ThemeMusicService(
      _getIt<MediaServerClient>(),
      _getIt<UserPreferences>(),
      _getIt<PlaybackManager>(),
    ),
  );
  _getIt.registerLazySingletonAsync<SeerrRepository>(
    () async => SeerrRepository(
      _getIt<PreferenceStore>(),
      _getIt<SessionRepository>(),
      await _getIt.getAsync<SeerrCookieJar>(),
      _getIt<MediaServerClient>(),
    ),
  );
  _getIt.registerLazySingletonAsync<SeerrDiscoverViewModel>(
    () async => SeerrDiscoverViewModel(
      await _getIt.getAsync<SeerrRepository>(),
      _getIt<SeerrPreferences>(),
    ),
  );
}
