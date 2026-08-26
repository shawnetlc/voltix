import 'package:get_it/get_it.dart';
import 'package:server_core/server_core.dart';
import 'package:server_jellyfin/server_jellyfin.dart';
import 'package:server_emby/server_emby.dart';

import '../../util/server_url.dart';
import '../offline/connectivity_aware_media_server_client.dart';
import '../offline/offline_catalog.dart';
import 'storage_path_service.dart';

class MediaServerClientFactory {
  final DeviceInfo deviceInfo;
  final Map<String, MediaServerClient> _clients = {};

  /// Server id of the session the user is currently signed in to.
  ///
  /// Kept explicitly rather than inferred from insertion order. [getActiveClient]
  /// used to return `_clients.values.last`, i.e. the most recently *created*
  /// client, which is not the active one as soon as a second server is logged in
  /// and the user switches back to the first. SyncPlay reads the active client to
  /// decide which server to send group calls to, so that mismatch silently
  /// addressed the wrong Jellyfin and no one ever joined.
  String? _activeServerId;

  MediaServerClientFactory({required this.deviceInfo});

  Map<String, MediaServerClient> get clients => Map.unmodifiable(_clients);

  String? get activeServerId => _activeServerId;

  /// Records which server is active. Called by SessionRepository whenever the
  /// session changes, including the Voltix-only stub session.
  void setActiveServerId(String? serverId) {
    _activeServerId = serverId;
  }

  /// The server id a client is registered under, or null if it is not ours.
  String? serverIdForClient(MediaServerClient client) {
    for (final entry in _clients.entries) {
      if (identical(entry.value, client)) return entry.key;
    }
    final normalized = normalizeServerBaseUrl(client.baseUrl);
    for (final entry in _clients.entries) {
      if (normalizeServerBaseUrl(entry.value.baseUrl) == normalized) {
        return entry.key;
      }
    }
    return null;
  }

  /// Like [getActiveClient] but null instead of throwing when nothing is signed in.
  MediaServerClient? get activeClientOrNull {
    if (_clients.isEmpty) return null;
    final id = _activeServerId;
    if (id != null) {
      final client = _clients[id];
      if (client != null) return client;
    }
    return _clients.values.last;
  }

  MediaServerClient getClient({
    required String serverId,
    required ServerType serverType,
    required String baseUrl,
  }) {
    final normalizedBaseUrl = normalizeServerBaseUrl(baseUrl);
    return _clients.putIfAbsent(serverId, () {
      return _createClient(
        serverType: serverType,
        baseUrl: normalizedBaseUrl,
      );
    });
  }

  MediaServerClient? getClientIfExists(String serverId) {
    final client = _clients[serverId];
    if (client != null) return client;

    if (serverId.contains('://')) {
      final normalizedInput = normalizeServerBaseUrl(serverId);
      if (normalizedInput.isNotEmpty) {
        for (final activeClient in _clients.values) {
          if (normalizeServerBaseUrl(activeClient.baseUrl) == normalizedInput) {
            return activeClient;
          }
        }
      }
    }
    return null;
  }

  MediaServerClient getActiveClient() {
    final client = activeClientOrNull;
    if (client == null) throw StateError('No active server clients');
    return client;
  }

  MediaServerClient _createClient({
    required ServerType serverType,
    required String baseUrl,
  }) {
    final raw = _createRawClient(serverType: serverType, baseUrl: baseUrl);
    final getIt = GetIt.instance;
    // Background isolates skip the offline stack.
    if (!getIt.isRegistered<OfflineCatalog>() ||
        !getIt.isRegistered<StoragePathService>()) {
      return raw;
    }
    return ConnectivityAwareMediaServerClient(
      raw,
      useOffline: shouldUseOfflineCatalog,
      catalog: getIt<OfflineCatalog>(),
      storagePath: getIt<StoragePathService>(),
    );
  }

  MediaServerClient _createRawClient({
    required ServerType serverType,
    required String baseUrl,
  }) {
    switch (serverType) {
      case ServerType.jellyfin:
        return JellyfinMediaServerClient(
          baseUrl: baseUrl,
          deviceInfo: deviceInfo,
        );
      case ServerType.emby:
        return EmbyMediaServerClient(
          baseUrl: baseUrl,
          deviceInfo: deviceInfo,
        );
    }
  }

  void removeClient(String serverId) {
    _clients.remove(serverId)?.dispose();
    if (_activeServerId == serverId) _activeServerId = null;
  }

  void disposeAll() {
    for (final client in _clients.values) {
      client.dispose();
    }
    _clients.clear();
    _activeServerId = null;
  }
}
