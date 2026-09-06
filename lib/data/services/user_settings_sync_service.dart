import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:logger/logger.dart';

import '../../auth/repositories/session_repository.dart';
import '../../auth/store/authentication_store.dart';
import '../../auth/store/voltix_session_store.dart';
import '../../preference/user_preferences.dart';
import '../../ui/widgets/overlay_sheet.dart';
import '../../ui/screens/setup/setup_wizard_gate.dart';
import 'azure_blob_storage_service.dart';
import 'media_server_client_factory.dart';
import 'voltix_api_service.dart';
import 'voltix_watch_registry_service.dart';

class UserSettingsSyncService {
  final Logger _logger = Logger();
  Timer? _debounceTimer;

  static const String _hasSyncedKeyPrefix = 'pref_has_synced_user_settings_';
  static const String _lastSyncedTimeKeyPrefix = 'pref_last_synced_time_';

  String _hasSyncedKey(String username) => '$_hasSyncedKeyPrefix${username.toLowerCase()}';
  String _lastSyncedTimeKey(String username) => '$_lastSyncedTimeKeyPrefix${username.toLowerCase()}';

  (String, String) _resolveCredentials(String? targetUsername) {
    final voltixStore = GetIt.instance<VoltixSessionStore>();
    final token = voltixStore.sessionToken ?? 'voltix_user_session';

    if (targetUsername != null && targetUsername.trim().isNotEmpty) {
      return (targetUsername.trim(), token);
    }
    if (voltixStore.username != null && voltixStore.username!.trim().isNotEmpty) {
      return (voltixStore.username!.trim(), token);
    }
    if (voltixStore.displayName != null && voltixStore.displayName!.trim().isNotEmpty) {
      return (voltixStore.displayName!.trim(), token);
    }
    try {
      final sessionRepo = GetIt.instance<SessionRepository>();
      final serverId = sessionRepo.activeServerId;
      final userId = sessionRepo.activeUserId;
      if (serverId != null && userId != null) {
        final authStore = GetIt.instance<AuthenticationStore>();
        final user = authStore.getUser(serverId, userId);
        final name = user?.name;
        if (name != null && name.trim().isNotEmpty) {
          return (name.trim(), token);
        }
      }
    } catch (_) {}
    _logger.i('[UserSettingsSync] Resolving fallback user identifier: voltix_user');
    return ('voltix_user', token);
  }

  /// Last failure reason from [backupSettingsToServer], for the UI to show.
  ///
  /// The backend distinguishes "no blob container configured", "wrote to the
  /// database fallback" and "nothing was stored at all", but that detail was
  /// being collapsed into a bare false and thrown away - leaving the user with
  /// "Failed to backup settings to server." and nothing to act on.
  String? lastBackupError;

  /// Saves current local settings to Azure Blob Storage / Voltix Server for the logged-in user.
  Future<bool> backupSettingsToServer({String? targetUsername}) async {
    final (username, token) = _resolveCredentials(targetUsername);
    lastBackupError = null;

    try {
      final userPrefs = GetIt.instance<UserPreferences>();
      final settingsData = userPrefs.exportSettingsJson();

      final azureBlobService = AzureBlobStorageService();
      bool success = await azureBlobService.uploadUserSettingsBlob(
        username: username,
        settingsData: settingsData,
      );

      if (!success) {
        final apiService = VoltixApiService();
        success = await apiService.saveUserSettings(
          sessionToken: token,
          username: username,
          settingsData: settingsData,
        );
      }

      if (success) {
        final prefStore = GetIt.instance<PreferenceStore>();
        final nowIso = DateTime.now().toIso8601String();
        await prefStore.setString(_hasSyncedKey(username), 'true');
        await prefStore.setString(_lastSyncedTimeKey(username), nowIso);
        _logger.i('[UserSettingsSync] Successfully backed up settings to server for @$username');
        return true;
      }
      lastBackupError =
          'The server accepted the request but reported nothing was stored. '
          'Check AZURE_STORAGE_CONNECTION_STRING is set and that the '
          'voltix_user_settings table exists.';
    } catch (e) {
      lastBackupError = e.toString();
      _logger.e('[UserSettingsSync] Failed to backup settings to server', error: e);
    }
    return false;
  }

