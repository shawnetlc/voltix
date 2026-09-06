import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:voltix_design/voltix_design.dart';
import 'package:server_core/server_core.dart';

import '../../data/repositories/multi_server_repository.dart';
import '../../data/services/socket_handler.dart';
import '../../l10n/app_localizations.dart';
import '../../preference/user_preferences.dart';
import 'bounded_network_image.dart';
import 'overlay_sheet.dart';

/// A controllable session together with the server it lives on.
///
/// Sessions are gathered from every logged-in server, so a command must be sent
/// through the client that reported the session - not through whichever server
/// happens to be active. Keeping the client alongside the payload is what makes
/// that impossible to get wrong.
class _RemoteSession {
  final Map<String, dynamic> raw;
  final MediaServerClient client;
  final String serverName;
  final String serverId;

  const _RemoteSession({
    required this.raw,
    required this.client,
    required this.serverName,
    required this.serverId,
  });

  String get id => raw['Id']?.toString() ?? '';

  /// Unique across servers: two servers can hand out the same session id.
  String get key => '$serverId::$id';

  SessionApi get sessionApi => client.sessionApi;
}

void showRemoteControlDialog(BuildContext context) {
  showFocusRestoringModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _RemoteControlSheet(),
  );
}

class _RemoteControlSheet extends StatefulWidget {
  const _RemoteControlSheet();

  @override
  State<_RemoteControlSheet> createState() => _RemoteControlSheetState();
}

class _RemoteControlSheetState extends State<_RemoteControlSheet> {
  List<_RemoteSession> _sessions = [];
  bool _loading = true;
  bool _fetching = false;
  String? _error;
  _RemoteSession? _selectedSession;
  bool _busy = false;
  double? _seekPosition;
  double? _volume;
  Timer? _refreshTimer;
  StreamSubscription<ServerWebSocketMessage>? _socketSub;

