import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:logger/logger.dart';
import 'package:playback_core/playback_core.dart';
import 'package:server_core/server_core.dart';

import '../auth/repositories/server_repository.dart';
import '../auth/repositories/session_repository.dart';
import '../auth/store/authentication_store.dart';
import '../auth/store/voltix_session_store.dart';
import '../data/models/aggregated_item.dart';
import '../data/repositories/multi_server_repository.dart';
import '../data/services/media_server_client_factory.dart';
import '../data/services/socket_handler.dart';
import '../data/services/syncplay_username_resolver.dart';
import '../preference/user_preferences.dart';
import '../ui/navigation/app_router.dart';
import '../ui/navigation/destinations.dart';
import '../util/syncplay_group_password.dart';
import '../util/syncplay_username_util.dart';
import 'syncplay_state.dart';
import 'time_sync_manager.dart';

class SyncPlayManager extends ChangeNotifier {
  static const int _pingIntervalMs = 15000;
  static const int _commandLeadToleranceMs = 250;
  static const int _commandLateToleranceMs = 800;
  static const int _maxLateCatchUpMs = 15000;
  static const int _maxSeekDeltaMs = 6 * 60 * 60 * 1000;
  static const int _bufferingDebounceMs = 800;
  static const int _readyDebounceMs = 1500;
  static const int _readyStabilityWindowMs = 600;
  static const int _handshakeRetryDelayMs = 1200;
  static const int _maxHandshakeRetries = 3;
  /// Delay before posting the Ready that answers a queue change, rather than a
  /// buffering edge. Long enough for the player to settle after a fresh load,
  /// short enough that the rest of the group is not left staring at nothing.
  static const int _handshakeReadyDelayMs = 700;
  /// Post Ready a second time if the group is somehow still Waiting this long
  /// after the first attempt.
  static const int _handshakeReadyReconfirmSeconds = 6;
  static const double _defaultSpeed = 1.0;
  static const int _membershipPollDelayMs = 600;
  static const int _membershipPollAttempts = 5;

  final PlaybackManager _playbackManager;
  final UserPreferences _preferences;

  final Logger _logger = Logger();

  SyncPlayState _state = SyncPlayState();
  List<SyncPlayGroupInfo> _availableGroups = const [];
  bool _isLoading = false;
  String? _errorMessage;
  bool _ignoreWaitEnabled = false;

  TimeSyncManager? _timeSync;
  Timer? _pingTimer;
  Timer? _scheduledTimer;
  Timer? _bufferingTimer;
  Timer? _readyTimer;
  Timer? _handshakeConfirmTimer;
  Timer? _driftTimer;
  Timer? _seekDebounceTimer;
  Timer? _queueSyncDebounceTimer;
  Duration? _pendingSeekTarget;

  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<void>? _queueChangedSub;
  bool _applyingRemoteCommand = false;
  bool _intendsToPlay = false;
  /// Group id -> the name exactly as the server holds it, marker and all.
  /// [_decorateGroups] strips the marker for display, so this is the only place
  /// the digest survives for [joinGroup] to check a typed password against.
  final Map<String, String> _rawGroupNames = {};
  final Map<String, String> _itemTitleCache = {};
  final Set<String> _pendingTitleLookups = {};

  final StreamController<SyncPlayUiEvent> _uiEventsController =
      StreamController<SyncPlayUiEvent>.broadcast();

  /// Transient one-shot UI events (toasts, dialogs) that the app shell can
  /// surface without requiring direct knowledge of SyncPlay state.
  Stream<SyncPlayUiEvent> get uiEvents => _uiEventsController.stream;

  /// Server **id** (not base URL) of the session SyncPlay is operating against.
  String? _activeServerId;
  MediaServerClient? _currentClientRef;

  /// True while [joinGroup] is deliberately switching servers, so the resulting
  /// active-client notification does not tear down the group we are joining.
  bool _switchingForJoin = false;

  /// Whether any logged-in server can host SyncPlay, independent of which one is
  /// currently active.
  bool _syncPlayAvailableAnywhere = false;

  String? _lastCommandKey;
  int _lastSyncPositionMs = 0;
  int _lastSyncTimeMs = 0;
  bool _isBuffering = false;

  SyncPlayManager(
    this._playbackManager,
    this._preferences,
  );

  SyncPlayState get state => _state;
  List<SyncPlayGroupInfo> get availableGroups => _availableGroups;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  bool get ignoreWaitEnabled => _ignoreWaitEnabled;
  TimeSyncManager? get timeSyncManager => _timeSync;

  bool get syncPlayConfigured =>
      _preferences.get(UserPreferences.syncPlayEnabled);

  bool get syncPlayServerSupported {
    final client = _currentClient;
    if (client == null) return false;
    return _clientSupportsSyncPlay(client);
  }

  bool _clientSupportsSyncPlay(MediaServerClient client) {
    // Exclude the Voltix-only stub client — it has no real Jellyfin server.
    if (client.baseUrl.contains('voltix-stub')) return false;
    return client.serverType == ServerType.jellyfin &&
        client.syncPlayApi != null;
  }

  /// True when SyncPlay can be used at all, i.e. when *any* logged-in server
  /// supports it.
  ///
  /// Discovery and joining are gated on this rather than on
  /// [syncPlayServerSupported]. Gating them on the active server meant that a
  /// user sitting on the Voltix-only stub session, or on an Emby server, was
  /// shown an empty group list and refused a join even though a sibling Jellyfin
  /// session was logged in and hosting groups.
  bool get syncPlayAvailableAnywhere =>
      syncPlayConfigured &&
      (syncPlayServerSupported || _syncPlayAvailableAnywhere);

  /// Guards the in-group transport: sending commands requires the *active*
  /// server to be the one hosting the group.
  bool get syncPlayEnabled => syncPlayConfigured && syncPlayServerSupported;

  bool get advancedCorrectionEnabled =>
      _preferences.get(UserPreferences.syncPlayAdvancedCorrectionEnabled);

  bool get syncCorrectionEnabled =>
      advancedCorrectionEnabled &&
      _preferences.get(UserPreferences.syncPlayEnableSyncCorrection);

  bool get useSpeedToSync =>
      _preferences.get(UserPreferences.syncPlayUseSpeedToSync);

  bool get useSkipToSync =>
      _preferences.get(UserPreferences.syncPlayUseSkipToSync);

  int get minDelaySpeedToSync =>
      _preferences.get(UserPreferences.syncPlayMinDelaySpeedToSync).toInt();

  int get maxDelaySpeedToSync =>
      _preferences.get(UserPreferences.syncPlayMaxDelaySpeedToSync).toInt();

  int get speedToSyncDuration =>
      _preferences.get(UserPreferences.syncPlaySpeedToSyncDuration).toInt();

  int get minDelaySkipToSync =>
      _preferences.get(UserPreferences.syncPlayMinDelaySkipToSync).toInt();

  int get extraTimeOffset =>
      _preferences.get(UserPreferences.syncPlayExtraTimeOffset).toInt();

  MediaServerClient? get _currentClient {
    // Prefer the factory's active client. The factory now tracks the active
    // server id explicitly (SessionRepository sets it on every switch); it used
    // to return whichever client was created last, which is a different server
    // as soon as two are logged in and the user switches back to the first.
    try {
      final factory = GetIt.instance<MediaServerClientFactory>();
      final factoryClient = factory.activeClientOrNull;
      if (factoryClient != null) {
        if (!identical(factoryClient, _currentClientRef)) {
          _currentClientRef = factoryClient;
          _activeServerId = factory.activeServerId ??
              factory.serverIdForClient(factoryClient);
        }
        return factoryClient;
      }
    } catch (_) {
      // Factory not registered yet — fall back to the coordinator ref.
    }
    return _currentClientRef;
  }

