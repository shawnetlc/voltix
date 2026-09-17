import 'dart:io';

void main() async {
  final file = File('lib/data/services/user_settings_sync_service.dart');
  var content = await file.readAsString();

  if (!content.contains('voltix_favorites_registry_service.dart')) {
    content = content.replaceAll(
      "import 'voltix_watch_registry_service.dart';",
      "import 'voltix_watch_registry_service.dart';\nimport 'voltix_favorites_registry_service.dart';"
    );
  }

  if (!content.contains('_dailySyncTimer')) {
    content = content.replaceAll(
      "Timer? _debounceTimer;",
      "Timer? _debounceTimer;\n  Timer? _dailySyncTimer;\n  static const String _lastDailySyncKeyPrefix = 'pref_last_daily_sync_';"
    );
  }

  content = content.replaceAll(
    "void scheduleAutoSync() {\n    _debounceTimer?.cancel();\n  }",
    '''void scheduleAutoSync() {
    _debounceTimer?.cancel();
    _dailySyncTimer?.cancel();
    _dailySyncTimer = Timer.periodic(
      const Duration(minutes: 30),
      (_) => _checkAndRunDailySync(),
    );
  }

  void cancelAutoSync() {
    _dailySyncTimer?.cancel();
    _dailySyncTimer = null;
  }

  Future<void> _checkAndRunDailySync() async {
    final (username, _) = _resolveCredentials(null);
    final prefStore = GetIt.instance<PreferenceStore>();
    final lastSyncRaw = prefStore.getString('\\');
    if (lastSyncRaw != null) {
      final lastSync = DateTime.tryParse(lastSyncRaw);
      if (lastSync != null && DateTime.now().difference(lastSync) < const Duration(hours: 24)) {
        return; // Less than 24h since last sync
      }
    }
    await syncActiveProfileToCloud();
  }

  Future<void> syncActiveProfileToCloud() async {
    final (username, _) = _resolveCredentials(null);
    final voltixStore = GetIt.instance<VoltixSessionStore>();
    final activeProfileId = voltixStore.activeProfileId;
    if (activeProfileId == null) return;
    
    final prefStore = GetIt.instance<PreferenceStore>();
    
    await backupSettingsToServer(targetUsername: username);
    await uploadWatchRegistryToServer(targetUsername: username);
    await uploadFavoritesRegistryToServer(targetUsername: username);
    
    await prefStore.setString('\\', DateTime.now().toIso8601String());
  }'''
  );

  content = content.replaceAll(
    '''final azureBlobService = AzureBlobStorageService();
        final success = await azureBlobService.uploadWatchRegistryBlob(
          username: username,
          registryData: registryData,
        );''',
    '''final voltixStore = GetIt.instance<VoltixSessionStore>();
        final azureBlobService = AzureBlobStorageService();
        final success = await azureBlobService.uploadWatchRegistryBlob(
          username: username,
          registryData: registryData,
          profileId: voltixStore.activeProfileId,
        );'''
  );

  content = content.replaceAll(
    '''final azureBlobService = AzureBlobStorageService();
      final remoteData = await azureBlobService.downloadWatchRegistryBlob(username: username);''',
    '''final voltixStore = GetIt.instance<VoltixSessionStore>();
      final azureBlobService = AzureBlobStorageService();
      final remoteData = await azureBlobService.downloadWatchRegistryBlob(username: username, profileId: voltixStore.activeProfileId);'''
  );

  if (!content.contains('uploadFavoritesRegistryToServer')) {
    final favoritesMethods = '''

  Future<bool> uploadFavoritesRegistryToServer({String? targetUsername}) async {
    final (username, _) = _resolveCredentials(targetUsername);
    try {
      if (GetIt.instance.isRegistered<VoltixFavoritesRegistryService>()) {
        final registry = GetIt.instance<VoltixFavoritesRegistryService>();
        final registryData = registry.exportRegistryData();
        final azureBlobService = AzureBlobStorageService();
        final voltixStore = GetIt.instance<VoltixSessionStore>();
        final profileId = voltixStore.activeProfileId;
        if (profileId == null) return false;
        final success = await azureBlobService.uploadFavoritesRegistryBlob(
          username: username,
          profileId: profileId,
          registryData: registryData,
        );
        if (success) {
          _logger.i('[UserSettingsSync] Favorites registry blob uploaded for @\ profile \');
        }
        return success;
      }
    } catch (e) {
      _logger.w('[UserSettingsSync] Failed to upload favorites registry: \');
    }
    return false;
  }

  Future<bool> restoreFavoritesRegistryFromServer({String? targetUsername}) async {
    final (username, _) = _resolveCredentials(targetUsername);
    try {
      final azureBlobService = AzureBlobStorageService();
      final voltixStore = GetIt.instance<VoltixSessionStore>();
      final profileId = voltixStore.activeProfileId;
      if (profileId == null) return false;
      final remoteData = await azureBlobService.downloadFavoritesRegistryBlob(username: username, profileId: profileId);
      if (remoteData != null && GetIt.instance.isRegistered<VoltixFavoritesRegistryService>()) {
        final registry = GetIt.instance<VoltixFavoritesRegistryService>();
        await registry.importRegistryData(remoteData);
        _logger.i('[UserSettingsSync] Restored remote favorites registry for @\ profile \');
        return true;
      }
    } catch (e) {
      _logger.w('[UserSettingsSync] Failed to restore favorites registry: \');
    }
    return false;
  }
''';
    content = content.replaceAll(
      "Future<bool> restoreWatchRegistryFromServer({String? targetUsername}) async {",
      favoritesMethods + "\\n  Future<bool> restoreWatchRegistryFromServer({String? targetUsername}) async {"
    );
  }
  
  content = content.replaceAll(
    '''final restoredRegistry = await restoreWatchRegistryFromServer(
          targetUsername: username,
        ).timeout(const Duration(seconds: 12), onTimeout: () {
          _logger.w('[UserSettingsSync] Watch registry restore timed out for @\');
          return false;
        });''',
    '''final restoredRegistry = await restoreWatchRegistryFromServer(
          targetUsername: username,
        ).timeout(const Duration(seconds: 12), onTimeout: () {
          _logger.w('[UserSettingsSync] Watch registry restore timed out for @\');
          return false;
        });
        final restoredFavorites = await restoreFavoritesRegistryFromServer(
          targetUsername: username,
        ).timeout(const Duration(seconds: 12), onTimeout: () {
          _logger.w('[UserSettingsSync] Favorites registry restore timed out for @\');
          return false;
        });'''
  );
  
  content = content.replaceAll(
    "'settings: \, watch registry: \',",
    "'settings: \, watch registry: \, favorites: \',"
  );
  
  await file.writeAsString(content);
}
