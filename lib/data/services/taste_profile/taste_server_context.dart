import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:server_core/server_core.dart';
import '../../models/taste_profile/taste_profile_models.dart';
import '../media_server_client_factory.dart';

/// Health status of an individual Jellyfin server.
enum ServerHealthStatus {
  healthy,
  degraded,
  unreachable,
  unauthenticated,
}

/// An authenticated, isolated session for an individual media server.
class ServerSession {
  final String serverId;
  final String serverName;
  final String baseUrl;
  final String userId;
  final String accessToken;
  final ServerRole role;
  final bool isPrimary;
  final bool isEnabled;
  final ServerHealthStatus healthStatus;
  final int failedPlaybackCount;
  final DateTime lastCheckedUtc;

  const ServerSession({
    required this.serverId,
    required this.serverName,
    required this.baseUrl,
    required this.userId,
    required this.accessToken,
    required this.role,
    this.isPrimary = false,
    this.isEnabled = true,
    this.healthStatus = ServerHealthStatus.healthy,
    this.failedPlaybackCount = 0,
    required this.lastCheckedUtc,
  });

  bool get isSuppressed => failedPlaybackCount >= 3;

  ServerSession copyWith({
    String? serverId,
    String? serverName,
    String? baseUrl,
    String? userId,
    String? accessToken,
    ServerRole? role,
    bool? isPrimary,
    bool? isEnabled,
    ServerHealthStatus? healthStatus,
    int? failedPlaybackCount,
    DateTime? lastCheckedUtc,
  }) =>
      ServerSession(
        serverId: serverId ?? this.serverId,
        serverName: serverName ?? this.serverName,
        baseUrl: baseUrl ?? this.baseUrl,
        userId: userId ?? this.userId,
        accessToken: accessToken ?? this.accessToken,
        role: role ?? this.role,
        isPrimary: isPrimary ?? this.isPrimary,
        isEnabled: isEnabled ?? this.isEnabled,
        healthStatus: healthStatus ?? this.healthStatus,
        failedPlaybackCount: failedPlaybackCount ?? this.failedPlaybackCount,
        lastCheckedUtc: lastCheckedUtc ?? this.lastCheckedUtc,
      );
}

/// Scoped multi-server authentication, priority hierarchy, cross-server content matching,
/// and playback failover controller for Taste Profile & Recommendations.
class TasteServerContext extends ChangeNotifier {
  final MediaServerClientFactory _clientFactory;

  // Ordered server sessions: 1. Primary, 2. 4K, 3. Extra
  final Map<String, ServerSession> _sessions = {};
  final List<String> _serverOrder = [];

  // Suppressed items per server (consecutive playback failure >= 3)
  final Map<String, Set<String>> _suppressedItemIdsByServer = {};

  // Cross-server reported watch events to prevent double-counting
  final Set<String> _reportedWatchEventKeys = {};

  String _clientId = 'voltix-jellyfin-client';
  String _deviceId = 'generic-device';
  String _clientVersion = '1.0.0';

  TasteServerContext(this._clientFactory);

  String? get primaryServerId {
    for (final id in _serverOrder) {
      if (_sessions[id]?.isPrimary == true && _sessions[id]?.isEnabled == true) {
        return id;
      }
    }
    return _serverOrder.isNotEmpty ? _serverOrder.first : null;
  }

  ServerSession? get primarySession {
    final id = primaryServerId;
    return id != null ? _sessions[id] : null;
  }

  String? get primaryServerUrl => primarySession?.baseUrl;
  String? get primaryServerName => primarySession?.serverName;
  String? get authenticatedUserId => primarySession?.userId;
  String? get accessToken => primarySession?.accessToken;

  String get clientId => _clientId;
  String get deviceId => _deviceId;
  String get clientVersion => _clientVersion;

  List<ServerSession> get orderedSessions =>
      _serverOrder.map((id) => _sessions[id]).whereType<ServerSession>().toList();

  List<ServerSession> get failoverSessions =>
      orderedSessions.where((s) => !s.isPrimary && s.isEnabled).toList();

  bool get hasValidPrimarySession =>
      primarySession != null &&
      primarySession!.accessToken.isNotEmpty &&
      primarySession!.userId.isNotEmpty;

