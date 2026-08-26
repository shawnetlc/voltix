import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:logger/logger.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:server_core/server_core.dart';

import 'websocket_message_parser.dart';

abstract class ServerWebSocketClient {
  Stream<ServerWebSocketMessage> get messages;

  /// True once the socket handshake has completed and messages can arrive.
  ///
  /// SyncPlay needs this: a join that lands before the socket is live on the
  /// target server never receives the GroupJoined push, so the group looks
  /// joined locally while no group state ever arrives.
  bool get isConnected;

  Future<void> connect();
  Future<void> disconnect();
  void dispose();

  factory ServerWebSocketClient.forServer(MediaServerClient client) {
    return switch (client.serverType) {
      ServerType.jellyfin => JellyfinWebSocketClient(client),
      ServerType.emby => EmbyWebSocketClient(client),
    };
  }
}

class JellyfinWebSocketClient implements ServerWebSocketClient {
  final MediaServerClient _client;
  final _logger = Logger();

  static const _maxReconnectAttempts = 12;
  static const _keepAliveIntervalSeconds = 30;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _keepAliveTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _disposed = false;
  bool _connected = false;

  final _messageController =
      StreamController<ServerWebSocketMessage>.broadcast();

  JellyfinWebSocketClient(this._client);

  @override
  Stream<ServerWebSocketMessage> get messages => _messageController.stream;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect() async {
    await disconnect();
    if (_disposed) return;

    final wsUrl =
        _client.baseUrl.replaceFirst('http', 'ws');
    final token = _client.accessToken ?? '';

    try {
      _channel = WebSocketChannel.connect(
        Uri.parse('$wsUrl/socket?api_key=$token'),
      );
      await _channel!.ready;
      _reconnectAttempt = 0;
      _connected = true;
      _startKeepAlive();

      _subscription = _channel!.stream.listen(
        (data) {
          final msg = WebSocketMessageParser.parse(data.toString());
          if (msg != null) _messageController.add(msg);
        },
        onError: (error) {
          _logger.e('Jellyfin WebSocket error', error: error);
          _connected = false;
          _scheduleReconnect();
        },
        onDone: () {
          _logger.i('Jellyfin WebSocket closed');
          _connected = false;
          _keepAliveTimer?.cancel();
          _scheduleReconnect();
        },
      );
    } catch (e) {
      _logger.e('Jellyfin WebSocket connection failed', error: e);
      _connected = false;
      _scheduleReconnect();
    }
  }

  void _startKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(
      const Duration(seconds: _keepAliveIntervalSeconds),
      (_) => _channel?.sink.add('{"MessageType":"KeepAlive"}'),
    );
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    if (_reconnectAttempt >= _maxReconnectAttempts) {
      _logger.w('Jellyfin WebSocket max reconnect attempts reached');
      return;
    }

    final baseDelay = min(30000, 1000 * (1 << min(_reconnectAttempt, 5)));
    final jitter = Random().nextInt(baseDelay ~/ 2 + 1);
    _reconnectAttempt++;

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(
      Duration(milliseconds: baseDelay + jitter),
      () => connect(),
    );
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
  }

  @override
  void dispose() {
    _disposed = true;
    disconnect();
    _messageController.close();
  }
}

class EmbyWebSocketClient implements ServerWebSocketClient {
  final MediaServerClient _client;
  final _logger = Logger();

  static const _maxReconnectAttempts = 12;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _keepAliveTimer;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _disposed = false;
  bool _connected = false;

  final _messageController =
      StreamController<ServerWebSocketMessage>.broadcast();

  EmbyWebSocketClient(this._client);

