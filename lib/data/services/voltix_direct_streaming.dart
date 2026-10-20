import 'dart:async';

import 'package:dio/dio.dart';
import 'package:get_it/get_it.dart';
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../auth/models/server.dart';
import '../../auth/models/user.dart';
import '../../auth/repositories/server_repository.dart';
import '../../auth/repositories/session_repository.dart';
import '../../auth/store/authentication_store.dart';
import '../../auth/store/voltix_session_store.dart';
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
    api.directStreamingDiag('start', {'servers': '${voltixServers.length}'});
    final creds = await api
        .getDirectCredentials(sessionToken)
        .timeout(const Duration(seconds: 15), onTimeout: () => const []);
    api.directStreamingDiag('credentials', {'count': '${creds.length}'});
    if (creds.isEmpty) {
      await _removeDirectServers(serverRepo);
      return const {};
    }

    final out = <int, DirectConnection>{};
    await Future.wait(creds.map((c) async {
      // The proxy fallback below goes through the Voltix server, which
      // Lumistream now blocks - so a transient failure here (slow network,
      // TV just woke up) must not drop the viewer onto a path that cannot
      // work. Retry once before giving up. A 401/403 is not retried.
      Future<DirectConnection?> attempt() => _connectOne(
            c,
            serverRepo: serverRepo,
            authStore: authStore,
            clientFactory: clientFactory,
            voltixUsername: voltixUsername,
            isVoltixAdmin: isVoltixAdmin,
          ).timeout(const Duration(seconds: 25));
      try {
        DirectConnection? connection;
        try {
          connection = await attempt();
        } catch (e) {
          final status = e is DioException ? e.response?.statusCode : null;
          if (status == 401 || status == 403) rethrow;
          _logger.w('[DirectStreaming] ${c.displayName}: first attempt failed ($e) - retrying');
          api.directStreamingDiag('server-retry', {'server': c.displayName});
          await Future<void>.delayed(const Duration(seconds: 2));
          connection = await attempt();
        }
        if (connection != null) out[c.voltixServerId] = connection;
      } catch (e) {
        _logger.w('[DirectStreaming] ${c.displayName}: direct sign-in failed: $e');
        final msg = e.toString().split('\n').first;
        api.directStreamingDiag('server-failed', {
          'server': c.displayName,
          'status': e is DioException ? '${e.response?.statusCode}' : 'none',
          'error': msg.length > 120 ? msg.substring(0, 120) : msg,
        });
      }
    }));

    api.directStreamingDiag('connected', {'count': '${out.length}'});
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
    // A server the backend no longer offers (e.g. the user was moved from
    // jellyfin.crazyguy.cc to supersilo) must go: left signed in, its stale
    // entry kept serving old item ids and playback/progress went to the old
    // server, so titles sat on "Loading stream".
    await _replaceDirectServers(
      serverRepo,
      out.values.map((c) => c.server.address).toList(),
    );
    _logger.i('[DirectStreaming] Connected directly to ${out.length} server(s)');
    return out;
  }

  static final RegExp _proxyPath = RegExp(r'/api/jellyfin/(\d+)');

  /// When the active direct server is no longer one the backend assigns to
  /// this user, signs in to the assigned server(s), removes the old one and
  /// switches the active session. One quick credentials call when nothing
  /// changed. Never throws.
  static Future<void> _moveToAssignedServer(String activeAddress, String token) async {
    try {
      final getIt = GetIt.instance;
      final api = getIt<VoltixApiService>();
      final creds = await api
          .getDirectCredentials(token)
          .timeout(const Duration(seconds: 15), onTimeout: () => const []);
      if (creds.isEmpty) return; // can't tell - keep what works
      final assigned = creds.map((c) => normalizeServerBaseUrl(c.url)).toSet();
      if (assigned.contains(normalizeServerBaseUrl(activeAddress))) {
        // Already on the right server: still drop any old one left signed in
        // (it kept receiving progress reports, e.g. jellyfin.crazyguy.cc).
        await _replaceDirectServers(
          getIt<ServerRepository>(),
          creds.map((c) => c.url).toList(),
        );
        return;
      }

      final store = getIt<VoltixSessionStore>();
      final direct = await connect(
        api: api,
        sessionToken: token,
        voltixServers: const [],
        serverRepo: getIt<ServerRepository>(),
        authStore: getIt<AuthenticationStore>(),
        clientFactory: getIt<MediaServerClientFactory>(),
        voltixUsername: store.username ?? '',
        isVoltixAdmin: store.isAdmin,
      );
      if (direct.isEmpty) return;
      final target = direct.values.first;
      await getIt<SessionRepository>().switchCurrentSession(
        serverId: target.server.id,
        userId: target.user.id,
        username: store.username,
      );
      api.directStreamingDiag('moved-server', {'to': target.server.address});
      _logger.i('[DirectStreaming] Moved active session from $activeAddress to ${target.server.address}');
    } catch (e) {
      _logger.w('[DirectStreaming] Assigned-server check failed: $e');
    }
  }

  /// Moves an already signed-in device off the Voltix proxy.
  ///
  /// A device that restores its last session at launch goes straight to Home
  /// and never reaches the sign-in code above, so without this it would stay
  /// on the proxy until the viewer signed out. If the active server is a
  /// Voltix proxy entry, this signs in to the same servers directly and
  /// switches the active session to the direct one. Does nothing (and keeps
  /// the proxy) when direct streaming isn't available. Never throws.
  static Future<void> upgradeActiveSession() async {
    try {
      final getIt = GetIt.instance;
      final store = getIt<VoltixSessionStore>();
      final token = store.sessionToken;
      if (token == null || token.isEmpty) return;

      final session = getIt<SessionRepository>();
      final serverRepo = getIt<ServerRepository>();
      final activeId = session.activeServerId;
      if (activeId == null) return;
      final activeAddress = serverRepo.getServer(activeId)?.address ?? '';
      final activeMatch = _proxyPath.firstMatch(activeAddress);
      getIt<VoltixApiService>().directStreamingDiag('upgrade-check', {
        'onProxy': '${activeMatch != null}',
      });
      if (activeMatch == null) {
        // Already direct: make sure it is still the server this user is
        // assigned to. After an admin moves the user (e.g. jellyfin.crazyguy.cc
        // -> supersilo) a restored session kept playing, resuming and
        // reporting progress against the old server.
        await _moveToAssignedServer(activeAddress, token);
        return;
      }

      // Rebuild the Voltix server list from the stored proxy entries; only the
      // id and proxy address are needed to match and clean them up.
      final voltixServers = <VoltixServer>[];
      for (final s in serverRepo.servers) {
        final m = _proxyPath.firstMatch(s.address);
        if (m == null) continue;
        voltixServers.add(VoltixServer(
          id: int.parse(m.group(1)!),
          name: s.name,
          proxyUrl: s.address,
        ));
      }

      final direct = await connect(
        api: getIt<VoltixApiService>(),
        sessionToken: token,
        voltixServers: voltixServers,
        serverRepo: serverRepo,
        authStore: getIt<AuthenticationStore>(),
        clientFactory: getIt<MediaServerClientFactory>(),
        voltixUsername: store.username ?? '',
        isVoltixAdmin: store.isAdmin,
      );
      if (direct.isEmpty) {
        _logger.i('[DirectStreaming] Not available - staying on the proxy');
        return;
      }

      final target = direct[int.parse(activeMatch.group(1)!)] ??
          direct.values.first;
      await session.switchCurrentSession(
        serverId: target.server.id,
        userId: target.user.id,
        username: store.username,
      );
      _logger.i('[DirectStreaming] Switched active session to ${target.server.name} (direct)');
    } catch (e) {
      _logger.w('[DirectStreaming] Upgrade from proxy failed: $e');
    }
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

  /// Remembers exactly [current] as the direct servers and deletes any server
  /// added for direct streaming earlier that is not in it any more.
  static Future<void> _replaceDirectServers(
    ServerRepository serverRepo,
    List<String> current,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final previous = prefs.getStringList(_prefsKey) ?? const <String>[];
      final keep = current.map(normalizeServerBaseUrl).toSet();
      final stale = previous
          .where((a) => !keep.contains(normalizeServerBaseUrl(a)))
          .toSet();
      // Also catch servers added by older builds that never recorded them:
      // any other server on the same provider domain as a current one (e.g.
      // jellyfin.crazyguy.cc after the move to supersilo.crazyguy.cc).
      String domainOf(String url) {
        final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
        final parts = host.split('.');
        return parts.length >= 2 ? parts.sublist(parts.length - 2).join('.') : host;
      }
      final keepDomains = current.map(domainOf).where((d) => d.isNotEmpty).toSet();
      for (final s in serverRepo.servers) {
        final addr = normalizeServerBaseUrl(s.address);
        if (keep.contains(addr) || s.address.contains('/api/jellyfin/')) continue;
        if (keepDomains.contains(domainOf(s.address))) stale.add(s.address);
      }
      if (stale.isNotEmpty) {
        for (final s in serverRepo.servers
            .where((s) => stale.contains(s.address) ||
                stale.map(normalizeServerBaseUrl).contains(normalizeServerBaseUrl(s.address)))
            .toList()) {
          _logger.i('[DirectStreaming] Removing server no longer assigned: ${s.address}');
          await serverRepo.deleteServer(s.id);
        }
      }
      await prefs.setStringList(_prefsKey, current);
    } catch (e) {
      _logger.w('[DirectStreaming] Could not prune old direct servers: $e');
    }
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