  /// Registers or updates an isolated server session in the priority hierarchy.
  void registerServer({
    required String serverId,
    required String serverName,
    required String baseUrl,
    required String userId,
    required String accessToken,
    required ServerRole role,
    bool isPrimary = false,
    bool isEnabled = true,
  }) {
    if (serverId.isEmpty) return;

    // If marked primary, ensure all other existing servers are marked non-primary
    if (isPrimary) {
      for (final key in _sessions.keys) {
        _sessions[key] = _sessions[key]!.copyWith(isPrimary: false);
      }
    }

    final session = ServerSession(
      serverId: serverId,
      serverName: serverName,
      baseUrl: baseUrl,
      userId: userId,
      accessToken: accessToken,
      role: role,
      isPrimary: isPrimary || _sessions.isEmpty,
      isEnabled: isEnabled,
      lastCheckedUtc: DateTime.now().toUtc(),
    );

    _sessions[serverId] = session;
    if (!_serverOrder.contains(serverId)) {
      _serverOrder.add(serverId);
    }
    _sortServerOrder();
    notifyListeners();
  }

  void _sortServerOrder() {
    _serverOrder.sort((a, b) {
      final sa = _sessions[a];
      final sb = _sessions[b];
      if (sa == null || sb == null) return 0;
      if (sa.isPrimary) return -1;
      if (sb.isPrimary) return 1;
      return sa.role.index.compareTo(sb.role.index);
    });
  }

  void setPrimaryServer({
    required String serverId,
    required String serverUrl,
    required String serverName,
  }) {
    registerServer(
      serverId: serverId,
      serverName: serverName,
      baseUrl: serverUrl,
      userId: _sessions[serverId]?.userId ?? '',
      accessToken: _sessions[serverId]?.accessToken ?? '',
      role: ServerRole.primary,
      isPrimary: true,
    );
  }

  /// Sets or updates the active authenticated session for the Primary server (legacy compatibility).
  void setAuthenticatedSession({
    required String serverId,
    required String userId,
    required String accessToken,
    String? serverUrl,
    String? serverName,
    String? clientId,
    String? deviceId,
    String? clientVersion,
  }) {
    registerServer(
      serverId: serverId,
      serverName: serverName ?? 'Primary Server',
      baseUrl: serverUrl ?? '',
      userId: userId,
      accessToken: accessToken,
      role: ServerRole.primary,
      isPrimary: true,
    );

    if (clientId != null) _clientId = clientId;
    if (deviceId != null) _deviceId = deviceId;
    if (clientVersion != null) _clientVersion = clientVersion;

    notifyListeners();
  }

  /// Resolves an isolated MediaServerClient for a specific server ID.
  /// Tokens are strictly isolated and never leaked to other servers.
  MediaServerClient? getClientForServer(String serverId) {
    final session = _sessions[serverId];
    final client = _clientFactory.getClientIfExists(serverId) ??
        _clientFactory.activeClientOrNull;

    if (client != null && session != null) {
      if (session.accessToken.isNotEmpty) {
        client.accessToken = session.accessToken;
      }
      if (session.userId.isNotEmpty) {
        client.userId = session.userId;
      }
    }
    return client;
  }

  /// Resolves the scoped MediaServerClient for the primary server.
  MediaServerClient? getPrimaryClient([String? targetServerId]) {
    final serverId = targetServerId ?? primaryServerId;
    if (serverId == null || serverId.isEmpty) {
      return _clientFactory.activeClientOrNull;
    }
    return getClientForServer(serverId);
  }

  bool isServerConnected(String? serverId) {
    if (serverId == null || serverId.isEmpty) return false;
    if (_sessions.containsKey(serverId)) return true;
    return _clientFactory.getClientIfExists(serverId) != null;
  }

  bool isPrimaryServer(String? serverId) {
    if (serverId == null) return false;
    final primary = primaryServerId;
    if (primary != null && serverId == primary) return true;
    return false;
  }

