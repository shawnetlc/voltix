import 'dart:async';

import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../auth/models/server.dart';
import '../../auth/models/user.dart';
import '../../auth/repositories/server_repository.dart';
import '../../auth/store/authentication_store.dart';
import '../../util/server_url.dart';
import 'media_server_client_factory.dart';
import 'voltix_api_service.dart';

/// A Lumistream server the app is signed in to directly.
class DirectConnection {
  final Server server;
  final PrivateUser user;
  const DirectConnection(this.server, this.user);

  /// The same shape as a Jellyfin AuthenticateByName response, so the sign-in
  /// screens can treat a direct connection like any other login result.
  Map<String, dynamic> toAuthResult() => {
        'AccessToken': user.accessToken,
        'User': {
          'Id': user.id,
          'Name': user.name,
          'PrimaryImageTag': user.imageTag,
          'Policy': {
            'IsAdministrator': user.isAdministrator,
            'EnableContentDownloading': user.canDownload,
            'EnableSubtitleManagement': user.canManageSubtitles,
            'EnableCollectionManagement': user.canManageCollections,
          },
        },
        'UserId': user.id,
      };
}

/// Direct streaming: the app logs in to Lumistream itself with the login the
/// Voltix backend assigns, so library, image and playback traffic comes from
/// the viewer's own IP instead of going through the Voltix server.
///
/// The Lumistream password is only held in memory during sign-in; what is kept
/// on the device is the Lumistream access token, exactly as for any server.
///
/// Falls back to the proxy whenever the backend offers no direct logins
/// (switched off with DIRECT_STREAMING_ENABLED=false, nothing assigned, or the
/// request failed), and cleans up the other mode's server entries so a library
/// never appears twice.
class VoltixDirectStreaming {
  VoltixDirectStreaming._();

  static final Logger _logger = Logger();
  static const _prefsKey = 'voltix_direct_server_addresses';

  /// Signs in to every server the backend offers directly. Returns the
  /// connections keyed by Voltix server id; empty means "use the proxy".
  static Future<Map<int, DirectConnection>> connect({
    required VoltixApiService api,
    required String sessionToken,
    required List<VoltixServer> voltixServers,
    required ServerRepository serverRepo,
    required AuthenticationStore authStore,
    required MediaServerClientFactory clientFactory,
    required String voltixUsername,
    bool isVoltixAdmin = false,
  }) async {
    final creds = await api
        .getDirectCredentials(sessionToken)
        .timeout(const Duration(seconds: 15), onTimeout: () => const []);
    if (creds.isEmpty) {
      await _removeDirectServers(serverRepo);
      return const {};
    }

    final out = <int, DirectConnection>{};
    await Future.wait(creds.map((c) async {
      try {
        final connection = await _connectOne(
          c,
          serverRepo: serverRepo,
          authStore: authStore,
          clientFactory: clientFactory,
          voltixUsername: voltixUsername,
          isVoltixAdmin: isVoltixAdmin,
        ).timeout(const Duration(seconds: 25));
        if (connection != null) out[c.voltixServerId] = connection;
      } catch (e) {
        _logger.w('[DirectStreaming] ${c.displayName}: direct sign-in failed: $e');
      }
    }));

    if (out.isEmpty) {
      // Every direct sign-in failed (e.g. the viewer's network can't reach
      // Lumistream): leave the proxy entries alone so the proxy keeps working.
      return const {};
    }

    // The proxy entries for these servers would list the same library a second
    // time, so remove them. Servers that failed directly keep their proxy entry.
    for (final vs in voltixServers.where((v) => out.containsKey(v.id))) {
      final proxyAddress =
          normalizeServerBaseUrl(vs.absoluteProxyUrl(api.baseUrl));
      final stale =
          serverRepo.servers.where((s) => s.address == proxyAddress).toList();
      for (final s in stale) {
        await serverRepo.deleteServer(s.id);
      }
    }
    await _rememberDirectServers(
      out.values.map((c) => c.server.address).toList(),
    );
    _logger.i('[DirectStreaming] Connected directly to ${out.length} server(s)');
    return out;
  }