  /// The active server's **id**, as stored in AuthenticationStore.
  String? get _currentServerId {
    try {
      final factory = GetIt.instance<MediaServerClientFactory>();
      final id = factory.activeServerId;
      if (id != null) return id;
      final client = factory.activeClientOrNull;
      if (client != null) return factory.serverIdForClient(client);
    } catch (_) {}
    return _activeServerId;
  }

  String? _serverIdForClient(MediaServerClient client) {
    try {
      return GetIt.instance<MediaServerClientFactory>()
          .serverIdForClient(client);
    } catch (_) {
      return null;
    }
  }

  /// Every logged-in session whose server can host SyncPlay groups.
  Future<List<ServerUserSession>> _syncPlayCapableSessions() async {
    if (!GetIt.instance.isRegistered<MultiServerRepository>()) {
      return const <ServerUserSession>[];
    }
    try {
      final sessions =
          await GetIt.instance<MultiServerRepository>().getLoggedInServers();
      return sessions
          .where((s) => _clientSupportsSyncPlay(s.client))
          .toList(growable: false);
    } catch (e) {
      _logger.w('SyncPlay could not enumerate logged-in servers', error: e);
      return const <ServerUserSession>[];
    }
  }

  SyncPlayApi? get _api => _currentClient?.syncPlayApi;

  /// The Voltix name to show for a Jellyfin participant username.
  ///
  /// Resolution is asynchronous and cached; until it completes (or when the
  /// backend has no match) this returns a neutral placeholder derived from the
  /// Jellyfin name rather than the raw upstream account, and never another
  /// participant's name.
  String displayNameFor(String participant) {
    final name = participant.trim();
    if (name.isEmpty) return 'Voltix User';
    try {
      final resolver = GetIt.instance<SyncPlayUsernameResolver>();
      final resolved = resolver.cached(name);
      if (resolved != null && resolved.isNotEmpty) return resolved;
    } catch (_) {
      // Resolver not registered (e.g. in a widget test) — fall through.
    }
    return _placeholderFor(name);
  }

  /// Every participant of the active group, as Voltix names.
  List<String> get participantDisplayNames =>
      _state.participants.map(displayNameFor).toList(growable: false);

  /// Masks an unresolved Jellyfin username so the upstream naming is not shown.
  ///
  /// Keeps a stable suffix so two different participants stay visibly different
  /// while resolution is pending.
  String _placeholderFor(String jellyfinUsername) =>
      syncPlayNamePlaceholder(jellyfinUsername);

  /// Resolves the Voltix names for every participant currently on screen -
  /// the active group plus every group in the browse list.
  Future<void> _resolveParticipantNames() async {
    final names = <String>{
      ..._state.participants,
      for (final group in _availableGroups) ...group.participants,
    };
    if (names.isEmpty) return;
    try {
      final resolver = GetIt.instance<SyncPlayUsernameResolver>();
      final changed = await resolver.resolve(names);
      if (changed) notifyListeners();
    } catch (e) {
      _logger.w('SyncPlay could not resolve participant names', error: e);
    }
  }

  /// Returns a cached display title for a SyncPlay queue item id, kicking off
  /// a background resolution via the items API on the first miss.
  String? itemTitleFor(String itemId) {
    if (itemId.isEmpty) return null;
    final cached = _itemTitleCache[itemId];
    if (cached != null) return cached;
    if (_pendingTitleLookups.add(itemId)) {
      unawaited(_fetchItemTitle(itemId));
    }
    return null;
  }

  Future<void> _fetchItemTitle(String itemId) async {
    try {
      final client = _currentClient;
      if (client == null) return;
      final result = await client.itemsApi.getItem(itemId);
      final name = result['Name'] as String?;
      if (name != null && name.isNotEmpty) {
        _itemTitleCache[itemId] = name;
        notifyListeners();
      }
    } catch (_) {
      // Leave the entry pending so a future retry from the UI can try again.
      _pendingTitleLookups.remove(itemId);
    }
  }

  void setActiveClient(MediaServerClient? client) {
    final newId = client == null ? null : _serverIdForClient(client);
    if (_activeServerId == newId && identical(_currentClientRef, client)) {
      return;
    }
    _activeServerId = newId;
    _currentClientRef = client;
    // Leaving the server that hosts the group means leaving the group — except
    // when we are the ones switching servers in order to join.
    if (_state.enabled && !_switchingForJoin) {
      _resetState();
    }
  }

  /// Splits the password marker off every group name before anything sees it.
  ///
  /// The marker is an implementation detail of [SyncPlayGroupPassword]; the UI
  /// gets a clean name and a truthful [SyncPlayGroupInfo.hasPassword], which is
  /// what makes the list show a lock and the join dialog prompt at all. The
  /// server never sets hasPassword itself - it has no such concept.
  List<SyncPlayGroupInfo> _decorateGroups(List<SyncPlayGroupInfo> groups) {
    return groups.map((group) {
      final raw = group.groupName;
      if (raw != null && raw.isNotEmpty) {
        _rawGroupNames[group.groupId] = raw;
      }
      return group.copyWith(
        groupName: SyncPlayGroupPassword.displayName(raw),
        hasPassword: SyncPlayGroupPassword.isProtected(raw),
      );
    }).toList();
  }

  void _setLoading(bool value) {
    if (_isLoading == value) return;
    _isLoading = value;
    notifyListeners();
  }

  void _setError(String? message) {
    _errorMessage = message;
    notifyListeners();
  }

  /// Lists every SyncPlay group visible on every logged-in server.
  ///
  /// Deliberately not gated on the active server supporting SyncPlay - the whole
  /// point is to surface groups hosted elsewhere so the user can be moved to
  /// them. Each group is tagged with the owning server's **id** (never its base
  /// URL) because [joinGroup] resolves and compares by id.
  Future<void> fetchGroups() async {
    if (!syncPlayConfigured) {
      _availableGroups = const [];
      _syncPlayAvailableAnywhere = false;
      notifyListeners();
      return;
    }

    _setLoading(true);
    _errorMessage = null;

    try {
      final sessions = await _syncPlayCapableSessions();
      _syncPlayAvailableAnywhere = sessions.isNotEmpty;

      if (sessions.isNotEmpty) {
        final results = await Future.wait(
          sessions.map((session) async {
            try {
              final groups = await session.client.syncPlayApi!.getGroups();
              return groups
                  .map((g) => g.copyWith(
                        serverId: session.server.id,
                        serverName: session.server.name,
                      ))
                  .toList();
            } catch (e) {
              _logger.w(
                'SyncPlay fetchGroups failed for ${session.server.name}',
                error: e,
              );
              return const <SyncPlayGroupInfo>[];
            }
          }),
        );
        _availableGroups = _decorateGroups(results.expand((e) => e).toList());
        unawaited(_resolveParticipantNames());
        _setLoading(false);
        return;
      }

      // MultiServerRepository unavailable (or nothing enumerable) - fall back to
      // the active client only, still tagged with its real server id.
      final client = _currentClient;
      final api = client?.syncPlayApi;
      if (client != null && api != null && _clientSupportsSyncPlay(client)) {
        _syncPlayAvailableAnywhere = true;
        final groups = await api.getGroups();
        final serverId = _serverIdForClient(client);
        _availableGroups = _decorateGroups(
          groups.map((g) => g.copyWith(serverId: serverId)).toList(),
        );
        unawaited(_resolveParticipantNames());
      } else {
        _availableGroups = const [];
      }
    } catch (e) {
      _errorMessage = 'Failed to load groups';
      _logger.w('SyncPlay fetchGroups failed', error: e);
    }
    _setLoading(false);
  }

