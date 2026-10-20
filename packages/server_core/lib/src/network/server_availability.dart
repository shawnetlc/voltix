import 'dart:async';

/// Tracks whether upstream media servers are currently reachable / permitting
/// this app, and acts as a lightweight circuit-breaker.
///
/// When a server answers a request with 403 (for example an upstream access
/// block), the breaker for that host "opens" for [cooldown]. While open the
/// Dio interceptor fails requests to that host immediately instead of sending
/// them, so the app stops hammering a server that is refusing it, and the UI
/// can show a calm "server unavailable" state instead of spinning on endless
/// retries. Any successful response closes the breaker again.
///
/// Pure Dart (no Flutter dependency): the UI listens via [changes] with a
/// StreamBuilder, or reads [anyUnavailable] / [isBlocked] synchronously.
class ServerAvailability {
  ServerAvailability._();
  static final ServerAvailability instance = ServerAvailability._();

  /// How long a host stays "blocked" after a 403 before the app tries again.
  ///
  /// Zero = breaker off. A single 403 (normal for admin / plugin endpoints on
  /// a non-admin shared login) used to block EVERY request to the server for
  /// two minutes, which emptied home rows, taste rows and the wizard. Stock
  /// Jellyfin clients have no such breaker; each request now stands alone.
  static Duration cooldown = Duration.zero;

  final Map<String, DateTime> _blockedUntil = {};
  final StreamController<bool> _controller =
      StreamController<bool>.broadcast();

  /// Emits whenever the "any server unavailable" state changes.
  Stream<bool> get changes => _controller.stream;

  /// True when at least one host's breaker is currently open.
  bool get anyUnavailable {
    _prune();
    return _blockedUntil.isNotEmpty;
  }

  // Key on the full base URL (not just host): the three Voltix servers share
  // one host (api.voltixstudio.com) and differ only by path, so per-host keying
  // would let one server's block take the others down with it.
  String _key(String baseUrl) {
    final trimmed = baseUrl.trim();
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  /// True while the breaker for [baseUrl] is open (caller should fail fast).
  bool isBlocked(String baseUrl) {
    final key = _key(baseUrl);
    final until = _blockedUntil[key];
    if (until == null) return false;
    if (!DateTime.now().isBefore(until)) {
      _blockedUntil.remove(key);
      _emit();
      return false;
    }
    return true;
  }

  /// Open the breaker for [baseUrl] after a 403 / access block.
  void markBlocked(String baseUrl) {
    final was = anyUnavailable;
    _blockedUntil[_key(baseUrl)] = DateTime.now().add(cooldown);
    if (!was) _emit();
  }

  /// A successful call proves the host is reachable: close its breaker.
  void markAvailable(String baseUrl) {
    if (_blockedUntil.remove(_key(baseUrl)) != null) _emit();
  }

  void _prune() {
    final now = DateTime.now();
    _blockedUntil.removeWhere((_, until) => !now.isBefore(until));
  }

  void _emit() {
    if (!_controller.isClosed) _controller.add(anyUnavailable);
  }
}
