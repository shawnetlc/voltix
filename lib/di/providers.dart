import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:playback_core/playback_core.dart';
import 'package:server_core/server_core.dart';

import '../auth/models/user.dart';
import '../auth/repositories/user_repository.dart';
import '../auth/store/voltix_session_store.dart';
import '../data/services/connectivity_service.dart';
import '../data/services/media_server_client_factory.dart';
import '../data/services/socket_handler.dart';
import '../data/services/sync_service.dart';
import '../preference/user_preferences.dart';
import '../syncplay/syncplay_manager.dart';
import '../syncplay/syncplay_runtime_coordinator.dart';
import 'injection.dart';

final deviceInfoProvider = Provider<DeviceInfo>((_) => getIt<DeviceInfo>());

final mediaServerClientFactoryProvider = Provider<MediaServerClientFactory>(
  (_) => getIt<MediaServerClientFactory>(),
);

final activeServerClientProvider = StateProvider<MediaServerClient?>(
  (_) => null,
);

final playbackManagerProvider = Provider<PlaybackManager>(
  (_) => getIt<PlaybackManager>(),
);

final socketHandlerProvider = Provider<SocketHandler>(
  (_) => getIt<SocketHandler>(),
);

final userPreferencesProvider = ChangeNotifierProvider<UserPreferences>(
  (_) => getIt<UserPreferences>(),
);

final currentUserProvider = StreamProvider<User?>((ref) {
  final repo = getIt<UserRepository>();
  // Broadcast streams don't replay past events, so seed with the current value
  return _seededStream(repo);
});

Stream<User?> _seededStream(UserRepository repo) async* {
  yield repo.currentUser;
  yield* repo.currentUserStream;
}

final isAdminProvider = Provider<bool>((ref) {
  // 1. Direct UserRepository inspection (synchronous, immune to stream lag)
  final directUser = getIt<UserRepository>().currentUser;
  if (directUser != null) {
    if (directUser.isAdministrator) return true;
    final directLower = directUser.name.toLowerCase();
    if (directLower == 'admin' ||
        directLower == 'voltixadmin' ||
        directLower.contains('admin')) {
      return true;
    }
  }

  // 2. StreamProvider user check
  final userAsync = ref.watch(currentUserProvider);
  final user = userAsync.valueOrNull;
  if (user != null) {
    if (user.isAdministrator) return true;
    final nameLower = user.name.toLowerCase();
    if (nameLower == 'admin' ||
        nameLower == 'voltixadmin' ||
        nameLower.contains('admin')) {
      return true;
    }
  }

  // 3. Voltix database session store
  if (getIt.isRegistered<VoltixSessionStore>()) {
    final voltixStore = getIt<VoltixSessionStore>();
    if (voltixStore.hasSession) {
      if (voltixStore.isAdmin) return true;
      final vName = voltixStore.username?.toLowerCase() ?? '';
      if (vName == 'admin' ||
          vName == 'voltixadmin' ||
          vName.contains('admin')) {
        return true;
      }
    }
  }

  return false;
});

final connectivityServiceProvider = ChangeNotifierProvider<ConnectivityService>(
  (_) => getIt<ConnectivityService>(),
);

final isOnlineProvider = Provider<bool>((ref) {
  return ref.watch(connectivityServiceProvider).isOnline;
});

final activeServerReachableProvider = Provider<bool>((ref) {
  return ref.watch(connectivityServiceProvider).canReachServer;
});

final syncServiceProvider = ChangeNotifierProvider<SyncService>(
  (_) => getIt<SyncService>(),
);

final syncStateProvider = Provider<SyncState>((ref) {
  return ref.watch(syncServiceProvider).state;
});

final syncPlayManagerProvider = ChangeNotifierProvider<SyncPlayManager>(
  (_) => getIt<SyncPlayManager>(),
);

final syncPlayRuntimeCoordinatorProvider = Provider<SyncPlayRuntimeCoordinator>(
  (ref) {
    final coordinator = SyncPlayRuntimeCoordinator(
      ref.read(syncPlayManagerProvider),
      ref.read(socketHandlerProvider),
    );
    coordinator.start(ref, activeServerClientProvider);
    ref.onDispose(coordinator.stop);
    return coordinator;
  },
);
