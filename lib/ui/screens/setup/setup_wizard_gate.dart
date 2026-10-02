import 'package:get_it/get_it.dart';
import 'package:server_core/server_core.dart';

import '../../../auth/store/voltix_session_store.dart';

import '../../../data/services/connectivity_service.dart';
import '../../../data/services/media_server_client_factory.dart';
import '../../../data/services/plugin_sync_service.dart';
import '../../../preference/user_preferences.dart';

/// Which questions the first-run wizard still has to ask, in the order shown.
///
/// [navbar] leads because it is the frame everything after it sits in.
/// [tour] is never suppressed, since it asks nothing that could already have
/// been answered.
/// [cloudSync] is never returned by [remainingSteps]: whether it applies
/// depends on a network probe, and the router calls into this class on every
/// navigation. The wizard appends it itself once the probe comes back.
enum SetupStep { navbar, mediaBar, homeRows, detailStyle, background, deviceTier, network, tour, cloudSync, taste }

/// Decides whether the wizard runs, and for which steps.
///
/// The router asks this on every navigation, so [shouldRun] stays a couple of
/// preference reads and never touches the network. Anything slow happens
/// inside the wizard itself.
class SetupWizardGate {
  SetupWizardGate(this._prefs);

  final UserPreferences _prefs;

  /// Set when a run is abandoned before it can finish, because the server was
  /// out of reach or its settings never arrived. Without it the router would
  /// send the user straight back in on the next navigation and strand them.
  /// In memory only, so the next launch tries again.
  bool _deferredThisLaunch = false;

  /// Set while an explicit re-run from settings is in flight, so the router
  /// leaves it alone even though the server is already marked as set up.
  bool _rerunning = false;

  /// The id the client factory filed this client under, which is also the id
  /// the sync service keys its per-server state by.
  String? _serverIdFor(MediaServerClient client) {
    if (!GetIt.instance.isRegistered<MediaServerClientFactory>()) return null;
    for (final entry
        in GetIt.instance<MediaServerClientFactory>().clients.entries) {
      if (identical(entry.value, client)) return entry.key;
    }
    return null;
  }

  /// Keyed by server id rather than address, so moving a server to a new URL
  /// doesn't read as one nobody has set up yet. It is the same pairing the
  /// settings themselves are scoped by, so the flag can't drift from the
  /// answers it stands for.
  String? _serverKeyFor(MediaServerClient client) {
    final userId = client.userId;
    if (userId == null || userId.isEmpty) return null;
    return '${_serverIdFor(client) ?? client.baseUrl}_$userId';
  }

  bool _isCompleteFor(String serverKey) =>
      _prefs.get(UserPreferences.setupWizardVersionForServer(serverKey)) >=
      UserPreferences.setupWizardVersion;

  /// The Voltix account the wizard was answered for.
  ///
  /// The server+user key alone was not stable across sign-out/sign-in: the
  /// Jellyfin client is rebuilt (and, with direct streaming, re-registered),
  /// so the key could resolve to the server address one time and the server
  /// id the next - and a key nobody had written reads as "never set up". The
  /// Voltix username is the same every time this person signs in.
  String? _voltixAccountKey() {
    if (!GetIt.instance.isRegistered<VoltixSessionStore>()) return null;
    final store = GetIt.instance<VoltixSessionStore>();
    final username = (store.username ?? '').trim().toLowerCase();
    if (username.isEmpty) return null;
    return 'voltix_$username';
  }

  bool _isCompleteForVoltixAccount() {
    final key = _voltixAccountKey();
    return key != null && _isCompleteFor(key);
  }