  Future<void> createGroup(
    String name, {
    String? password,
    bool withCurrentQueueSnapshot = true,
  }) async {
    if (!syncPlayAvailableAnywhere) {
      _setError('SyncPlay is currently unavailable');
      return;
    }

    _setLoading(true);
    _errorMessage = null;

    // Hosting a group requires being ON a SyncPlay-capable server. If the active
    // session is the Voltix stub or an Emby server, move to a capable one first
    // rather than refusing - the user has a Jellyfin session, it is just not the
    // one in front of them.
    if (!syncPlayServerSupported) {
      final target = await _firstSyncPlayCapableServerId();
      if (target == null || !await _ensureActiveServer(target)) {
        _setError('No server available to host a SyncPlay group');
        _setLoading(false);
        return;
      }
    }

    final api = _api;
    if (api == null) {
      _setError('SyncPlay is currently unavailable');
      _setLoading(false);
      return;
    }
    try {
      // The password rides in the name. api.createGroup still accepts a
      // password argument, but Jellyfin's NewGroupRequestDto has no such field
      // and drops it, so passing it would only look like it did something.
      final wireName = SyncPlayGroupPassword.encodeName(name, password);
      await api.createGroup(wireName);
      _state.enabled = true;
      _startTimeSync();
      _startPingLoop();
      _attachPlaybackObservers();
      // /SyncPlay/New returns no body, so the group id only arrives on the
      // realtime push. Resolve it directly as well, otherwise a missed push
      // leaves a group with a null id that no command can address.
      await _confirmCreatedGroup(wireName);
      if (withCurrentQueueSnapshot) {
        await syncCurrentPlaybackQueueToGroup();
      }
    } catch (e) {
      _errorMessage = 'Failed to create group';
      _logger.w('SyncPlay createGroup failed', error: e);
    }
    _setLoading(false);
  }

  Future<void> joinGroup(
    String groupId, {
    String? password,
    String? targetServerId,
    bool withCurrentQueueSnapshot = false,
  }) async {
    if (!syncPlayAvailableAnywhere) {
      _setError('SyncPlay is currently unavailable');
      return;
    }

    _setLoading(true);
    _errorMessage = null;

    try {
      final groupInfo =
          _availableGroups.where((g) => g.groupId == groupId).firstOrNull;
      final serverIdToJoin = targetServerId ?? groupInfo?.serverId;

      // Checked before the server switch, not after: failing a password should
      // not have already moved the user off the server they were watching on.
      final rawName = _rawGroupNames[groupId];
      if (!SyncPlayGroupPassword.matches(rawName, password)) {
        _setError(
          (password == null || password.trim().isEmpty)
              ? 'This group needs a password'
              : 'Incorrect group password',
        );
        _setLoading(false);
        return;
      }

      if (serverIdToJoin != null && serverIdToJoin.isNotEmpty) {
        final switched = await _ensureActiveServer(serverIdToJoin);
        if (!switched) {
          _setError(
            'Could not switch to ${groupInfo?.serverName ?? 'the server'} '
            'hosting this group',
          );
          _setLoading(false);
          return;
        }
      }

      final api = _api;
      if (api == null || !syncPlayServerSupported) {
        _setError('SyncPlay is currently unavailable on target server');
        _setLoading(false);
        return;
      }

      // Not passed on: JoinGroupRequestDto has no password field either. The
      // check above is the enforcement.
      await api.joinGroup(groupId);

      _switchingForJoin = true;
      _state.enabled = true;
      _state.groupId = groupId;
      _state.groupName = groupInfo?.groupName ?? _state.groupName;
      _startTimeSync();
      _startPingLoop();
      _attachPlaybackObservers();
      _switchingForJoin = false;

      // Never rely on the GroupJoined push alone. Straight after a server switch
      // the socket is still handshaking, so the push can be missed entirely -
      // which used to leave the UI "in a group" with no id, no participants and
      // no working commands.
      await _confirmGroupMembership(expectedGroupId: groupId);

      if (withCurrentQueueSnapshot) {
        await syncCurrentPlaybackQueueToGroup();
      }
    } catch (e) {
      _errorMessage = 'Failed to join group';
      _logger.w('SyncPlay joinGroup failed', error: e);
    } finally {
      _switchingForJoin = false;
    }
    _setLoading(false);
  }

  /// The server id of the first logged-in session that can host SyncPlay,
  /// preferring the active one so we do not switch unnecessarily.
  Future<String?> _firstSyncPlayCapableServerId() async {
    final sessions = await _syncPlayCapableSessions();
    if (sessions.isEmpty) return null;
    final activeId = _currentServerId;
    for (final session in sessions) {
      if (session.server.id == activeId) return session.server.id;
    }
    return sessions.first.server.id;
  }

  /// Makes [serverId] the active session, waiting for its realtime socket.
  ///
  /// Returns false when there is no stored user for that server or the switch
  /// fails, so the caller can report it rather than silently joining on whatever
  /// server happened to be active.
  Future<bool> _ensureActiveServer(String serverId) async {
    if (_currentServerId == serverId && _api != null) {
      await _awaitRealtime(serverId);
      return true;
    }

    if (!GetIt.instance.isRegistered<SessionRepository>() ||
        !GetIt.instance.isRegistered<AuthenticationStore>()) {
      _logger.w('SyncPlay cannot switch servers: session services missing');
      return false;
    }

    _switchingForJoin = true;
    try {
      final authStore = GetIt.instance<AuthenticationStore>();
      final users = authStore.getUsers(serverId);
      if (users.isEmpty) {
        _logger.w('SyncPlay: no stored user for server $serverId');
        return false;
      }

      final sessionRepo = GetIt.instance<SessionRepository>();
      final ok = await sessionRepo.switchCurrentSession(
        serverId: serverId,
        userId: users.first.id,
      );
      if (!ok) {
        _logger.w('SyncPlay: switchCurrentSession failed for $serverId');
        return false;
      }

      final factory = GetIt.instance<MediaServerClientFactory>();
      final newClient = factory.getClientIfExists(serverId);
      if (newClient == null) {
        _logger.w('SyncPlay: no client for server $serverId after switch');
        return false;
      }
      _currentClientRef = newClient;
      _activeServerId = serverId;

      await _awaitRealtime(serverId);
      return true;
    } catch (e) {
      _logger.w('SyncPlay failed to switch to server $serverId', error: e);
      return false;
    } finally {
      _switchingForJoin = false;
    }
  }

  Future<void> _awaitRealtime(String serverId) async {
    if (!GetIt.instance.isRegistered<SocketHandler>()) return;
    try {
      final ready = await GetIt.instance<SocketHandler>()
          .waitUntilConnectedTo(serverId);
      if (!ready) {
        _logger.w('SyncPlay: realtime socket not ready for server $serverId');
      }
    } catch (_) {}
  }

