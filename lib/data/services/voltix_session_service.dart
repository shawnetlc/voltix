import 'dart:async';

import 'package:get_it/get_it.dart';
import 'package:logger/logger.dart';

import '../../auth/repositories/session_repository.dart';
import '../../auth/store/voltix_session_store.dart';
import '../../ui/navigation/app_router.dart';
import '../../ui/navigation/destinations.dart';
import 'user_settings_sync_service.dart';
import 'voltix_api_service.dart';

/// Keeps the Voltix session alive by pinging the backend periodically.
///
/// If the backend reports that the user's subscription is inactive
/// (admin suspended), this service automatically clears the local session
/// and redirects to the login screen.
class VoltixSessionService {
  static const _pingInterval = Duration(minutes: 5);

  final _logger = Logger();
  Timer? _pingTimer;
  bool _isRunning = false;

  /// Starts the periodic ping. Safe to call multiple times — idempotent.
  void start() {
    if (_isRunning) return;
    _isRunning = true;
    _logger.i('[VoltixSession] Starting periodic ping (every ${_pingInterval.inMinutes}m)');
    _pingTimer = Timer.periodic(_pingInterval, (_) => _doPing());
    
    try {
      if (GetIt.instance.isRegistered<UserSettingsSyncService>()) {
        GetIt.instance<UserSettingsSyncService>().scheduleAutoSync();
      }
    } catch (_) {}
    
    // Also do an immediate ping on start
    _doPing();
  }

  /// Stops the periodic ping.
  void stop() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _isRunning = false;
    
    try {
      if (GetIt.instance.isRegistered<UserSettingsSyncService>()) {
        GetIt.instance<UserSettingsSyncService>().cancelAutoSync();
      }
    } catch (_) {}
  }

  Future<void> _doPing() async {
    try {
      final voltixStore = GetIt.instance<VoltixSessionStore>();
      if (!voltixStore.hasSession) return;

      final voltixApi = GetIt.instance<VoltixApiService>();
      final result = await voltixApi.ping(voltixStore.sessionToken!);

      final active = result['active'] as bool? ?? true;
      final reason = result['reason'] as String? ?? 'ok';

      if (!active) {
        _logger.w('[VoltixSession] Session no longer active: $reason');

        if (reason == 'subscription_inactive' || reason == 'user_not_found' || reason == 'no_session') {
          // Admin suspended or session invalidated — force logout
          await _forceLogout();
        }
      }
    } catch (e) {
      _logger.w('[VoltixSession] Ping failed (will retry): $e');
      // Don't force logout on network errors — the user may be temporarily offline
    }
  }

  Future<void> _forceLogout() async {
    stop();

    try {
      final voltixStore = GetIt.instance<VoltixSessionStore>();
      await voltixStore.clear();
    } catch (_) {}

    try {
      final sessionRepo = GetIt.instance<SessionRepository>();
      await sessionRepo.destroyCurrentSession();
    } catch (_) {}

    appRouter.go(Destinations.voltixLogin);
  }
}