  @override
  Stream<ServerWebSocketMessage> get messages => _messageController.stream;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> connect() async {
    await disconnect();
    if (_disposed) return;

    final token = _client.accessToken;
    if (token == null) return;

    final wsUrl =
        _client.baseUrl.replaceFirst('http', 'ws');
    final deviceId = Uri.encodeComponent(_client.deviceInfo.id);

    try {
      _channel = WebSocketChannel.connect(
        Uri.parse('$wsUrl/embywebsocket?api_key=$token&deviceId=$deviceId'),
      );
      await _channel!.ready;
      _reconnectAttempt = 0;
      _connected = true;

      _subscription = _channel!.stream.listen(
        _handleRawMessage,
        onError: (error) {
          _logger.e('Emby WebSocket error', error: error);
          _connected = false;
          _scheduleReconnect();
        },
        onDone: () {
          _logger.i('Emby WebSocket closed');
          _connected = false;
          _keepAliveTimer?.cancel();
          _scheduleReconnect();
        },
      );
    } catch (e) {
      _logger.e('Emby WebSocket connection failed', error: e);
      _connected = false;
      _scheduleReconnect();
    }
  }

  void _handleRawMessage(dynamic data) {
    try {
      final json = jsonDecode(data.toString()) as Map<String, dynamic>;
      final messageType = json['MessageType'] as String?;

      if (messageType == 'ForceKeepAlive') {
        final intervalSeconds =
            (json['Data'] as num?)?.toInt() ?? 60;
        _startKeepAlive(intervalSeconds);
        return;
      }

      final msg = WebSocketMessageParser.parseJson(json);
      if (msg != null) _messageController.add(msg);
    } catch (e) {
      _logger.w('Failed to parse Emby WebSocket message', error: e);
    }
  }

  void _startKeepAlive(int intervalSeconds) {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(
      Duration(seconds: intervalSeconds ~/ 2),
      (_) {
        _channel?.sink.add('{"MessageType":"KeepAlive"}');
      },
    );
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    if (_reconnectAttempt >= _maxReconnectAttempts) {
      _logger.w('Emby WebSocket max reconnect attempts reached');
      return;
    }

    final baseDelay = min(30000, 1000 * (1 << min(_reconnectAttempt, 5)));
    final jitter = Random().nextInt(baseDelay ~/ 2 + 1);
    _reconnectAttempt++;

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(
      Duration(milliseconds: baseDelay + jitter),
      () => connect(),
    );
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
  }

  @override
  void dispose() {
    _disposed = true;
    disconnect();
    _messageController.close();
  }
}

class SocketHandler {
  static const Duration _readyPollInterval = Duration(milliseconds: 150);

  ServerWebSocketClient? _wsClient;
  final _eventController =
      StreamController<ServerWebSocketMessage>.broadcast();
  StreamSubscription? _forwardSub;

  /// Server id the socket is currently attached to, so callers can tell whether
  /// realtime pushes for a given server will actually reach them.
  String? _connectedServerId;

  Stream<ServerWebSocketMessage> get events => _eventController.stream;

  String? get connectedServerId => _connectedServerId;

  bool get isConnected => _wsClient?.isConnected ?? false;

  bool isConnectedTo(String serverId) =>
      _connectedServerId == serverId && isConnected;

  void connectTo(MediaServerClient client, {String? serverId}) {
    disconnect();
    _connectedServerId = serverId;
    _wsClient = ServerWebSocketClient.forServer(client);
    _forwardSub = _wsClient!.messages.listen(_eventController.add);
    _wsClient!.connect();
  }

  /// Waits until the socket for [serverId] has completed its handshake.
  ///
  /// Returns false on timeout. SyncPlay calls this after switching servers so a
  /// join is not issued into a socket that is still connecting - the server's
  /// GroupJoined push would be sent to a socket that no longer exists and the
  /// client would sit in a group it has no state for.
  Future<bool> waitUntilConnectedTo(
    String serverId, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (isConnectedTo(serverId)) return true;
      await Future<void>.delayed(_readyPollInterval);
    }
    return isConnectedTo(serverId);
  }

  void disconnect() {
    _forwardSub?.cancel();
    _forwardSub = null;
    _wsClient?.dispose();
    _wsClient = null;
    _connectedServerId = null;
  }

  void dispose() {
    disconnect();
    _eventController.close();
  }
}