  /// Downloads settings from Azure Blob Storage / Voltix Server for [username] and applies them locally.
  Future<bool> restoreSettingsFromServer({String? targetUsername}) async {
    final (username, token) = _resolveCredentials(targetUsername);

    try {
      final azureBlobService = AzureBlobStorageService();
      Map<String, dynamic>? remoteData = await azureBlobService.downloadUserSettingsBlob(
        username: username,
      );

      if (remoteData == null || remoteData.isEmpty) {
        final apiService = VoltixApiService();
        remoteData = await apiService.getUserSettings(
          sessionToken: token,
          username: username,
        );
      }

      if (remoteData != null && remoteData.isNotEmpty) {
        final userPrefs = GetIt.instance<UserPreferences>();
        await userPrefs.importSettingsJson(remoteData);

        final prefStore = GetIt.instance<PreferenceStore>();
        final nowIso = DateTime.now().toIso8601String();
        await prefStore.setString(_hasSyncedKey(username), 'true');
        await prefStore.setString(_lastSyncedTimeKey(username), nowIso);
        _logger.i('[UserSettingsSync] Successfully restored settings from server for @$username');
        return true;
      }
    } catch (e) {
      _logger.e('[UserSettingsSync] Failed to restore settings from server', error: e);
    }
    return false;
  }

  /// Deletes all cloud data (settings + taste profile) for the user.
  Future<void> deleteAllCloudData({String? targetUsername}) async {
    final (username, _) = _resolveCredentials(targetUsername);
    final azureBlobService = AzureBlobStorageService();

    await Future.wait([
      azureBlobService.deleteUserSettingsBlob(username: username),
    ]);
    _logger.i('[UserSettingsSync] Deleted all cloud data for @$username');
  }

  /// Schedules a debounced backup to server whenever settings change locally.
  /// (Disabled per user requirement: Cloud sync occurs strictly when the user pushes the explicit Sync button).
  void scheduleAutoSync() {
    _debounceTimer?.cancel();
  }

  /// Uploads user watch registry to server.
  Future<bool> uploadWatchRegistryToServer({String? targetUsername}) async {
    final (username, _) = _resolveCredentials(targetUsername);
    try {
      if (GetIt.instance.isRegistered<VoltixWatchRegistryService>()) {
        final registry = GetIt.instance<VoltixWatchRegistryService>();
        final registryData = registry.exportRegistryData();
        final azureBlobService = AzureBlobStorageService();
        final success = await azureBlobService.uploadWatchRegistryBlob(
          username: username,
          registryData: registryData,
        );
        if (success) {
          _logger.i('[UserSettingsSync] Watch registry blob uploaded for @$username');
        }
        return success;
      }
    } catch (e) {
      _logger.w('[UserSettingsSync] Failed to upload watch registry: $e');
    }
    return false;
  }

  /// Restores user watch registry from server.
  Future<bool> restoreWatchRegistryFromServer({String? targetUsername}) async {
    final (username, _) = _resolveCredentials(targetUsername);
    try {
      final azureBlobService = AzureBlobStorageService();
      final remoteData = await azureBlobService.downloadWatchRegistryBlob(username: username);
      if (remoteData != null && GetIt.instance.isRegistered<VoltixWatchRegistryService>()) {
        final registry = GetIt.instance<VoltixWatchRegistryService>();
        await registry.importRegistryData(remoteData);
        _logger.i('[UserSettingsSync] Restored remote watch registry for @$username');
        return true;
      }
    } catch (e) {
      _logger.w('[UserSettingsSync] Failed to restore watch registry: $e');
    }
    return false;
  }

  /// Checks if remote settings and/or taste profile exist on the server for a
  /// newly logged-in or fresh install user.
  /// If remote data exists and local hasn't been linked yet, prompts the user
  /// to import, delete, or skip.
  /// True when the setup wizard is going to run, in which case it owns the
  /// cloud-data prompt and shows it as its final step. Prompting here as well
  /// would ask twice -- and because the login/startup path fires this dialog
  /// unawaited on the root navigator and then immediately navigates, the
  /// dialog would race the router's redirect into the wizard.
  bool _setupWizardOwnsPrompt() {
    try {
      if (!GetIt.instance.isRegistered<SetupWizardGate>()) return false;
      if (!GetIt.instance.isRegistered<MediaServerClientFactory>()) return false;
      final client =
          GetIt.instance<MediaServerClientFactory>().getActiveClient();
      return GetIt.instance<SetupWizardGate>().shouldRun(client);
    } catch (_) {
      return false;
    }
  }

  /// Probe for the setup wizard: is there cloud data worth asking about?
  ///
  /// Mirrors the no-UI half of [checkAndPromptForRemoteSettings], including the
  /// once-off initial backup when nothing is stored yet, so routing the prompt
  /// through the wizard doesn't skip that baseline.
  Future<bool> hasPendingCloudPrompt(String username) async {
    try {
      final token = GetIt.instance<VoltixSessionStore>().sessionToken;
      if (token == null || token.isEmpty) return false;

      final prefStore = GetIt.instance<PreferenceStore>();
      if (prefStore.getString(_hasSyncedKey(username)) == 'true') return false;

      final remoteSettings = await _checkForRemoteSettings(
        AzureBlobStorageService(),
        username,
        token,
      ).timeout(const Duration(seconds: 12), onTimeout: () => null);

      if (remoteSettings == null || remoteSettings.isEmpty) {
        await backupSettingsToServer(targetUsername: username);
        return false;
      }
      return true;
    } catch (e) {
      _logger.w('[UserSettingsSync] Cloud prompt probe failed: $e');
      return false;
    }
  }