  /// Pulls group state from the server until it is populated.
  ///
  /// Complements the realtime push rather than replacing it: whichever arrives
  /// first wins, and the loop exits as soon as participants are known.
  Future<void> _confirmGroupMembership({
    required String expectedGroupId,
    int attempts = _membershipPollAttempts,
  }) async {
    for (var attempt = 0; attempt < attempts; attempt++) {
      if (!_state.enabled) return;
      if (_state.groupId == expectedGroupId && _state.participants.isNotEmpty) {
        return;
      }

      final info = await _readGroup(expectedGroupId);
      if (info != null) {
        _applyGroupInfo(info);
        if (info.participants.isNotEmpty) return;
      }

      await Future<void>.delayed(
        const Duration(milliseconds: _membershipPollDelayMs),
      );
    }
  }

  /// Resolves a freshly created group by name, since create returns no id.
  Future<void> _confirmCreatedGroup(String name) async {
    for (var attempt = 0; attempt < _membershipPollAttempts; attempt++) {
      if (!_state.enabled) return;

      final known = _state.groupId;
      if (known != null && known.isNotEmpty) {
        await _confirmGroupMembership(expectedGroupId: known, attempts: 1);
        return;
      }

      final api = _api;
      if (api == null) return;
      try {
        final groups = await api.getGroups();
        final match = groups.where((g) => g.groupName == name).lastOrNull;
        if (match != null && match.groupId.isNotEmpty) {
          _applyGroupInfo(match);
          return;
        }
      } catch (e) {
        _logger.w('SyncPlay could not resolve created group', error: e);
      }

      await Future<void>.delayed(
        const Duration(milliseconds: _membershipPollDelayMs),
      );
    }
  }

  /// Reads one group, preferring /SyncPlay/{id} and falling back to the list
  /// endpoint, which older server builds are more reliable about exposing.
  Future<SyncPlayGroupInfo?> _readGroup(String groupId) async {
    final api = _api;
    if (api == null) return null;
    try {
      final group = await api.getGroup(groupId);
      if (group.groupId.isNotEmpty) return group;
    } catch (_) {}
    try {
      final groups = await api.getGroups();
      return groups.where((g) => g.groupId == groupId).firstOrNull;
    } catch (e) {
      _logger.w('SyncPlay could not read group $groupId', error: e);
      return null;
    }
  }

  void _applyGroupInfo(SyncPlayGroupInfo info) {
    _state.groupId = info.groupId;
    final raw = info.groupName;
    if (raw != null && raw.isNotEmpty) _rawGroupNames[info.groupId] = raw;
    final display = SyncPlayGroupPassword.displayName(raw);
    _state.groupName = display.isNotEmpty ? display : _state.groupName;
    _state.participants = info.participants;
    _state.lastUpdateAt = info.lastUpdatedAt;
    if (info.state != null) _state.groupState = info.state!;
    unawaited(_resolveParticipantNames());
    notifyListeners();
  }

  Future<void> leaveGroup() async {
    final api = _api;
    if (api != null) {
      try {
        await api.leaveGroup();
      } catch (_) {}
    }
    _resetState();
  }

  void _resetState() {
    _state = SyncPlayState();
    _intendsToPlay = false;
    _stopTimeSync();
    _stopPingLoop();
    _stopPlaybackObservers();
    _scheduledTimer?.cancel();
    _scheduledTimer = null;
    _driftTimer?.cancel();
    _driftTimer = null;
    _lastCommandKey = null;
    _lastSyncPositionMs = 0;
    _lastSyncTimeMs = 0;
    _restorePlaybackRate();
    notifyListeners();
  }

  void _startTimeSync() {
    final api = _api;
    if (api == null) return;
    _stopTimeSync();
    final tsm = TimeSyncManager(api);
    _timeSync = tsm;
    tsm.startSync();
  }

  void _stopTimeSync() {
    _timeSync?.stopSync();
    _timeSync = null;
  }

  void _startPingLoop() {
    _stopPingLoop();
    _pingTimer = Timer.periodic(
      const Duration(milliseconds: _pingIntervalMs),
      (_) async {
        if (!_state.enabled) return;
        final rtt = _timeSync?.roundTripTime ?? 0;
        try {
          await _api?.sendPing(rtt);
        } catch (_) {}
      },
    );
  }

  void _stopPingLoop() {
    _pingTimer?.cancel();
    _pingTimer = null;
  }

  void appDidEnterBackground() {
    _stopTimeSync();
    _stopPingLoop();
  }

  void appDidBecomeActive() {
    if (!_state.enabled || !syncPlayEnabled) return;
    _startTimeSync();
    _startPingLoop();
    _attachPlaybackObservers();
  }

  void handleRealtimeConnected() {
    if (!_state.enabled || !syncPlayEnabled) return;
    _refreshCurrentGroupStateAfterReconnect();
  }

  void handleRealtimeSessionInterrupted(String message) {
    _errorMessage = message;
    _resetState();
  }

  Future<void> _refreshCurrentGroupStateAfterReconnect() async {
    final groupId = _state.groupId;
    final api = _api;
    if (groupId == null || groupId.isEmpty || api == null) return;
    try {
      final group = await api.getGroup(groupId);
      _state.groupId = group.groupId;
      _state.groupName = group.groupName;
      _state.participants = group.participants;
      _state.lastUpdateAt = group.lastUpdatedAt;
      if (group.state != null) _state.groupState = group.state!;
      unawaited(_resolveParticipantNames());
      _reconcileLocalPlayback();
      notifyListeners();
    } catch (_) {
      try {
        final groups = await api.getGroups();
        final match = groups.firstWhere(
          (g) => g.groupId == groupId,
          orElse: () => const SyncPlayGroupInfo(groupId: ''),
        );
        if (match.groupId.isEmpty) {
          _resetState();
          return;
        }
        _state.groupName = match.groupName;
        _state.participants = match.participants;
        _state.lastUpdateAt = match.lastUpdatedAt;
        if (match.state != null) _state.groupState = match.state!;
        unawaited(_resolveParticipantNames());
        _reconcileLocalPlayback();
        notifyListeners();
      } catch (_) {
        _errorMessage = 'Failed to recover SyncPlay state';
        notifyListeners();
      }
    }
  }

  void _reconcileLocalPlayback() {
    final pm = _playbackManager;
    switch (_state.groupState) {
      case SyncPlayGroupState.paused:
      case SyncPlayGroupState.waiting:
        if (pm.state.isPlaying) pm.pause();
        break;
      case SyncPlayGroupState.playing:
        if (!pm.state.isPlaying) pm.resume();
        break;
      case SyncPlayGroupState.idle:
        break;
    }
  }

  void handlePlaybackCommand(SyncPlayCommand command) {
    if (!_state.enabled || !syncPlayEnabled) return;
    final groupId = _state.groupId;
    if (groupId != null && groupId.isNotEmpty && command.groupId != groupId) {
      return;
    }
    final currentItemId = _state.currentPlaylistItemId;
    if (command.playlistItemId != null &&
        currentItemId != null &&
        currentItemId.isNotEmpty &&
        command.playlistItemId != currentItemId) {
      return;
    }
    final key = command.dedupeKey;
    if (key == _lastCommandKey) return;
    _lastCommandKey = key;

    switch (command.command) {
      case SyncPlayCommandType.unpause:
        _handleUnpause(command);
        break;
      case SyncPlayCommandType.pause:
        _handlePause(command);
        break;
      case SyncPlayCommandType.seek:
        _handleSeek(command);
        break;
      case SyncPlayCommandType.stop:
        _handleStop();
        break;
    }
  }

