import 'package:get_it/get_it.dart';
import 'package:server_core/server_core.dart';

import '../../data/services/download_notification_service.dart';
import '../../data/services/download_service.dart';
import '../../data/services/media_server_client_factory.dart';
import '../../data/services/background_download_coordinator.dart';
import '../../data/services/seerr_notification_service.dart';
import '../../data/services/storage_path_service.dart';
import '../../data/offline/connectivity_aware_media_server_client.dart';
import '../../data/offline/offline_catalog.dart';
import '../../playback/server_transcode_capabilities.dart';

final _getIt = GetIt.instance;

void registerServerModule() {
  _getIt.registerLazySingleton<MediaServerClientFactory>(
    () => MediaServerClientFactory(
      deviceInfo: _getIt<DeviceInfo>(),
    ),
  );

  if (!_getIt.isRegistered<DownloadNotificationService>()) {
    _getIt.registerLazySingleton<DownloadNotificationService>(
      () => DownloadNotificationService(),
    );
  }

  // App-lifetime: owns the background_downloader singleton across server
  // switches, while DownloadService instances attach/detach to it.
  if (!_getIt.isRegistered<BackgroundDownloadCoordinator>()) {
    _getIt.registerLazySingleton<BackgroundDownloadCoordinator>(
      () => BackgroundDownloadCoordinator(),
    );
  }

  if (!_getIt.isRegistered<SeerrNotificationService>()) {
    _getIt.registerLazySingleton<SeerrNotificationService>(
      () => SeerrNotificationService(),
    );
  }

  if (!_getIt.isRegistered<ServerTranscodeCapabilities>()) {
    _getIt.registerLazySingleton<ServerTranscodeCapabilities>(
      () => ServerTranscodeCapabilities(),
    );
  }
}

void setActiveServerClient(MediaServerClient client) {
  final rawClient = client is ConnectivityAwareMediaServerClient
      ? client.onlineClient
      : client;
  final wrapped = ConnectivityAwareMediaServerClient(
    rawClient,
    useOffline: shouldUseOfflineCatalog,
    catalog: _getIt<OfflineCatalog>(),
    storagePath: _getIt<StoragePathService>(),
  );

  if (_getIt.isRegistered<MediaServerClient>()) {
    _getIt.unregister<MediaServerClient>();
  }
  _getIt.registerSingleton<MediaServerClient>(wrapped);

  if (_getIt.isRegistered<DownloadService>()) {
    _getIt.unregister<DownloadService>();
  }
  final downloadService = DownloadService(
    rawClient,
    _getIt<DownloadNotificationService>(),
  );
  _getIt.registerSingleton<DownloadService>(downloadService);

  downloadService.recoverIncompleteDownloads();

  _getIt<ServerTranscodeCapabilities>().refresh(rawClient);
}