  bool shouldRun(MediaServerClient client) {
    if (GetIt.instance.isRegistered<VoltixSessionStore>() &&
        GetIt.instance<VoltixSessionStore>().isKidsProfile) {
      return false;
    }
    if (_rerunning) return true;
    if (_deferredThisLaunch) return false;

    // A server we can't reach can neither serve the previews nor resolve the
    // settings the wizard would otherwise overwrite. Leave the flag unwritten
    // so a later launch, on a better network, still gets the chance.
    if (GetIt.instance.isRegistered<ConnectivityService>() &&
        !GetIt.instance<ConnectivityService>().canReachServer) {
      return false;
    }

    if (_isCompleteForVoltixAccount()) return false;
    final serverKey = _serverKeyFor(client);
    if (serverKey == null) return false;
    if (_isCompleteFor(serverKey)) return false;
    return remainingSteps().isNotEmpty;
  }

  /// The steps still worth asking, in order.
  ///
  /// Always the full four defaults (plus the tour) the first time a server
  /// hasn't been set up on this device, even when a plugin-synced profile
  /// from another device already filled preferences in behind the scenes --
  /// each step's card still opens pre-selected to whatever value is already
  /// there (see e.g. _buildNavbarStep reading _prefs as its fallback), so a
  /// synced choice is offered rather than applied for the user. It only
  /// counts once the user has actually pressed Next on it here. A deliberate
  /// re-run asks everything for the same reason: going looking for it says
  /// more than the stored values do.
  List<SetupStep> remainingSteps() {
    if (_rerunning) {
      return SetupStep.values
          .where((step) =>
              step != SetupStep.cloudSync && step != SetupStep.taste)
          .toList();
    }

    return const [
      SetupStep.navbar,
      SetupStep.mediaBar,
      SetupStep.homeRows,
      SetupStep.detailStyle,
      SetupStep.background,
      SetupStep.deviceTier,
      SetupStep.network,
      SetupStep.tour,
    ];
  }

  /// Waits for the server to hand over this user's settings.
  ///
  /// The plugin resolves a profile shortly after sign-in and applies it whole.
  /// Answering before that lands means watching the answers get overwritten a
  /// second later.
  Future<bool> waitForSettings(
    MediaServerClient client, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (!GetIt.instance.isRegistered<PluginSyncService>()) return true;
    final sync = GetIt.instance<PluginSyncService>();
    // Has to be the id the sync service wrote under. Reading without it falls
    // back to the address, which is a key nothing ever sets, so the wait could
    // only ever time out.
    final serverId = _serverIdFor(client);

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (sync.isSyncInitializedForServer(client, serverId: serverId)) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    // A server with no plugin on it has no profile coming, so there is nothing
    // left to wait for. One that has the plugin is still going to push, and it
    // would land on top of anything chosen here.
    return !sync.pluginAvailable;
  }

  /// Stand down for the rest of this launch without marking anything done.
  void deferThisLaunch() {
    // The re-run flag goes with it. shouldRun answers true for a re-run before
    // it looks at anything else, so leaving it set sends the router straight
    // back here and the wizard never stops loading.
    _rerunning = false;
    _deferredThisLaunch = true;
  }

  /// Marks this server and user as set up, whether they answered every question
  /// or skipped the lot. Skipping is an answer: it means stop asking.
  Future<void> markComplete(MediaServerClient client) async {
    _rerunning = false;
    // Saved against the Voltix account as well as the server+user pair, so
    // signing out and back in (or a rebuilt client) doesn't ask again.
    final accountKey = _voltixAccountKey();
    if (accountKey != null) {
      await _prefs.set(
        UserPreferences.setupWizardVersionForServer(accountKey),
        UserPreferences.setupWizardVersion,
      );
    }
    final serverKey = _serverKeyFor(client);
    if (serverKey == null) return;
    await _prefs.set(
      UserPreferences.setupWizardVersionForServer(serverKey),
      UserPreferences.setupWizardVersion,
    );
  }

  /// Asks every question again, whatever the stored values say.
  ///
  /// Cleared by [markComplete], which every way out of the wizard goes through.
  void beginRerun() {
    _rerunning = true;
    _deferredThisLaunch = false;
  }
}