  /// Carries out the user's choice. No UI, so the wizard owns the chrome.
  Future<void> applyCloudChoice(
    CloudDataAction action,
    String username,
  ) async {
    final prefStore = GetIt.instance<PreferenceStore>();
    switch (action) {
      case CloudDataAction.importAll:
        await restoreSettingsFromServer(targetUsername: username)
            .timeout(const Duration(seconds: 20), onTimeout: () => false);
        await prefStore.setString(_hasSyncedKey(username), 'true');
      case CloudDataAction.delete:
        // Marked first: the local reset is what the user waits on. The blob
        // delete can burn ~35s falling back from the proxy to Azure, so it
        // runs detached with its own timeouts.
        await prefStore.setString(_hasSyncedKey(username), 'true');
        unawaited(
          deleteAllCloudData(targetUsername: username).catchError((Object e) {
            _logger.w('[UserSettingsSync] Background cloud delete failed: $e');
          }),
        );
      case CloudDataAction.skip:
        await prefStore.setString(_hasSyncedKey(username), 'true');
    }
  }

  Future<void> checkAndPromptForRemoteSettings(
    BuildContext context,
    String username,
  ) async {
    final voltixStore = GetIt.instance<VoltixSessionStore>();
    final token = voltixStore.sessionToken;
    if (token == null || token.isEmpty) return;

    final prefStore = GetIt.instance<PreferenceStore>();
    final hasSyncedLocally = prefStore.getString(_hasSyncedKey(username)) == 'true';

    if (hasSyncedLocally) {
      // User has previously synced: automatically restore latest cloud data on
      // app restart.
      //
      // Bounded for the same reason the first-time branch below is, and it
      // matters more here: this is the branch EVERY returning user takes, and
      // it was the only one without a ceiling. Both calls reach Azure Blob
      // directly rather than the Voltix API, so a blob endpoint that accepts
      // the connection and stalls is invisible in the server logs -- the
      // device simply goes quiet after a successful login and sits on the
      // logo and spinner with nothing to show for it.
      //
      // Restored settings are a convenience, not a precondition for using the
      // app, so timing out and carrying on is the right trade every time.
      try {
        final restoredSettings = await restoreSettingsFromServer(
          targetUsername: username,
        ).timeout(const Duration(seconds: 12), onTimeout: () {
          _logger.w('[UserSettingsSync] Settings restore timed out for @$username');
          return false;
        });
        final restoredRegistry = await restoreWatchRegistryFromServer(
          targetUsername: username,
        ).timeout(const Duration(seconds: 12), onTimeout: () {
          _logger.w('[UserSettingsSync] Watch registry restore timed out for @$username');
          return false;
        });
        _logger.i(
          '[UserSettingsSync] Startup restore for @$username — '
          'settings: $restoredSettings, watch registry: $restoredRegistry',
        );
      } catch (e) {
        _logger.w('[UserSettingsSync] Could not restore latest data on startup: $e');
      }
      return;
    }

    if (_setupWizardOwnsPrompt()) {
      _logger.i(
        '[UserSettingsSync] Setup wizard is running -- it asks about cloud '
        'data as its final step.',
      );
      return;
    }

    try {
      final azureBlobService = AzureBlobStorageService();

      // Bounded: this runs while the login screen sits on its logo-and-spinner
      // loading state, and every await here delays the user reaching a screen.
      // A slow or unreachable blob endpoint must degrade to "no cloud data",
      // never to an indefinite spinner.
      final remoteSettings = await _checkForRemoteSettings(
        azureBlobService,
        username,
        token,
      ).timeout(
        const Duration(seconds: 12),
        onTimeout: () {
          _logger.w('[UserSettingsSync] Cloud data check timed out for @$username');
          return null;
        },
      );

      final hasSettings = remoteSettings != null && remoteSettings.isNotEmpty;

      if (!hasSettings) {
        // No remote data exists: perform initial once-off cloud backup
        // This sends a snapshot of default settings so new users always have
        // a cloud baseline to restore from.
        _logger.i('[UserSettingsSync] No cloud data found. Performing once-off initial backup for @$username');
        await backupSettingsToServer(targetUsername: username);
        return;
      }

      if (!context.mounted) return;

      // Build a description of what was found
      final foundItems = <String>[];
      if (hasSettings) foundItems.add('Application settings');

      final action = await showFocusRestoringDialog<CloudDataAction>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF0F141C),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Color(0xFF1E293B)),
          ),
          contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          title: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF3B82F6).withValues(alpha: 0.15),
                  border: Border.all(
                    color: const Color(0xFF3B82F6).withValues(alpha: 0.35),
                  ),
                ),
                child: const Icon(Icons.cloud_done_rounded,
                    color: Color(0xFF38BDF8), size: 22),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Cloud Data Found',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Voltix Cloud Sync Backup',
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B).withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF334155)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.account_circle_outlined,
                        size: 16, color: Color(0xFF38BDF8)),
                    const SizedBox(width: 6),
                    Text(
                      '@$username',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'A saved cloud backup for this account was found on the server:',
                style: TextStyle(
                    color: Colors.white70, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF161D2B),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(0xFF1E293B),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: foundItems
                      .map((item) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              children: [
                                const Icon(Icons.check_circle_rounded,
                                    color: Color(0xFF10B981), size: 16),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    item,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ))
                      .toList(),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Would you like to restore your cloud backup or start fresh on this device?',
                style: TextStyle(
                    color: Colors.white60, fontSize: 12, height: 1.4),
              ),
            ],
          ),
          actionsAlignment: MainAxisAlignment.spaceBetween,
          actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(CloudDataAction.delete),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFEF4444),
              ),
              child: const Text(
                'Delete Cloud Data',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(CloudDataAction.skip),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white60,
                  ),
                  child: const Text('Start Fresh', style: TextStyle(fontSize: 13)),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: const Icon(Icons.cloud_download_rounded, size: 16),
                  label: const Text('Restore Backup',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  onPressed: () =>
                      Navigator.of(ctx).pop(CloudDataAction.importAll),
                ),
              ],
            ),
          ],
        ),
      );

      switch (action) {
        case CloudDataAction.importAll:
          // Bounded for the same reason as the check above: the caller cannot
          // navigate until this returns.
          if (hasSettings) {
            await restoreSettingsFromServer(targetUsername: username)
                .timeout(const Duration(seconds: 20), onTimeout: () => false);
          }
          await prefStore.setString(_hasSyncedKey(username), 'true');
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Cloud data successfully imported!'),
                backgroundColor: Color(0xFF10B981),
              ),
            );
          }
        case CloudDataAction.delete:
          // The local reset is what the user is waiting on — it is instant.
          //
          // The cloud delete is not: the blob deletion falls back from the
          // Voltix proxy to Azure directly, so a bad endpoint can burn ~35s.
          // Awaiting it left the caller
          // parked on the Voltix logo and spinner with no feedback, which is
          // indistinguishable from a hang. Fire it off instead — nothing
          // downstream depends on its result, and each request carries its own
          // timeout.
          await prefStore.setString(_hasSyncedKey(username), 'true');
          unawaited(
            deleteAllCloudData(targetUsername: username).catchError((Object e) {
              _logger.w('[UserSettingsSync] Background cloud delete failed: $e');
            }),
          );
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Cloud data deleted. Starting fresh.'),
                backgroundColor: Color(0xFF3B82F6),
              ),
            );
          }
        case CloudDataAction.skip:
        case null:
          // Mark as synced so we don't prompt again
          await prefStore.setString(_hasSyncedKey(username), 'true');
      }
    } catch (e) {
      _logger.w('[UserSettingsSync] Error checking remote data: $e');
    }
  }

  /// Helper to check for remote settings via Azure blob or Voltix API.
  Future<Map<String, dynamic>?> _checkForRemoteSettings(
    AzureBlobStorageService azureBlobService,
    String username,
    String token,
  ) async {
    Map<String, dynamic>? remoteSettings = await azureBlobService.downloadUserSettingsBlob(
      username: username,
    );
    if (remoteSettings == null || remoteSettings.isEmpty) {
      final apiService = VoltixApiService();
      remoteSettings = await apiService.getUserSettings(
        sessionToken: token,
        username: username,
      );
    }
    return remoteSettings;
  }

  /// Returns string representation of last sync time for [username].
  String getLastSyncedTime(String username) {
    try {
      final prefStore = GetIt.instance<PreferenceStore>();
      final raw = prefStore.getString(_lastSyncedTimeKey(username));
      if (raw == null || raw.isEmpty) return 'Never synced';
      final dt = DateTime.parse(raw).toLocal();
      return '${dt.month}/${dt.day}/${dt.year} at ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return 'Never synced';
    }
  }
}

enum CloudDataAction { importAll, delete, skip }