  static Future<DirectConnection?> _connectOne(
    DirectServerCredentials c, {
    required ServerRepository serverRepo,
    required AuthenticationStore authStore,
    required MediaServerClientFactory clientFactory,
    required String voltixUsername,
    required bool isVoltixAdmin,
  }) async {
    final address = normalizeServerBaseUrl(c.url);
    Server? server = serverRepo.servers
        .where((s) => s.address == address)
        .cast<Server?>()
        .firstWhere((_) => true, orElse: () => null);
    server ??= await serverRepo.addServer(address);
    if (server == null) return null;

    // Keep the Voltix name: library artwork, shared-server handling and the
    // server picker all key off "Voltix Primary / Extra / 4K".
    if (server.name != c.displayName) {
      server = server.copyWith(name: c.displayName);
      await serverRepo.updateServer(server);
    }

    final client = clientFactory.getClient(
      serverId: server.id,
      serverType: server.serverType,
      baseUrl: server.address,
    );

    // Reuse the stored Lumistream token while it is still accepted, so every
    // app start doesn't open a new session on Lumistream.
    final stored = authStore.getUsers(server.id);
    for (final u in stored) {
      if (u.accessToken.isEmpty) continue;
      try {
        client.accessToken = u.accessToken;
        client.userId = u.id;
        await client.usersApi
            .getCurrentUser()
            .timeout(const Duration(seconds: 8));
        final refreshed = PrivateUser(
          id: u.id,
          name: voltixUsername,
          serverId: server.id,
          accessToken: u.accessToken,
          lastUsed: DateTime.now(),
          imageTag: u.imageTag,
          isAdministrator: u.isAdministrator || isVoltixAdmin,
          canDownload: u.canDownload,
          canManageSubtitles: u.canManageSubtitles,
          canManageCollections: u.canManageCollections,
        );
        await authStore.putUser(refreshed);
        return DirectConnection(server, refreshed);
      } catch (_) {
        // Expired or revoked: drop it and sign in again below.
        await authStore.removeUser(server.id, u.id);
      }
    }

    final auth = await client.authApi
        .authenticateByName(c.username, c.password)
        .timeout(const Duration(seconds: 12));
    final token = auth['AccessToken'] as String?;
    final userJson = auth['User'] as Map<String, dynamic>?;
    final userId = userJson?['Id'] as String? ?? auth['UserId'] as String?;
    if (token == null || userId == null) return null;
    final policy = userJson?['Policy'] as Map<String, dynamic>?;

    client.accessToken = token;
    client.userId = userId;
    final user = PrivateUser(
      id: userId,
      // Show the viewer's Voltix name, not the shared Lumistream login.
      name: voltixUsername,
      serverId: server.id,
      accessToken: token,
      lastUsed: DateTime.now(),
      imageTag: (userJson?['PrimaryImageTag'] as String?),
      isAdministrator:
          (policy?['IsAdministrator'] as bool? ?? false) || isVoltixAdmin,
      canDownload: policy?['EnableContentDownloading'] as bool? ?? false,
      canManageSubtitles: policy?['EnableSubtitleManagement'] as bool? ?? false,
      canManageCollections:
          policy?['EnableCollectionManagement'] as bool? ?? false,
    );
    await authStore.putUser(user);
    return DirectConnection(server, user);
  }

  static Future<void> _rememberDirectServers(List<String> addresses) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existing = prefs.getStringList(_prefsKey) ?? const <String>[];
      await prefs.setStringList(
        _prefsKey,
        {...existing, ...addresses}.toList(),
      );
    } catch (_) {}
  }

  /// Back on the proxy: remove servers that were added for direct streaming so
  /// their libraries aren't listed alongside the proxy's.
  static Future<void> _removeDirectServers(ServerRepository serverRepo) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final addresses = prefs.getStringList(_prefsKey) ?? const <String>[];
      if (addresses.isEmpty) return;
      for (final s in serverRepo.servers
          .where((s) => addresses.contains(s.address))
          .toList()) {
        await serverRepo.deleteServer(s.id);
      }
      await prefs.remove(_prefsKey);
    } catch (_) {}
  }
}
