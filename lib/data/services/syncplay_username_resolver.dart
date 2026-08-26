import 'package:get_it/get_it.dart';
import 'package:logger/logger.dart';

import '../../auth/repositories/user_repository.dart';
import '../../auth/store/voltix_session_store.dart';
import 'voltix_api_service.dart';

/// Turns Jellyfin/Lumistream usernames into Voltix display names.
///
/// SyncPlay participant lists are whatever Jellyfin reports, which is the
/// provisioned upstream account name (`lumistream_ab12`, per-tier accounts,
/// pooled streaming accounts) rather than anything the subscriber recognises.
/// Only the Voltix backend knows which subscriber owns which Jellyfin identity,
/// so names are resolved there in batches and cached here for the session.
///
/// This replaces a purely local heuristic that inspected the name's prefix. That
/// approach could not work: it mapped *every* participant whose name began with
/// `lumistream`/`jellyfin`/`admin_`/`user_` onto the local user's own Voltix
/// name, so a group of four people rendered as the same person four times.
class SyncPlayUsernameResolver {
  /// Names are resolved once per app run; Jellyfin identities do not churn.
  final Map<String, String> _cache = {};
  final Set<String> _unresolved = {};
  final Set<String> _inFlight = {};
  final Logger _logger = Logger();

  static const int _maxBatchSize = 50;

  /// Cached Voltix name for [jellyfinUsername], or null if not resolved yet.
  String? cached(String jellyfinUsername) =>
      _cache[jellyfinUsername.trim().toLowerCase()];

  /// True when we asked the backend and it had no match, so callers can stop
  /// waiting and fall back to a placeholder.
  bool isKnownUnresolvable(String jellyfinUsername) =>
      _unresolved.contains(jellyfinUsername.trim().toLowerCase());

  /// Resolves any names not already known. Returns true when the cache changed,
  /// so the caller knows whether to notify listeners.
  Future<bool> resolve(Iterable<String> jellyfinUsernames) async {
    final pending = <String>[];
    for (final raw in jellyfinUsernames) {
      final name = raw.trim();
      if (name.isEmpty) continue;
      final key = name.toLowerCase();
      if (_cache.containsKey(key) ||
          _unresolved.contains(key) ||
          _inFlight.contains(key)) {
        continue;
      }
      pending.add(name);
    }
    if (pending.isEmpty) return false;

    // Resolve the local user without a round trip — we already know who they are.
    var changed = false;
    final localNames = _localIdentityNames();
    if (localNames.voltixName != null) {
      for (final name in List<String>.from(pending)) {
        if (localNames.matches(name)) {
          _cache[name.toLowerCase()] = localNames.voltixName!;
          pending.remove(name);
          changed = true;
        }
      }
    }
    if (pending.isEmpty) return changed;

    _inFlight.addAll(pending.map((n) => n.toLowerCase()));
    try {
      for (var i = 0; i < pending.length; i += _maxBatchSize) {
        final batch = pending.sublist(
          i,
          i + _maxBatchSize > pending.length ? pending.length : i + _maxBatchSize,
        );
        final mapping = await _fetch(batch);
        for (final name in batch) {
          final key = name.toLowerCase();
          final resolved = mapping[key];
          if (resolved != null && resolved.trim().isNotEmpty) {
            _cache[key] = resolved.trim();
          } else {
            _unresolved.add(key);
          }
          changed = true;
        }
      }
    } catch (e) {
      _logger.w('SyncPlay username resolution failed', error: e);
      // Leave the names unresolved rather than caching a wrong answer; a later
      // refresh can retry.
    } finally {
      _inFlight.removeAll(pending.map((n) => n.toLowerCase()));
    }
    return changed;
  }

  Future<Map<String, String>> _fetch(List<String> batch) async {
    final api = GetIt.instance<VoltixApiService>();
    String? token;
    try {
      token = GetIt.instance<VoltixSessionStore>().sessionToken;
    } catch (_) {}
    return api.resolveSyncPlayUsernames(
      jellyfinUsernames: batch,
      sessionToken: token,
    );
  }

  _LocalIdentity _localIdentityNames() {
    try {
      final store = GetIt.instance<VoltixSessionStore>();
      final voltixName = (store.displayName != null &&
              store.displayName!.trim().isNotEmpty)
          ? store.displayName!.trim()
          : store.username?.trim();

      String? jellyfinName;
      try {
        if (GetIt.instance.isRegistered<UserRepository>()) {
          jellyfinName = GetIt.instance<UserRepository>().currentUser?.name.trim();
        }
      } catch (_) {}

      return _LocalIdentity(
        voltixName: (voltixName != null && voltixName.isNotEmpty)
            ? voltixName
            : null,
        voltixUsername: store.username?.trim(),
        jellyfinUsername: jellyfinName,
      );
    } catch (_) {
      return const _LocalIdentity(
        voltixName: null,
        voltixUsername: null,
        jellyfinUsername: null,
      );
    }
  }

  void clear() {
    _cache.clear();
    _unresolved.clear();
    _inFlight.clear();
  }
}

class _LocalIdentity {
  final String? voltixName;
  final String? voltixUsername;
  final String? jellyfinUsername;

  const _LocalIdentity({
    required this.voltixName,
    required this.voltixUsername,
    this.jellyfinUsername,
  });

  /// Checks if the candidate matches the local user's Voltix username, display name,
  /// or their connected Jellyfin server username, ensuring their Voltix identity is injected.
  bool matches(String candidate) {
    final c = candidate.trim().toLowerCase();
    if (c.isEmpty) return false;
    if (voltixUsername != null && voltixUsername!.toLowerCase() == c) return true;
    if (voltixName != null && voltixName!.toLowerCase() == c) return true;
    if (jellyfinUsername != null && jellyfinUsername!.toLowerCase() == c) return true;
    return false;
  }
}