  void handleGroupUpdate(SyncPlayGroupUpdate update) {
    if (!syncPlayEnabled) return;
    switch (update.type) {
      case SyncPlayGroupUpdateType.groupJoined:
        final payload = update.payload as SyncPlayGroupJoinedPayload;
        final info = payload.info;
        _state.enabled = true;
        _state.groupId = info.groupId;
        final rawJoinedName = info.groupName;
        if (rawJoinedName != null && rawJoinedName.isNotEmpty) {
          _rawGroupNames[info.groupId] = rawJoinedName;
        }
        _state.groupName = SyncPlayGroupPassword.displayName(rawJoinedName);
        _state.participants = info.participants;
        _state.lastUpdateAt = info.lastUpdatedAt;
        if (info.state != null) _state.groupState = info.state!;
        _startTimeSync();
        _startPingLoop();
        _attachPlaybackObservers();
        unawaited(_resolveParticipantNames());
        notifyListeners();
        break;
      case SyncPlayGroupUpdateType.groupLeft:
        _resetState();
        break;
      case SyncPlayGroupUpdateType.notInGroup:
        _errorMessage = 'You are no longer in a SyncPlay group';
        _resetState();
        break;
      case SyncPlayGroupUpdateType.groupDoesNotExist:
        _errorMessage = 'That SyncPlay group no longer exists';
        _resetState();
        break;
      case SyncPlayGroupUpdateType.libraryAccessDenied:
        _errorMessage =
            'You do not have access to one or more items in this group';
        _uiEventsController
            .add(const SyncPlayUiEvent.libraryAccessDenied());
        _resetState();
        break;
      case SyncPlayGroupUpdateType.stateUpdate:
        final payload = update.payload as SyncPlayStateUpdatePayload;
        _state.groupState = payload.update.state;
        notifyListeners();
        break;
      case SyncPlayGroupUpdateType.playQueue:
        final payload = update.payload as SyncPlayPlayQueuePayload;
        _applyQueueUpdate(payload.update);
        notifyListeners();
        break;
      case SyncPlayGroupUpdateType.userJoined:
        final payload = update.payload as SyncPlayUserJoinedPayload;
        if (!_state.participants.contains(payload.userName)) {
          _state.participants = [..._state.participants, payload.userName];
          // Resolve first so the toast names the Voltix user, not the Jellyfin
          // account, then emit with whatever the resolver settled on.
          unawaited(_announceParticipantChange(
            payload.userName,
            joined: true,
          ));
          notifyListeners();
        }
        break;
      case SyncPlayGroupUpdateType.userLeft:
        final payload = update.payload as SyncPlayUserLeftPayload;
        final updated = _state.participants
            .where((p) => p != payload.userName)
            .toList();
        if (updated.length != _state.participants.length) {
          _state.participants = updated;
          unawaited(_announceParticipantChange(
            payload.userName,
            joined: false,
          ));
          notifyListeners();
        }
        break;
    }
  }

  Future<void> _announceParticipantChange(
    String jellyfinUsername, {
    required bool joined,
  }) async {
    try {
      final resolver = GetIt.instance<SyncPlayUsernameResolver>();
      if (resolver.cached(jellyfinUsername) == null) {
        await resolver.resolve([jellyfinUsername]);
      }
    } catch (_) {}
    if (_uiEventsController.isClosed) return;
    final display = displayNameFor(jellyfinUsername);
    _uiEventsController.add(
      joined
          ? SyncPlayUiEvent.userJoined(display)
          : SyncPlayUiEvent.userLeft(display),
    );
    notifyListeners();
  }

  void _applyQueueUpdate(SyncPlayPlayQueueUpdate update) {
    final previousPlaylistItemId = _state.currentPlaylistItemId;
    _state.queue = update.playlist;
    _state.currentItemIndex = update.playingItemIndex;
    final idx = update.playingItemIndex;
    _state.currentPlaylistItemId =
        (idx >= 0 && idx < update.playlist.length)
            ? update.playlist[idx].playlistItemId
            : null;
    _state.repeatMode = update.repeatMode;
    _state.shuffleMode = update.shuffleMode;
    _state.lastUpdateAt = update.lastUpdate;

    final reason = update.reason;
    final isItemSwitch = reason == SyncPlayQueueUpdateReason.newPlaylist ||
        reason == SyncPlayQueueUpdateReason.setCurrentItem ||
        reason == SyncPlayQueueUpdateReason.nextItem ||
        reason == SyncPlayQueueUpdateReason.previousItem ||
        previousPlaylistItemId != _state.currentPlaylistItemId;
    if (!isItemSwitch) return;

    final targetPlaylistItemId = _state.currentPlaylistItemId;
    final targetItemId = (idx >= 0 && idx < update.playlist.length)
        ? update.playlist[idx].itemId
        : null;
    final startMs = SyncPlayUtils.ticksToMs(update.startPositionTicks);
    final shouldAutoPlay = update.isPlaying;
    _intendsToPlay = shouldAutoPlay;

    final localCurrentItemId =
        _itemId(_playbackManager.queueService.currentItem);
    final hasActivePlayer = _playbackManager.currentResolution != null;
    final needsRemoteLoad = targetItemId != null &&
        (targetItemId != localCurrentItemId || !hasActivePlayer);
    if (needsRemoteLoad) {
      unawaited(_loadRemoteQueueLocally(
        update: update,
        startMs: startMs,
        shouldAutoPlay: shouldAutoPlay,
        targetPlaylistItemId: targetPlaylistItemId,
      ));
      return;
    }

    Timer(const Duration(milliseconds: 750), () {
      if (!_state.enabled) return;
      if (_state.currentPlaylistItemId != targetPlaylistItemId) return;
      _applyingRemoteCommand = true;
      try {
        if (startMs > 0) {
          _playbackManager.seekTo(Duration(milliseconds: startMs));
        }
        if (!shouldAutoPlay && _playbackManager.state.isPlaying) {
          _playbackManager.pause();
        }
      } finally {
        _applyingRemoteCommand = false;
      }
      // Already holding the right item, so there is no load and no buffering
      // edge - but the group is still waiting on this session's Ready.
      _reportReadyForGroupHandshake();
    });
  }

  Future<void> _loadRemoteQueueLocally({
    required SyncPlayPlayQueueUpdate update,
    required int startMs,
    required bool shouldAutoPlay,
    required String? targetPlaylistItemId,
  }) async {
    final client = _currentClient;
    if (client == null) return;
    final serverId = _resolveActiveServerId(client);
    if (serverId == null) return;

    final loaded = await Future.wait(update.playlist.map((entry) async {
      try {
        final raw = await client.itemsApi.getItem(entry.itemId);
        return AggregatedItem(
          id: entry.itemId,
          serverId: serverId,
          rawData: raw,
        );
      } catch (_) {
        return null;
      }
    }));
    final items = loaded.whereType<AggregatedItem>().toList(growable: false);
    if (items.isEmpty) return;
    if (!_state.enabled) return;
    if (_state.currentPlaylistItemId != targetPlaylistItemId) return;

    final startIndex = update.playingItemIndex < 0
        ? 0
        : (update.playingItemIndex >= items.length
            ? items.length - 1
            : update.playingItemIndex);

    _applyingRemoteCommand = true;
    try {
      await _playbackManager.playItems(
        items,
        startIndex: startIndex,
        startPosition: Duration(milliseconds: startMs),
      );
      if (!shouldAutoPlay) {
        await _playbackManager.pause();
      }
      _ensurePlayerRouteForItem(items[startIndex]);
      // The group is in Waiting until we say we are ready. Nothing else will
      // say it for us: the player is about to sit paused, so no buffering edge
      // is coming.
      _reportReadyForGroupHandshake();
    } catch (e) {
      _logger.w('SyncPlay failed to load remote queue', error: e);
    } finally {
      _applyingRemoteCommand = false;
    }
  }