  @override
  void initState() {
    super.initState();
    _load();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _refresh(),
    );
    _socketSub = GetIt.instance<SocketHandler>().events.listen((event) {
      switch (event) {
        case SessionEndedMessage():
        case PlayMessage():
        case PlaystateMessage():
        case GeneralCommandMessage():
          _refresh();
        case ServerEventMessage(:final type)
            when type == 'SessionsStart' || type == 'SessionsStop':
          _refresh();
        default:
          break;
      }
    });
  }

  @override
  void dispose() {
    _socketSub?.cancel();
    _refreshTimer?.cancel();
    super.dispose();
  }

  /// Every logged-in server, so sessions on a server the user is not currently
  /// looking at are still listed and controllable.
  Future<List<({MediaServerClient client, String name, String id})>>
      _targets() async {
    if (GetIt.instance.isRegistered<MultiServerRepository>()) {
      try {
        final sessions =
            await GetIt.instance<MultiServerRepository>().getLoggedInServers();
        if (sessions.isNotEmpty) {
          return sessions
              .map((s) => (
                    client: s.client,
                    name: s.server.name,
                    id: s.server.id,
                  ))
              .toList();
        }
      } catch (_) {
        // Fall through to the active client below.
      }
    }
    final active = GetIt.instance<MediaServerClient>();
    return [(client: active, name: '', id: active.baseUrl)];
  }

  Future<void> _load() async {
    if (_fetching) return;
    _fetching = true;
    try {
      final targets = await _targets();
      final selfDeviceId = GetIt.instance<MediaServerClient>().deviceInfo.id;

      final perServer = await Future.wait(
        targets.map((target) async {
          try {
            // Ask for controllable sessions first; fall back to all sessions,
            // because some server builds answer the filtered query with nothing.
            var found = <Map<String, dynamic>>[];
            try {
              found = await target.client.sessionApi.getSessions(
                controllableByUserId: target.client.userId,
              );
            } catch (_) {}
            if (found.isEmpty) {
              try {
                found = await target.client.sessionApi.getSessions();
              } catch (_) {}
            }
            return found
                .map((raw) => _RemoteSession(
                      raw: raw,
                      client: target.client,
                      serverName: target.name,
                      serverId: target.id,
                    ))
                .toList();
          } catch (_) {
            return const <_RemoteSession>[];
          }
        }),
      );

      final controllable = _mergeUniqueSessions(
        perServer.expand((e) => e).toList(),
      ).where((session) {
        final deviceId = session.raw['DeviceId']?.toString();
        // Never offer to remote-control this device from itself.
        if (deviceId != null && deviceId == selfDeviceId) return false;
        return _isPotentiallyControllable(session.raw);
      }).toList();

      if (!mounted) return;
      setState(() {
        _sessions = controllable;
        _loading = false;
        _error = null;
        final previousKey = _selectedSession?.key;
        _selectedSession = previousKey == null
            ? null
            : controllable
                .cast<_RemoteSession?>()
                .firstWhere((s) => s?.key == previousKey, orElse: () => null);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    } finally {
      _fetching = false;
    }
  }

  List<_RemoteSession> _mergeUniqueSessions(List<_RemoteSession> sessions) {
    final byKey = <String, _RemoteSession>{};
    for (final session in sessions) {
      if (session.id.isEmpty) continue;
      byKey.putIfAbsent(session.key, () => session);
    }
    return byKey.values.toList();
  }

  bool _isPotentiallyControllable(Map<String, dynamic> session) {
    final supportsRemote = session['SupportsRemoteControl'];
    if (supportsRemote is bool && supportsRemote) {
      return true;
    }

    final supportsMedia = session['SupportsMediaControl'];
    if (supportsMedia is bool && supportsMedia) {
      return true;
    }

    final commands = session['SupportedCommands'];
    if (commands is List) {
      return commands.whereType<String>().isNotEmpty;
    }

    return false;
  }

  Future<void> _refresh() async {
    if (_fetching) return;
    await _load();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await Future.delayed(const Duration(milliseconds: 300));
      await _refresh();
    } catch (e) {
      if (mounted) {
        final l10n = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.remoteCommandFailed(e.toString())),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendPlayState(String command, {int? seekTicks}) {
    final session = _selectedSession;
    if (session == null || session.id.isEmpty) return Future.value();
    return _run(
      () => session.sessionApi.sendPlayStateCommand(
        session.id,
        command,
        seekPositionTicks: seekTicks,
      ),
    );
  }

  Future<void> _sendGeneral(String commandName, {Map<String, String>? args}) {
    final session = _selectedSession;
    if (session == null || session.id.isEmpty) return Future.value();
    return _run(
      () => session.sessionApi.sendGeneralCommand(
        session.id,
        commandName,
        arguments: args,
      ),
    );
  }

  /// Navigation commands, for driving the target's on-screen UI.
  ///
  /// These are Jellyfin GeneralCommandType values. Unlike the transport
  /// commands they only do something on a client with a focusable UI, so the
  /// D-pad is hidden unless the session advertises at least one of them.
  static const List<String> _navigationCommands = [
    'MoveUp',
    'MoveDown',
    'MoveLeft',
    'MoveRight',
    'Select',
    'Back',
  ];

  bool _supportsAnyNavigation(Map<String, dynamic> session) =>
      _navigationCommands.any((c) => _supportsCommand(session, c));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.65,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 10),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Icon(
                    Icons.settings_remote_rounded,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    l10n.remoteControlTitle,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  if (_busy)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            l10n.remoteFailedToLoadSessions,
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(height: 8),
                          TextButton(onPressed: _load, child: Text(l10n.retry)),
                        ],
                      ),
                    )
                  : _sessions.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.devices_other,
                            size: 48,
                            color: theme.colorScheme.outline,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            l10n.remoteNoSessions,
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            l10n.remoteStartPlayback,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      children: [
                        ..._sessions.map(_buildSessionTile),
                        if (_selectedSession != null) ...[
                          const SizedBox(height: 16),
                          ..._buildControls(theme),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionTile(_RemoteSession remoteSession) {
    final session = remoteSession.raw;
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final isSelected = _selectedSession?.key == remoteSession.key;
    final userName = session['UserName'] as String? ?? l10n.unknownUser;
    final client = session['Client'] as String? ?? '';
    final device = session['DeviceName'] as String? ?? '';
    final serverName = remoteSession.serverName;
    final nowPlaying = session['NowPlayingItem'] as Map<String, dynamic>?;
    final playState = session['PlayState'] as Map<String, dynamic>?;
    final isPaused = playState?['IsPaused'] as bool? ?? false;
    final runTimeTicks = (nowPlaying?['RunTimeTicks'] as num?)?.toDouble() ?? 0;
    final positionTicks =
        (playState?['PositionTicks'] as num?)?.toDouble() ?? 0;
    final progress = (nowPlaying != null && runTimeTicks > 0)
        ? (positionTicks / runTimeTicks).clamp(0.0, 1.0)
        : null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: isSelected
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => setState(
            () => _selectedSession = isSelected ? null : remoteSession,
          ),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isSelected
                    ? theme.colorScheme.primary.withValues(alpha: 0.6)
                    : theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                width: isSelected ? 1.5 : 1,
              ),
            ),
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: theme.colorScheme.primaryContainer,
                      child: Text(
                        userName.isNotEmpty ? userName[0].toUpperCase() : '?',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  userName,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 6),
                              _platformIcon(client, theme),
                            ],
                          ),
                          Text(
                            nowPlaying != null
                                ? (nowPlaying['Name'] as String? ??
                                      l10n.unknownItem)
                                : '$client · $device',
                            style: theme.textTheme.bodySmall,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                          // Which server this session is on. Only shown when
                          // more than one server is in play, so single-server
                          // users see no extra noise.
                          if (serverName.isNotEmpty && _hasMultipleServers)
                            Text(
                              serverName,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                        ],
                      ),
                    ),
                    if (nowPlaying != null)
                      Icon(
                        isPaused
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_filled,
                        size: 20,
                        color: isPaused
                            ? theme.colorScheme.outline
                            : theme.colorScheme.primary,
                      ),
                    if (isSelected)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Icon(
                          Icons.check_circle,
                          size: 18,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                  ],
                ),
                if (progress != null) ...[
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.only(left: 42),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 3,
                        backgroundColor:
                            theme.colorScheme.surfaceContainerHighest,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool get _hasMultipleServers =>
      _sessions.map((s) => s.serverId).toSet().length > 1;

  List<Widget> _buildControls(ThemeData theme) {
    final l10n = AppLocalizations.of(context);
    final session = _selectedSession!.raw;
    final nowPlaying = session['NowPlayingItem'] as Map<String, dynamic>?;
    final playState = session['PlayState'] as Map<String, dynamic>?;
    final isPaused = playState?['IsPaused'] as bool? ?? false;
    final isMuted = playState?['IsMuted'] as bool? ?? false;
    final positionTicks = (playState?['PositionTicks'] as num?)?.toInt();
    final runtimeTicks = (nowPlaying?['RunTimeTicks'] as num?)?.toInt();
    final volumeLevel = (playState?['VolumeLevel'] as num?)?.toDouble();
    final supportsSetVolume = _supportsCommand(session, 'SetVolume');

    final showDpad = _showDpadEnabled && _supportsAnyNavigation(session);

    // Nothing playing doesn't mean nothing to control: MoveUp/Down/Left/
    // Right/Select/Back and volume are general session commands the target
    // answers whether or not it has media loaded, the same way pressing an
    // arrow key on a real remote navigates an idle home screen. This used to
    // return early with just a placeholder and hide the d-pad along with it,
    // which is what made "nothing playing" read as "nothing controllable".
    if (nowPlaying == null) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Center(
            child: Column(
              children: [
                Icon(Icons.tv_off, size: 40, color: theme.colorScheme.outline),
                const SizedBox(height: 8),
                Text(
                  l10n.remoteNothingPlaying,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        if (supportsSetVolume || isMuted || volumeLevel != null) ...[
          const SizedBox(height: 4),
          _buildVolumeRow(theme, l10n, isMuted, volumeLevel, supportsSetVolume),
        ],
        if (showDpad) ...[
          const SizedBox(height: 18),
          _buildDpad(theme, session),
        ],
      ];
    }

    return [
      _buildNowPlayingCard(theme, nowPlaying, positionTicks, runtimeTicks),
      const SizedBox(height: 18),
      _buildTransportRow(theme, isPaused),
      const SizedBox(height: 18),
      _buildVolumeRow(theme, l10n, isMuted, volumeLevel, supportsSetVolume),
      if (showDpad) ...[
        const SizedBox(height: 18),
        _buildDpad(theme, session),
      ],
      const SizedBox(height: 14),
      _buildStopButton(theme, l10n),
    ];
  }

  bool get _showDpadEnabled {
    try {
      return GetIt.instance<UserPreferences>()
          .get(UserPreferences.remoteControlShowDpad);
    } catch (_) {
      return true;
    }
  }

  /// Arrows, select and back, for navigating the target client's UI.
  Widget _buildDpad(ThemeData theme, Map<String, dynamic> session) {
    Widget pad(IconData icon, String command, {double size = 46}) {
      final supported = _supportsCommand(session, command);
      return _DpadButton(
        icon: icon,
        size: size,
        // Rendered but disabled when the target does not advertise the command,
        // so the pad keeps its shape instead of collapsing into an odd cross.
        onTap: supported ? () => _sendGeneral(command) : null,
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.fromBorderSide(ThemeRegistry.active.borders.chipBorder),
      ),
      child: Column(
        children: [
          pad(Icons.keyboard_arrow_up_rounded, 'MoveUp'),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              pad(Icons.keyboard_arrow_left_rounded, 'MoveLeft'),
              const SizedBox(width: 6),
              _DpadButton(
                icon: Icons.radio_button_checked_rounded,
                size: 52,
                emphasised: true,
                onTap: _supportsCommand(session, 'Select')
                    ? () => _sendGeneral('Select')
                    : null,
              ),
              const SizedBox(width: 6),
              pad(Icons.keyboard_arrow_right_rounded, 'MoveRight'),
            ],
          ),
          const SizedBox(height: 6),
          pad(Icons.keyboard_arrow_down_rounded, 'MoveDown'),
          const SizedBox(height: 10),
          _DpadButton(
            icon: Icons.arrow_back_rounded,
            size: 46,
            onTap: _supportsCommand(session, 'Back')
                ? () => _sendGeneral('Back')
                : null,
          ),
        ],
      ),
    );
  }

  Widget _buildNowPlayingCard(
    ThemeData theme,
    Map<String, dynamic> nowPlaying,
    int? positionTicks,
    int? runtimeTicks,
  ) {
    final title = nowPlaying['Name'] as String? ?? '';
    final series = nowPlaying['SeriesName'] as String?;
    final year = (nowPlaying['ProductionYear'] as num?)?.toInt();
    final subtitle = series ?? (year != null ? '$year' : null);
    final posterUrl = _posterUrlFor(nowPlaying);
    final hasSeek =
        positionTicks != null && runtimeTicks != null && runtimeTicks > 0;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(16),
        border: Border.fromBorderSide(ThemeRegistry.active.borders.chipBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 56,
              height: 84,
              child: posterUrl == null
                  ? _posterPlaceholder(theme)
                  : BoundedNetworkImage(
                      imageUrl: posterUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => _posterPlaceholder(theme),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 10),
                if (hasSeek) _buildSeekBar(theme, positionTicks, runtimeTicks),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _posterPlaceholder(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: Icon(
        Icons.movie_outlined,
        color: theme.colorScheme.outline,
        size: 24,
      ),
    );
  }

  Widget _buildSeekBar(ThemeData theme, int positionTicks, int runtimeTicks) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            padding: EdgeInsets.zero,
          ),
          child: Slider(
            value: (_seekPosition ?? positionTicks / runtimeTicks)
                .clamp(0.0, 1.0),
            onChanged: (v) => setState(() => _seekPosition = v),
            onChangeEnd: (v) {
              final target = (v * runtimeTicks).round();
              _seekPosition = null;
              _sendPlayState('Seek', seekTicks: target);
            },
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _ticksToTime(positionTicks),
              style: theme.textTheme.labelSmall,
            ),
            Text(
              _ticksToTime(runtimeTicks),
              style: theme.textTheme.labelSmall,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTransportRow(ThemeData theme, bool isPaused) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _TransportButton(
          icon: Icons.skip_previous_rounded,
          onTap: () => _sendPlayState('PreviousTrack'),
        ),
        const SizedBox(width: 18),
        _TransportButton(
          icon: Icons.replay_10_rounded,
          onTap: () => _sendPlayState('Rewind'),
        ),
        const SizedBox(width: 18),
        _PrimaryTransportButton(
          icon: isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          onTap: () => _sendPlayState('PlayPause'),
        ),
        const SizedBox(width: 18),
        _TransportButton(
          icon: Icons.forward_10_rounded,
          onTap: () => _sendPlayState('FastForward'),
        ),
        const SizedBox(width: 18),
        _TransportButton(
          icon: Icons.skip_next_rounded,
          onTap: () => _sendPlayState('NextTrack'),
        ),
      ],
    );
  }

  Widget _buildVolumeRow(
    ThemeData theme,
    AppLocalizations l10n,
    bool isMuted,
    double? volumeLevel,
    bool supportsSetVolume,
  ) {
    if (!supportsSetVolume) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _ControlButton(
            icon: isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
            label: isMuted ? l10n.unmute : l10n.mute,
            onTap: () => _sendGeneral(isMuted ? 'Unmute' : 'Mute'),
          ),
          const SizedBox(width: 8),
          _ControlButton(
            icon: Icons.volume_down_rounded,
            label: l10n.sessionVolumeDown,
            onTap: () => _sendGeneral('VolumeDown'),
          ),
          const SizedBox(width: 8),
          _ControlButton(
            icon: Icons.volume_up_rounded,
            label: l10n.sessionVolumeUp,
            onTap: () => _sendGeneral('VolumeUp'),
          ),
        ],
      );
    }

    final value = (_volume ?? volumeLevel ?? 100).clamp(0.0, 100.0);
    final IconData volumeIcon;
    if (isMuted || value == 0) {
      volumeIcon = Icons.volume_off_rounded;
    } else if (value < 50) {
      volumeIcon = Icons.volume_down_rounded;
    } else {
      volumeIcon = Icons.volume_up_rounded;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.fromBorderSide(ThemeRegistry.active.borders.chipBorder),
      ),
      child: Row(
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(volumeIcon),
            color: theme.colorScheme.onSurfaceVariant,
            tooltip: isMuted ? l10n.unmute : l10n.mute,
            onPressed: () => _sendGeneral(isMuted ? 'Unmute' : 'Mute'),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
              child: Slider(
                min: 0,
                max: 100,
                value: value,
                onChanged: (v) => setState(() => _volume = v),
                onChangeEnd: (v) {
                  _volume = null;
                  _sendGeneral(
                    'SetVolume',
                    args: {'Volume': v.round().toString()},
                  );
                },
              ),
            ),
          ),
          SizedBox(
            width: 36,
            child: Text(
              '${value.round()}%',
              textAlign: TextAlign.end,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStopButton(ThemeData theme, AppLocalizations l10n) {
    return Center(
      child: TextButton.icon(
        onPressed: () => _sendPlayState('Stop'),
        icon: const Icon(Icons.stop_rounded, size: 18),
        label: Text(l10n.stop),
        style: TextButton.styleFrom(
          foregroundColor: theme.colorScheme.error,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: theme.colorScheme.error.withValues(alpha: 0.4),
            ),
          ),
        ),
      ),
    );
  }

  String _ticksToTime(int ticks) {
    final duration = Duration(microseconds: ticks ~/ 10);
    final h = duration.inHours;
    final m = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  bool _supportsCommand(Map<String, dynamic> session, String command) {
    final commands = session['SupportedCommands'];
    return commands is List && commands.whereType<String>().contains(command);
  }

  String? _posterUrlFor(Map<String, dynamic> nowPlaying) {
    final id = nowPlaying['Id']?.toString();
    if (id == null || id.isEmpty) return null;
    // Must be the selected session's own server: the item id is meaningless on
    // any other one, and the poster would 404 or show the wrong artwork.
    final client =
        _selectedSession?.client ?? GetIt.instance<MediaServerClient>();
    return client.imageApi.getPrimaryImageUrl(id, maxHeight: 300);
  }

  Widget _platformIcon(String client, ThemeData theme) {
    final lc = client.toLowerCase();
    final IconData icon;
    if (lc.contains('android tv') ||
        lc.contains('fire tv') ||
        lc.contains('apple tv') ||
        lc.contains('roku')) {
      icon = Icons.tv;
    } else if (lc.contains('android')) {
      icon = Icons.android;
    } else if (lc.contains('ios') ||
        lc.contains('iphone') ||
        lc.contains('ipad') ||
        lc.contains('apple')) {
      icon = Icons.phone_iphone;
    } else if (lc.contains('web') || lc.contains('browser')) {
      icon = Icons.language;
    } else {
      icon = Icons.devices_other;
    }
    return Icon(icon, size: 13, color: theme.colorScheme.onSurfaceVariant);
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ControlButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = theme.colorScheme.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 28, color: fg),
            const SizedBox(height: 2),
            Text(label, style: theme.textTheme.labelSmall?.copyWith(color: fg)),
          ],
        ),
      ),
    );
  }
}

/// One key of the remote's D-pad.
///
/// A null [onTap] means the target session does not advertise that command; the
/// key stays in place, greyed out, rather than vanishing and leaving a lopsided
/// cross.
class _DpadButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final bool emphasised;
  final VoidCallback? onTap;

  const _DpadButton({
    required this.icon,
    required this.size,
    required this.onTap,
    this.emphasised = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onTap != null;
    final background = emphasised
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest;
    final foreground = emphasised
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurface;

    return Semantics(
      button: true,
      enabled: enabled,
      child: Material(
        color: background.withValues(alpha: enabled ? 1 : 0.35),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: Icon(
                icon,
                size: size * 0.55,
                color: foreground.withValues(alpha: enabled ? 1 : 0.4),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TransportButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _TransportButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkResponse(
      onTap: onTap,
      radius: 28,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(icon, size: 28, color: theme.colorScheme.onSurface),
      ),
    );
  }
}

class _PrimaryTransportButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _PrimaryTransportButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.primary,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Icon(icon, size: 32, color: theme.colorScheme.onPrimary),
        ),
      ),
    );
  }
}
