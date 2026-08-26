import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:voltix_design/voltix_design.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';


import '../../../auth/models/user.dart';
import '../../../auth/repositories/server_repository.dart';
import '../../../auth/repositories/session_repository.dart';
import '../../../auth/repositories/user_repository.dart';
import '../../../auth/store/authentication_preferences.dart';
import '../../../auth/store/authentication_store.dart';
import '../../../auth/store/credential_store.dart';
import '../../../auth/store/voltix_session_store.dart';
import '../../../data/services/media_server_client_factory.dart';
import '../../../data/services/user_settings_sync_service.dart';
import '../../../data/services/voltix_api_service.dart';
import '../../../data/services/voltix_session_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../util/pin_code_util.dart';
import '../../../preference/preference_constants.dart';
import '../../../preference/user_preferences.dart';
import '../../navigation/destinations.dart';
import '../../widgets/overlay_sheet.dart';
import '../../widgets/pin_entry_dialog.dart';
import '../../widgets/focus/request_initial_focus.dart';


class StartupScreen extends StatefulWidget {
  final bool bootstrapActiveSession;

  const StartupScreen({
    super.key,
    this.bootstrapActiveSession = false,
  });

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeIn,
    );
    _fadeController.forward();
    _initialize();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      final session = GetIt.instance<SessionRepository>();
      final serverRepo = GetIt.instance<ServerRepository>();
      final credentialStore = GetIt.instance<CredentialStore>();
      final authPrefs = GetIt.instance<AuthenticationPreferences>();
      final voltixStore = GetIt.instance<VoltixSessionStore>();

    // Wait for the session to become ready WITHOUT losing the event.
    //
    // SessionRepository.stateStream is a plain broadcast StreamController with
    // no replay and no seed value, so anything emitted before a listener
    // attaches is gone for good. The old code checked the state and only then
    // called firstWhere, leaving a window: if the session reached ready between
    // the check and the subscription, the event was already delivered to nobody
    // and the await never returned - stranding the app on the splash logo and
    // spinner, permanently, with no timeout to recover.
    //
    // That window is timing-dependent, which is why it was intermittent and
    // noticeably worse on relaunch: a warm start reaches ready sooner, so it is
    // more likely to land before the subscription exists.
    //
    // Subscribing first and re-checking afterwards closes the window - once the
    // subscription is live the transition cannot be missed, and if it already
    // happened the re-check sees it. The timeout is a backstop so a genuinely
    // stuck session still lets the user reach a screen instead of hanging.
    if (session.state != SessionState.ready) {
      final ready = session.stateStream
          .firstWhere((s) => s == SessionState.ready)
          .timeout(
            const Duration(seconds: 15),
            onTimeout: () => SessionState.ready,
          );
      if (session.state != SessionState.ready) {
        await ready;
      } else {
        // Already ready - do not await, but let the future settle via its
        // timeout so the stream subscription is released.
        unawaited(ready);
      }
    }

    await serverRepo.loadStoredServers().timeout(
      const Duration(seconds: 15),
      onTimeout: () {},
    );
    await voltixStore.load();

    if (widget.bootstrapActiveSession && session.activeUserId != null) {
      _navigate(Destinations.home);
      return;
    }

    final behavior = authPrefs.loginBehavior;
    String? targetUserId;

    // Only the user id is needed: its sole consumer is the PIN check below.
    //
    // A targetServerId was also tracked here, described as a fallback so an
    // unset behaviour-specific id would still land on the right server's
    // user-select page. Nothing ever read it - every fallback path now routes to
    // the Voltix login (_fallbackToLoginOrServerSelect) - so both the variable
    // and that comment described behaviour this screen no longer has.
    if (behavior == UserSelectBehavior.lastUser) {
      targetUserId = authPrefs.savedLastUserId;
    } else if (behavior == UserSelectBehavior.currentUser) {
      targetUserId = authPrefs.savedAutoLoginUserId;
    }

    bool pinEnabledForAutoLoginUser = false;
    if (targetUserId != null && targetUserId.isNotEmpty) {
      final store = GetIt.instance<PreferenceStore>();
      final pinUtil = PinCodeUtil(store, targetUserId);
      pinEnabledForAutoLoginUser = pinUtil.isPinEnabled;
    }

    // Also bounded: restoring a stored session can reach the media server, and
    // there is typically only a session to restore once a device has been
    // linked - the same path the freeze was isolated to. Falling back to "not
    // restored" sends the user to login, which is recoverable; hanging is not.
    final restored = (authPrefs.shouldAlwaysAuthenticate || pinEnabledForAutoLoginUser)
        ? false
        : await session.restoreSession().timeout(
            const Duration(seconds: 20),
            onTimeout: () => false,
          );

    if (!mounted) return;

    if (credentialStore.consumeSecureStorageUnavailable()) {
      await _showSecureStorageWarning();
      if (!mounted) return;
    }

    if (restored && session.activeUserId != null) {
      final store = GetIt.instance<PreferenceStore>();
      final pinUtil = PinCodeUtil(store, session.activeUserId!);

      if (pinUtil.isPinEnabled) {
        final verified = await PinEntryDialog.show(
          context,
          mode: PinEntryMode.verify,
          onVerify: pinUtil.verifyPin,
          onForgotPin: () {
            _fallbackToLoginOrServerSelect();
          },
        );

        if (!verified) {
          _fallbackToLoginOrServerSelect();
          return;
        }
      }

      _navigate(Destinations.home);
    } else {
      // Try to restore from a Voltix session token
      if (voltixStore.hasSession) {
        try {
          final voltixApi = GetIt.instance<VoltixApiService>();
          final userPrefs = GetIt.instance<UserPreferences>();
          final clientFactory = GetIt.instance<MediaServerClientFactory>();
          final authStore = GetIt.instance<AuthenticationStore>();
          // Everything in this branch is bounded, because this branch is only
          // reached once a device has been LINKED (voltixStore.hasSession), and
          // an unbounded await here strands the app on the splash logo forever
          // with no way out. The enclosing catch already falls through to the
          // login screen, so a TimeoutException is a safe, recoverable outcome -
          // hanging is not.
          final sessionResult = await voltixApi
              .validateSession(voltixStore.sessionToken!)
              .timeout(const Duration(seconds: 20));

          // ── Suspension check: admin disabled the account ──
          if (!sessionResult.user.isActive) {
            await voltixStore.clear();
            await session.destroyCurrentSession();
            if (mounted) {
              _navigate(Destinations.voltixLogin);
            }
            return;
          }

          // Add any missing assigned servers in parallel
          final addedServersMap = <int, dynamic>{};
          final addFutures = sessionResult.servers.map((vServer) async {
            try {
              final serverUrl = vServer.absoluteProxyUrl(voltixApi.baseUrl);
              final exists = serverRepo.servers.any((s) => s.address == serverUrl);
              if (!exists) {
                // Bounded per server: addServer reaches out to the media
                // server itself, so one unreachable or half-open host must not
                // stall startup. The catch below swallows the timeout, so the
                // remaining servers still get added.
                final added = await serverRepo
                    .addServer(serverUrl)
                    .timeout(const Duration(seconds: 12));
                if (added != null) addedServersMap[vServer.id] = added;
              } else {
                final existing = serverRepo.servers.firstWhere((s) => s.address == serverUrl);
                addedServersMap[vServer.id] = existing;
              }
            } catch (_) {}
          }).toList();
          // Backstop in case a future never settles despite the per-server
          // bound above.
          await Future.wait(addFutures).timeout(const Duration(seconds: 25));

          final jellyfinEnabled = userPrefs.get(UserPreferences.voltixJellyfinEnabled);

          // Sync IPTV/Live TV state from server
          await userPrefs.set(UserPreferences.voltixLiveTvEnabled, sessionResult.iptvReady);

          // Neither service assigned — can't proceed to home
          if (!sessionResult.jellyfinReady && !sessionResult.iptvReady) {
            await voltixStore.clear();
            // Fall through to login screen where user will see "no services" error
          } else if (!jellyfinEnabled || !sessionResult.jellyfinReady) {
            // Jellyfin is disabled/not ready but Live TV is available
            session.setVoltixOnlySession(
              serverId: sessionResult.activeServer?.id.toString() ?? '1',
              userId: sessionResult.user.id.toString(),
              username: sessionResult.user.username,
            );
            await userPrefs.set(UserPreferences.voltixJellyfinEnabled, false);
            _navigate(Destinations.home);
            return;
          } else {
            // Jellyfin is ready — try to re-authenticate using the JWT session token.
            // The Jellyfin proxy accepts JWT tokens in the password field.
            // Prefer Voltix Primary as the active server on restore too, so a
            // session that was created against Extra/4K still lands on Primary.
            final activeServerData = preferPrimaryServer(
                  sessionResult.servers,
                  fallback: sessionResult.activeServer,
                ) ??
                sessionResult.activeServer;
            if (activeServerData != null) {
              final activeLocalServer = addedServersMap[activeServerData.id];
              if (activeLocalServer != null) {
                try {
                  final client = clientFactory.getClient(
                    serverId: activeLocalServer.id,
                    serverType: activeLocalServer.serverType,
                    baseUrl: activeLocalServer.address,
                  );

                  Map<String, dynamic> authResult;
                  try {
                    authResult = await client.authApi
                        .authenticateByName(
                          sessionResult.user.username,
                          voltixStore.sessionToken!,
                        )
                        .timeout(const Duration(seconds: 10));
                  } catch (_) {
                    client.accessToken = voltixStore.sessionToken!;
                    final serverUser = await client.usersApi
                        .getCurrentUser()
                        .timeout(const Duration(seconds: 10));
                    authResult = {
                      'AccessToken': voltixStore.sessionToken!,
                      'User': {
                        'Id': serverUser.id,
                        'Name': serverUser.name,
                        'PrimaryImageTag': serverUser.primaryImageTag,
                        'Policy': {
                          'IsAdministrator': serverUser.policy?.isAdministrator ?? false,
                        },
                      },
                      'UserId': serverUser.id,
                    };
                  }

                  final accessToken = authResult['AccessToken'] as String?;
                  final userJson = authResult['User'] as Map<String, dynamic>?;
                  final userId = userJson?['Id'] as String? ??
                      authResult['UserId'] as String?;
                  final userName = userJson?['Name'] as String? ??
                      sessionResult.user.username;
                  final imageTag = (userJson?['PrimaryImageTag'] as String?) ??
                      ((userJson?['ImageTags'] as Map<String, dynamic>?)?['Primary'] as String?);
                  final policyJson = userJson?['Policy'] as Map<String, dynamic>?;
                  final startupNameLower = userName.toLowerCase();
                  final isAdmin = (policyJson?['IsAdministrator'] as bool? ?? false) ||
                      startupNameLower == 'voltixadmin' ||
                      startupNameLower == 'admin' ||
                      startupNameLower.contains('admin');

                  if (accessToken != null && userId != null) {
                    client.accessToken = accessToken;
                    client.userId = userId;

                    final user = PrivateUser(
                      id: userId,
                      name: userName,
                      serverId: activeLocalServer.id,
                      accessToken: accessToken,
                      lastUsed: DateTime.now(),
                      imageTag: imageTag,
                      isAdministrator: isAdmin,
                    );

                    await authStore.putUser(user);
                    final authPrefsInst = GetIt.instance<AuthenticationPreferences>();
                    await authPrefsInst.setLastServerId(activeLocalServer.id);
                    await authPrefsInst.setLastUserId(userId);

                    final switched = await session.switchCurrentSession(
                      serverId: activeLocalServer.id,
                      userId: userId,
                      username: sessionResult.user.username,
                    );

                    if (switched) {
                      // Also authenticate other servers in the background (non-blocking)
                      final otherServers = sessionResult.servers
                          .where((s) => s.id != activeServerData.id)
                          .toList();
                      if (otherServers.isNotEmpty) {
                        unawaited(Future.wait(otherServers.map((vServer) async {
                          try {
                            final otherLocal = addedServersMap[vServer.id];
                            if (otherLocal == null) return;
                            final otherClient = clientFactory.getClient(
                              serverId: otherLocal.id,
                              serverType: otherLocal.serverType,
                              baseUrl: otherLocal.address,
                            );
                            Map<String, dynamic> otherAuth;
                            try {
                              otherAuth = await otherClient.authApi
                                  .authenticateByName(
                                    sessionResult.user.username,
                                    voltixStore.sessionToken!,
                                  )
                                  .timeout(const Duration(seconds: 4));
                            } catch (_) {
                              otherClient.accessToken = voltixStore.sessionToken!;
                              final oUser = await otherClient.usersApi
                                  .getCurrentUser()
                                  .timeout(const Duration(seconds: 4));
                              otherAuth = {
                                'AccessToken': voltixStore.sessionToken!,
                                'User': {
                                  'Id': oUser.id,
                                  'Name': oUser.name,
                                  'PrimaryImageTag': oUser.primaryImageTag,
                                  'Policy': {
                                    'IsAdministrator': oUser.policy?.isAdministrator ?? false,
                                  },
                                },
                                'UserId': oUser.id,
                              };
                            }
                            final oToken = otherAuth['AccessToken'] as String?;
                            final oUserJson = otherAuth['User'] as Map<String, dynamic>?;
                            final oUserId = oUserJson?['Id'] as String?;
                            if (oToken != null && oUserId != null) {
                              otherClient.accessToken = oToken;
                              otherClient.userId = oUserId;
                              await authStore.putUser(PrivateUser(
                                id: oUserId,
                                name: oUserJson?['Name'] as String? ?? sessionResult.user.username,
                                serverId: otherLocal.id,
                                accessToken: oToken,
                                lastUsed: DateTime.now(),
                              ));
                            }
                          } catch (_) {}
                        })));
                      }

                      await userPrefs.set(UserPreferences.voltixJellyfinEnabled, true);
                      _navigate(Destinations.home);
                      return;
                    }
                  }
                } catch (_) {
                  // Re-auth failed — fall through to login
                }
              }
            }
          }
        } on VoltixApiException catch (e) {
          if (mounted && _isDeviceLimitError(e.message)) {
            final confirm = await _showDeviceLimitDialog(e.message);
            if (confirm) {
              try {
                final voltixApi = GetIt.instance<VoltixApiService>();
                final retryResult = await voltixApi.validateSession(
                  voltixStore.sessionToken!,
                  forceReplace: true,
                );
                if (retryResult.user.isActive) {
                  _navigate(Destinations.home);
                  return;
                }
              } catch (_) {}
            }
          }
        } catch (_) {
          // Persistent sessions: do NOT clear the token on transient failures
          // (network errors, timeouts, 5xx).
        }
      }
      _fallbackToLoginOrServerSelect();
    }
  } catch (e, st) {
    debugPrint('[Voltix] StartupScreen._initialize error: $e\n$st');
    _fallbackToLoginOrServerSelect();
  }
}

  void _navigate(String route) {
    if (mounted) {
      if (route == Destinations.home) {
        GetIt.instance<VoltixSessionService>().start();
        final voltixStore = GetIt.instance<VoltixSessionStore>();
        final userRepo = GetIt.instance<UserRepository>();
        final resolvedUsername = (voltixStore.username ?? userRepo.currentUser?.name ?? '').trim();
        if (resolvedUsername.isNotEmpty) {
          // Deliberately not awaited: the prompt must never gate navigation.
          // It is shown on the root navigator, so it survives the screen
          // change that happens immediately below.
          unawaited(GetIt.instance<UserSettingsSyncService>()
              .checkAndPromptForRemoteSettings(context, resolvedUsername));
        }
      }
      context.go(route);
    }
  }

  void _fallbackToLoginOrServerSelect() {
    _navigate(Destinations.voltixLogin);
  }

  bool _isDeviceLimitError(String msg) {
    final m = msg.toLowerCase();
    return m.contains('device limit') ||
        m.contains('limit reached') ||
        m.contains('active connection') ||
        m.contains('already connected') ||
        (m.contains('too many') &&
            (m.contains('device') || m.contains('connection'))) ||
        (m.contains('maximum') && m.contains('device'));
  }

  Future<bool> _showDeviceLimitDialog(String message) async {
    return await showFocusRestoringDialog<bool>(
          context: context,
          barrierDismissible: true,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF0F141C),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: Color(0xFF1E293B)),
            ),
            title: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Color(0xFFF59E0B)),
                SizedBox(width: 10),
                Text(
                  'Active Stream Limit Reached',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            content: Text(
              '$message\n\nYour account has reached the maximum allowed active connections. '
              'Would you like to disconnect the other active device/stream and continue on this device?',
              style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFEF4444),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Disconnect & Continue'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _showSecureStorageWarning() async {
    final l10n = AppLocalizations.of(context);
    await showFocusRestoringDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) => AlertDialog(
        title: Text(l10n.secureStorageUnavailable),
        content: Text(
          l10n.secureStorageUnavailableMessage,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.ok),
          ),
        ],
      ),
    );
  }

  bool get _isLargeScreen {
    final platform = defaultTargetPlatform;
    return platform == TargetPlatform.linux ||
        platform == TargetPlatform.macOS ||
        platform == TargetPlatform.windows;
  }

  @override
  Widget build(BuildContext context) =>
      RequestInitialFocus(child: _buildContent(context));

  Widget _buildContent(BuildContext context) {
    final gradientColors = [
      AppColorScheme.background,
      AppColorScheme.surfaceVariant,
      AppColorScheme.surface,
    ];
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: gradientColors,
          ),
        ),
        child: Center(
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  'assets/images/logo_and_text.png',
                  height: _isLargeScreen ? 80 : 56,
                ),
                const SizedBox(height: 32),
                SizedBox(
                  height: 24,
                  width: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColorScheme.accent.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