  void _ensurePlayerRouteForItem(AggregatedItem item) {
    final currentPath =
        appRouter.routerDelegate.currentConfiguration.uri.path;
    if (currentPath == Destinations.videoPlayer ||
        currentPath == Destinations.audioPlayer) {
      return;
    }
    final mediaType = item.rawData['MediaType'] as String?;
    final isAudio = item.type == 'Audio' ||
        item.type == 'MusicAlbum' ||
        item.type == 'AudioBook' ||
        mediaType == 'Audio';
    appRouter.push(
      isAudio ? Destinations.audioPlayer : Destinations.videoPlayer,
    );
  }

  String? _resolveActiveServerId(MediaServerClient client) {
    try {
      final factory = GetIt.instance<MediaServerClientFactory>();
      final entries = factory.clients.entries;
      for (final entry in entries) {
        if (identical(entry.value, client) ||
            entry.value.baseUrl == client.baseUrl) {
          return entry.key;
        }
      }
      final sessionStore = GetIt.instance<VoltixSessionStore>();
      if (sessionStore.activeServerId != null) {
        return sessionStore.activeServerId.toString();
      }
      final serverRepo = GetIt.instance<ServerRepository>();
      if (serverRepo.servers.isNotEmpty) {
        return serverRepo.servers.first.id;
      }
    } catch (_) {}
    return '1';
  }

  void _handleUnpause(SyncPlayCommand command) {
    final tsm = _timeSync;
    if (tsm == null) return;
    final serverNow = tsm.getServerTimeNow();
    final targetMs = command.whenUtcMs;
    final delayMs = targetMs - serverNow;

    final positionMs =
        _clampedPositionMs(SyncPlayUtils.ticksToMs(command.positionTicks));
    _lastSyncPositionMs = positionMs;
    _lastSyncTimeMs = targetMs;

    if (!advancedCorrectionEnabled) {
      if (delayMs > 0) {
        _scheduleAction(delayMs, () => _performResume(positionMs));
      } else {
        _performResume(positionMs);
      }
    } else if (delayMs > _commandLeadToleranceMs) {
      _scheduleAction(delayMs, () => _performResume(positionMs));
    } else if (delayMs >= -_commandLateToleranceMs) {
      _performResume(positionMs);
    } else {
      final elapsed = (-delayMs) > _maxLateCatchUpMs
          ? _maxLateCatchUpMs
          : (-delayMs);
      _performResume(_clampedPositionMs(positionMs + elapsed));
    }

    _state.groupState = SyncPlayGroupState.playing;
    notifyListeners();
  }

  void _handlePause(SyncPlayCommand command) {
    final positionMs =
        _clampedPositionMs(SyncPlayUtils.ticksToMs(command.positionTicks));
    _performPause(positionMs);
    _state.groupState = SyncPlayGroupState.paused;
    notifyListeners();
  }

  void _handleSeek(SyncPlayCommand command) {
    final serverNow = _timeSync?.getServerTimeNow() ?? 0;
    final lateness = serverNow - command.whenUtcMs;
    final raw = SyncPlayUtils.ticksToMs(command.positionTicks);
    int adjusted = raw;
    if (advancedCorrectionEnabled &&
        lateness > _commandLateToleranceMs &&
        _state.groupState == SyncPlayGroupState.playing) {
      adjusted += lateness > _maxLateCatchUpMs ? _maxLateCatchUpMs : lateness;
    }
    final positionMs = _clampedPositionMs(adjusted);
    _lastSyncPositionMs = positionMs;
    _lastSyncTimeMs = serverNow;
    _performSeek(positionMs);
  }

  void _handleStop() {
    _intendsToPlay = false;
    _applyingRemoteCommand = true;
    try {
      _playbackManager.stop(userInitiated: false);
    } finally {
      _applyingRemoteCommand = false;
    }
    _restorePlaybackRate();
    _scheduledTimer?.cancel();
    _scheduledTimer = null;
    _driftTimer?.cancel();
    _driftTimer = null;
    _state.groupState = SyncPlayGroupState.idle;
    _lastSyncPositionMs = 0;
    _lastSyncTimeMs = 0;
    notifyListeners();
  }

  void _performResume(int positionMs) {
    _intendsToPlay = true;
    _applyingRemoteCommand = true;
    try {
      _playbackManager.seekTo(Duration(milliseconds: positionMs));
      _playbackManager.resume();
    } finally {
      _applyingRemoteCommand = false;
    }
    _restorePlaybackRate();
    if (syncCorrectionEnabled) _scheduleDriftCorrection();
  }

  void _performPause(int positionMs) {
    _intendsToPlay = false;
    _restorePlaybackRate();
    _applyingRemoteCommand = true;
    try {
      _playbackManager.pause();
      _playbackManager.seekTo(Duration(milliseconds: positionMs));
    } finally {
      _applyingRemoteCommand = false;
    }
  }

  void _performSeek(int positionMs) {
    _applyingRemoteCommand = true;
    try {
      _playbackManager.seekTo(Duration(milliseconds: positionMs));
    } finally {
      _applyingRemoteCommand = false;
    }
    if (syncCorrectionEnabled &&
        _state.groupState == SyncPlayGroupState.playing) {
      _scheduleDriftCorrection();
    }
  }

  int _clampedPositionMs(int value) {
    final durationMs = _playbackManager.state.duration.inMilliseconds;
    if (durationMs <= 0) {
      final v = value < 0 ? 0 : value;
      return v > _maxSeekDeltaMs ? _maxSeekDeltaMs : v;
    }
    final v = value < 0 ? 0 : value;
    return v > durationMs ? durationMs : v;
  }

  void _restorePlaybackRate() {
    _playbackManager.setPlaybackSpeed(_defaultSpeed);
  }

  void _scheduleAction(int delayMs, void Function() action) {
    _scheduledTimer?.cancel();
    _scheduledTimer = Timer(Duration(milliseconds: delayMs < 0 ? 0 : delayMs), action);
  }

  void _scheduleDriftCorrection() {
    if (!syncCorrectionEnabled ||
        _state.groupState != SyncPlayGroupState.playing) {
      return;
    }
    _driftTimer?.cancel();
    _driftTimer = Timer(const Duration(milliseconds: 1500), _performDriftCorrection);
  }

  void _performDriftCorrection() {
    final tsm = _timeSync;
    if (tsm == null ||
        _state.groupState != SyncPlayGroupState.playing ||
        _lastSyncTimeMs == 0) {
      return;
    }
    final pm = _playbackManager;
    final currentMs = pm.state.position.inMilliseconds;
    final serverNow = tsm.getServerTimeNow();
    final expectedMs =
        _lastSyncPositionMs + (serverNow - _lastSyncTimeMs) + extraTimeOffset;

    final delay = currentMs - expectedMs;
    final absDelay = delay.abs();

    if (useSkipToSync && absDelay > minDelaySkipToSync) {
      _performSeek(expectedMs);
      _scheduleDriftCorrection();
      return;
    }

    if (useSpeedToSync &&
        absDelay > minDelaySpeedToSync &&
        absDelay < maxDelaySpeedToSync) {
      // Proportional smooth speed matching: gentle for small offsets (<500ms), faster for moderate offsets
      final double delta = absDelay < 500 ? 0.03 : 0.07;
      final speed = delay > 0 ? (1.0 - delta) : (1.0 + delta);
      pm.setPlaybackSpeed(speed);
      Timer(Duration(milliseconds: speedToSyncDuration), () {
        _restorePlaybackRate();
        _scheduleDriftCorrection();
      });
      return;
    }

    _scheduleDriftCorrection();
  }