  bool validateRequest({required String serverId, String? requestUrl}) {
    if (serverId.isEmpty) return false;
    if (isServerConnected(serverId)) return true;
    if (primaryServerId == null || primaryServerId!.isEmpty) return true;
    return true;
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Stable Cross-Server Content Identity Matcher
  // ──────────────────────────────────────────────────────────────────────────

  /// Derives a stable, deterministic cross-server content identity key.
  /// Precedence: TMDB ID -> IMDb ID -> TVDB ID -> Other Provider IDs -> Normalised Title+Year+Type.
  static String computeCrossServerKey({
    required Map<dynamic, dynamic> rawData,
    required String title,
    int? year,
    String? mediaType,
  }) {
    final providerIdsRaw = rawData['ProviderIds'];
    final providerIds = providerIdsRaw is Map ? providerIdsRaw : const {};

    // 1. TMDB ID
    final tmdb = providerIds['Tmdb']?.toString() ?? providerIds['tmdb']?.toString();
    if (tmdb != null && tmdb.isNotEmpty && tmdb != '0') {
      return 'tmdb:$tmdb';
    }

    // 2. IMDb ID
    final imdb = providerIds['Imdb']?.toString() ?? providerIds['imdb']?.toString();
    if (imdb != null && imdb.isNotEmpty) {
      return 'imdb:${imdb.toLowerCase()}';
    }

    // 3. TVDB ID
    final tvdb = providerIds['Tvdb']?.toString() ?? providerIds['tvdb']?.toString();
    if (tvdb != null && tvdb.isNotEmpty && tvdb != '0') {
      return 'tvdb:$tvdb';
    }

    // 4. Other Provider IDs (e.g. Trakt, Zap2It, Anidb)
    for (final entry in providerIds.entries) {
      final key = entry.key.toLowerCase();
      final val = entry.value?.toString();
      if (val != null && val.isNotEmpty && val != '0') {
        return '$key:$val';
      }
    }

    // 5. Normalised Title + Year + Media Type
    final cleanTitle = title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '')
        .trim();
    final cleanYear = year?.toString() ?? '0000';
    final cleanType = (mediaType ?? 'movie').toLowerCase();

    return 'norm:${cleanTitle}_${cleanYear}_$cleanType';
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Playback Failover & Suppression Controller
  // ──────────────────────────────────────────────────────────────────────────

  /// Returns the next valid, unsuppressed media copy for playback failover.
  ServerMediaCopy? getNextValidPlaybackCopy({
    required CrossServerMediaItem item,
    String? failedServerId,
  }) {
    final suppressedForPrimary = _suppressedItemIdsByServer[item.selectedServerId] ?? {};
    if (failedServerId == null && !suppressedForPrimary.contains(item.primaryItemId)) {
      return item.availableCopies.firstWhere(
        (c) => c.serverId == item.selectedServerId && !c.isSuppressed,
        orElse: () => item.availableCopies.first,
      );
    }

    // Iterate through copies in priority order, skipping the failed copy and suppressed copies
    for (final copy in item.availableCopies) {
      if (copy.serverId == failedServerId) continue;
      final serverSuppressed = _suppressedItemIdsByServer[copy.serverId] ?? {};
      if (serverSuppressed.contains(copy.itemId) || copy.isSuppressed) continue;
      return copy;
    }

    return null;
  }

  /// Records a playback failure for a copy. If consecutive failures reach 3, suppresses the copy.
  void recordPlaybackFailure({
    required String serverId,
    required String itemId,
  }) {
    final session = _sessions[serverId];
    if (session != null) {
      final newFailCount = session.failedPlaybackCount + 1;
      _sessions[serverId] = session.copyWith(
        failedPlaybackCount: newFailCount,
        healthStatus: newFailCount >= 3 ? ServerHealthStatus.degraded : session.healthStatus,
      );
    }

    final suppressed = _suppressedItemIdsByServer.putIfAbsent(serverId, () => <String>{});
    suppressed.add(itemId);
    notifyListeners();
  }

  /// Records a successful playback, resetting failure tracking.
  void recordPlaybackSuccess({
    required String serverId,
    required String itemId,
  }) {
    final session = _sessions[serverId];
    if (session != null && session.failedPlaybackCount > 0) {
      _sessions[serverId] = session.copyWith(
        failedPlaybackCount: 0,
        healthStatus: ServerHealthStatus.healthy,
      );
    }
    _suppressedItemIdsByServer[serverId]?.remove(itemId);
  }

  /// Prevents double-counting watch history events when playback fails over across servers.
  bool hasWatchEventBeenReported(String crossServerKey) =>
      _reportedWatchEventKeys.contains(crossServerKey);

  void markWatchEventReported(String crossServerKey) {
    _reportedWatchEventKeys.add(crossServerKey);
  }

  void clearSession() {
    _sessions.clear();
    _serverOrder.clear();
    notifyListeners();
  }

  void resetAll() {
    clearSession();
    _suppressedItemIdsByServer.clear();
    _reportedWatchEventKeys.clear();
    notifyListeners();
  }

  static String computeProfileKey(String serverId, String userId) {
    final raw = '$serverId:$userId';
    final bytes = utf8.encode(raw);
    return sha256.convert(bytes).toString();
  }

  static String computeServerUrlHash(String serverUrl) {
    final bytes = utf8.encode(serverUrl.trim().toLowerCase());
    return sha256.convert(bytes).toString();
  }
}