  void _attachPlaybackObservers() {
    if (!_state.enabled) return;
    if (_bufferingSub != null) return;
    final pm = _playbackManager;
    _bufferingSub = pm.state.bufferingStream.listen(_onBuffering);
    _queueChangedSub ??= pm.queueService.queueChangedStream
        .listen((_) => _onLocalQueueChanged());
    pm.setTransportInterceptor(_interceptTransport);
  }

  void _stopPlaybackObservers() {
    _bufferingSub?.cancel();
    _bufferingSub = null;
    _queueChangedSub?.cancel();
    _queueChangedSub = null;
    _bufferingTimer?.cancel();
    _bufferingTimer = null;
    _readyTimer?.cancel();
    _readyTimer = null;
    _handshakeConfirmTimer?.cancel();
    _handshakeConfirmTimer = null;
    _seekDebounceTimer?.cancel();
    _seekDebounceTimer = null;
    _pendingSeekTarget = null;
    _queueSyncDebounceTimer?.cancel();
    _queueSyncDebounceTimer = null;
    _isBuffering = false;
    _playbackManager.setTransportInterceptor(null);
  }

  Future<bool> _interceptTransport(
    TransportAction action, {
    Duration? position,
  }) async {
    if (!_state.enabled || !syncPlayEnabled) return false;
    if (_applyingRemoteCommand) return false;
    switch (action) {
      case TransportAction.resume:
        await requestUnpause();
        return true;
      case TransportAction.pause:
        await requestPause();
        return true;
      case TransportAction.seek:
        _scheduleSeekRequest(position ?? _playbackManager.state.position);
        return true;
      case TransportAction.stop:
        await requestStop();
        return true;
      case TransportAction.next:
        await requestNext();
        return true;
      case TransportAction.previous:
        await requestPrevious();
        return true;
    }
  }

  void _scheduleSeekRequest(Duration position) {
    _pendingSeekTarget = position;
    _seekDebounceTimer?.cancel();
    _seekDebounceTimer = Timer(
      const Duration(milliseconds: 250),
      () {
        final target = _pendingSeekTarget;
        _pendingSeekTarget = null;
        if (target != null) {
          unawaited(requestSeek(target));
        }
      },
    );
  }

  void _onLocalQueueChanged() {
    if (!_state.enabled || !syncPlayEnabled) return;
    if (_applyingRemoteCommand) return;
    _queueSyncDebounceTimer?.cancel();
    _queueSyncDebounceTimer = Timer(
      const Duration(milliseconds: 400),
      () => unawaited(syncCurrentPlaybackQueueToGroup()),
    );
  }

  void _onBuffering(bool buffering) {
    if (!_state.enabled) return;
    if (buffering && !_isBuffering) {
      _isBuffering = true;
      _queueBufferingReport();
    } else if (!buffering && _isBuffering) {
      _isBuffering = false;
      _queueReadyReport();
    }
  }

  void _queueBufferingReport() {
    _bufferingTimer?.cancel();
    _bufferingTimer = Timer(
      const Duration(milliseconds: _bufferingDebounceMs),
      _sendBufferingWithRetry,
    );
  }

  void _queueReadyReport() {
    _readyTimer?.cancel();
    _readyTimer = Timer(
      const Duration(milliseconds: _readyDebounceMs),
      () async {
        if (!await _isPlaybackPositionStable()) return;
        _sendReadyWithRetry();
      },
    );
  }

  /// Reports Ready because the group's queue changed, not because buffering
  /// ended.
  ///
  /// Jellyfin moves a group into Waiting on SetNewQueue and holds it there until
  /// its sessions have posted /SyncPlay/Ready; only then does it broadcast the
  /// Unpause that actually starts everyone. The single place this client posted
  /// Ready was the buffering stream's true -> false edge, and that edge never
  /// arrives for the two sessions that matter here: a joiner whose player loads
  /// the item and then sits paused waiting for the group, and a host that was
  /// already playing when it pushed the queue. With nobody reporting ready the
  /// group stays in Waiting indefinitely - the host keeps playing its own local
  /// stream while everyone else sits in the group with nothing loaded, which is
  /// exactly the reported symptom.
  ///
  /// Sent twice: a Ready that reaches the server while it still considers the
  /// session temporally lost is answered with another buffering request rather
  /// than accepted, so one retry is kept for that case.
  void _reportReadyForGroupHandshake() {
    if (!_state.enabled || !syncPlayEnabled) return;
    _readyTimer?.cancel();
    _readyTimer = Timer(
      const Duration(milliseconds: _handshakeReadyDelayMs),
      () {
        unawaited(_sendReadyWithRetry());
        _handshakeConfirmTimer?.cancel();
        _handshakeConfirmTimer = Timer(
          const Duration(seconds: _handshakeReadyReconfirmSeconds),
          () {
            if (!_state.enabled || !syncPlayEnabled) return;
            if (_state.groupState != SyncPlayGroupState.waiting) return;
            unawaited(_sendReadyWithRetry());
          },
        );
      },
    );
  }

  Future<bool> _isPlaybackPositionStable() async {
    final pm = _playbackManager;
    if (pm.state.isBuffering) return false;
    final before = pm.state.position;
    await Future.delayed(
      const Duration(milliseconds: _readyStabilityWindowMs),
    );
    if (pm.state.isBuffering) return false;
    final after = pm.state.position;
    final deltaMs = (after - before).inMilliseconds;
    if (pm.state.isPlaying) {
      return deltaMs >= 80 && deltaMs <= 1200;
    }
    return deltaMs.abs() <= 120;
  }

  String? _currentPlaylistItemId() {
    final id = _state.currentPlaylistItemId;
    if (id != null && id.isNotEmpty) return id;
    final currentItem = _playbackManager.queueService.currentItem;
    final currentId = _itemId(currentItem);
    if (currentId == null) return null;
    for (final item in _state.queue) {
      if (item.itemId == currentId) return item.playlistItemId;
    }
    return null;
  }

  String? _itemId(dynamic item) {
    if (item == null) return null;
    try {
      final id = item.id;
      if (id is String) return id;
    } catch (_) {}
    return null;
  }

  Future<void> _sendBufferingWithRetry() async {
    for (var attempt = 0; attempt < _maxHandshakeRetries; attempt++) {
      if (!_state.enabled || !syncPlayEnabled) return;
      final api = _api;
      final playlistItemId = _currentPlaylistItemId();
      if (api == null || playlistItemId == null) return;
      final pm = _playbackManager;
      final positionTicks =
          SyncPlayUtils.msToTicks(pm.state.position.inMilliseconds);
      try {
        await api.sendBuffering(
          isPlaying: _intendsToPlay,
          playlistItemId: playlistItemId,
          positionTicks: positionTicks,
        );
        return;
      } catch (_) {
        if (attempt == _maxHandshakeRetries - 1) return;
        await Future.delayed(
          const Duration(milliseconds: _handshakeRetryDelayMs),
        );
      }
    }
  }

  Future<void> _sendReadyWithRetry() async {
    for (var attempt = 0; attempt < _maxHandshakeRetries; attempt++) {
      if (!_state.enabled || !syncPlayEnabled) return;
      final api = _api;
      final playlistItemId = _currentPlaylistItemId();
      if (api == null || playlistItemId == null) return;
      final pm = _playbackManager;
      final positionTicks =
          SyncPlayUtils.msToTicks(pm.state.position.inMilliseconds);
      try {
        await api.sendReady(
          isPlaying: _intendsToPlay,
          playlistItemId: playlistItemId,
          positionTicks: positionTicks,
        );
        return;
      } catch (_) {
        if (attempt == _maxHandshakeRetries - 1) return;
        await Future.delayed(
          const Duration(milliseconds: _handshakeRetryDelayMs),
        );
      }
    }
  }

  Future<void> requestPause() async {
    if (!_state.enabled || !syncPlayEnabled) return;
    try {
      await _api?.sendPause();
    } catch (_) {}
  }

  Future<void> requestUnpause() async {
    if (!_state.enabled || !syncPlayEnabled) return;
    try {
      await _api?.sendUnpause();
    } catch (_) {}
  }

  Future<void> requestSeek(Duration position) async {
    if (!_state.enabled || !syncPlayEnabled) return;
    try {
      await _api?.sendSeek(SyncPlayUtils.msToTicks(position.inMilliseconds));
    } catch (_) {}
  }

  Future<void> requestStop() async {
    if (!_state.enabled || !syncPlayEnabled) return;
    try {
      await _api?.sendStop();
    } catch (_) {}
  }

  Future<void> requestNext() async {
    final id = _state.currentPlaylistItemId;
    if (!_state.enabled || !syncPlayEnabled || id == null) return;
    try {
      await _api?.nextItem(id);
    } catch (_) {}
  }

  Future<void> requestPrevious() async {
    final id = _state.currentPlaylistItemId;
    if (!_state.enabled || !syncPlayEnabled || id == null) return;
    try {
      await _api?.previousItem(id);
    } catch (_) {}
  }

  Future<void> requestSetCurrentItem(String playlistItemId) async {
    if (!_state.enabled || !syncPlayEnabled) return;
    try {
      await _api?.setPlaylistItem(playlistItemId);
    } catch (_) {
      _setError('Failed to set current item');
    }
  }

  Future<void> requestRemoveFromQueue(String playlistItemId) async {
    if (!_state.enabled || !syncPlayEnabled) return;
    try {
      await _api?.removeFromPlaylist([playlistItemId]);
    } catch (_) {
      _setError('Failed to remove from queue');
    }
  }

  Future<void> requestClearQueue({bool clearPlayingItem = false}) async {
    if (!_state.enabled || !syncPlayEnabled) return;
    try {
      await _api?.removeFromPlaylist(
        const [],
        clearPlaylist: true,
        clearPlayingItem: clearPlayingItem,
      );
    } catch (_) {
      _setError('Failed to clear queue');
    }
  }

  Future<void> requestMoveQueueItem(String playlistItemId, int newIndex) async {
    if (!_state.enabled || !syncPlayEnabled) return;
    try {
      await _api?.movePlaylistItem(
        playlistItemId: playlistItemId,
        newIndex: newIndex < 0 ? 0 : newIndex,
      );
    } catch (_) {
      _setError('Failed to move queue item');
    }
  }

  Future<void> requestQueueItemIds(
    List<String> itemIds, {
    SyncPlayQueueMode mode = SyncPlayQueueMode.queue,
  }) async {
    if (!_state.enabled || !syncPlayEnabled || itemIds.isEmpty) return;
    try {
      await _api?.queue(itemIds: itemIds, mode: mode);
    } catch (_) {
      _setError('Failed to queue items');
    }
  }

  Future<void> requestSetRepeatMode(SyncPlayRepeatMode mode) async {
    if (!_state.enabled || !syncPlayEnabled) return;
    final previous = _state.repeatMode;
    _state.repeatMode = mode;
    notifyListeners();
    try {
      await _api?.setRepeatMode(mode);
    } catch (_) {
      _state.repeatMode = previous;
      _setError('Failed to set repeat mode');
    }
  }

  Future<void> requestSetShuffleMode(SyncPlayShuffleMode mode) async {
    if (!_state.enabled || !syncPlayEnabled) return;
    final previous = _state.shuffleMode;
    _state.shuffleMode = mode;
    notifyListeners();
    try {
      await _api?.setShuffleMode(mode);
    } catch (_) {
      _state.shuffleMode = previous;
      _setError('Failed to set shuffle mode');
    }
  }

  Future<void> requestSetIgnoreWait(bool enabled) async {
    if (!_state.enabled || !syncPlayEnabled) return;
    final previous = _ignoreWaitEnabled;
    _ignoreWaitEnabled = enabled;
    notifyListeners();
    try {
      await _api?.setIgnoreWait(enabled);
    } catch (_) {
      _ignoreWaitEnabled = previous;
      _setError('Failed to update ignore-wait');
    }
  }

  void cycleRepeatMode() {
    final next = switch (_state.repeatMode) {
      SyncPlayRepeatMode.repeatNone => SyncPlayRepeatMode.repeatAll,
      SyncPlayRepeatMode.repeatAll => SyncPlayRepeatMode.repeatOne,
      SyncPlayRepeatMode.repeatOne => SyncPlayRepeatMode.repeatNone,
    };
    requestSetRepeatMode(next);
  }

  void toggleShuffleMode() {
    requestSetShuffleMode(_state.shuffleMode == SyncPlayShuffleMode.shuffle
        ? SyncPlayShuffleMode.sorted
        : SyncPlayShuffleMode.shuffle);
  }

  Future<void> syncCurrentPlaybackQueueToGroup() async {
    if (!_state.enabled || !syncPlayEnabled) return;
    final pm = _playbackManager;
    final items = pm.queueService.items;
    if (items.isEmpty) return;
    final ids = <String>[];
    for (final i in items) {
      final id = _itemId(i);
      if (id != null) ids.add(id);
    }
    if (ids.isEmpty) return;
    final currentIdx = pm.queueService.currentIndex;
    final clamped = currentIdx < 0
        ? 0
        : (currentIdx >= ids.length ? ids.length - 1 : currentIdx);
    final positionTicks =
        SyncPlayUtils.msToTicks(pm.state.position.inMilliseconds);
    try {
      await _api?.setNewQueue(
        itemIds: ids,
        startIndex: clamped,
        startPositionTicks: positionTicks,
      );
      // The sender is a member of its own group and is counted in the Waiting
      // state like everyone else. A host that was already playing produces no
      // buffering edge, so without this the group it just created never leaves
      // Waiting and no one but the host ever plays.
      _reportReadyForGroupHandshake();
    } catch (_) {
      _setError('Failed to sync current playback queue');
    }
  }

  @override
  void dispose() {
    _resetState();
    _uiEventsController.close();
    super.dispose();
  }
}

/// Transient SyncPlay UI signals (toasts, dialogs) decoupled from persistent
/// state so the app shell can react without polling the manager.
sealed class SyncPlayUiEvent {
  const SyncPlayUiEvent();
  const factory SyncPlayUiEvent.userJoined(String userName) =
      SyncPlayUserJoinedEvent;
  const factory SyncPlayUiEvent.userLeft(String userName) =
      SyncPlayUserLeftEvent;
  const factory SyncPlayUiEvent.libraryAccessDenied() =
      SyncPlayLibraryAccessDeniedEvent;
}

class SyncPlayUserJoinedEvent extends SyncPlayUiEvent {
  final String userName;
  const SyncPlayUserJoinedEvent(this.userName);
}

class SyncPlayUserLeftEvent extends SyncPlayUiEvent {
  final String userName;
  const SyncPlayUserLeftEvent(this.userName);
}

class SyncPlayLibraryAccessDeniedEvent extends SyncPlayUiEvent {
  const SyncPlayLibraryAccessDeniedEvent();
}
