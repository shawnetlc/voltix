import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:server_core/server_core.dart';
import 'package:uuid/uuid.dart';
import '../../preference/user_preferences.dart';
import '../models/aggregated_item.dart';
import '../models/taste_profile/taste_profile_models.dart';
import '../services/media_server_client_factory.dart';
import '../services/row_data_source.dart';
import '../services/taste_profile/azure_taste_sync_service.dart';
import '../services/taste_profile/grok_taste_ai_service.dart';
import '../services/taste_profile/taste_genre_service.dart';
import '../services/taste_profile/taste_history_analyzer.dart';
import '../services/taste_profile/taste_local_store.dart';
import '../services/taste_profile/taste_refresh_service.dart';
import '../services/taste_profile/taste_server_context.dart';
import '../services/taste_profile/taste_sync_manager.dart';

/// Repository managing taste profiles, atomic local persistence, Azure cloud backup,
/// server-genre discovery, Grok AI intelligence, and candidate refresh pipelines for the Primary Jellyfin Server.
class TasteProfileRepository extends ChangeNotifier {
  final MediaServerClient _client;
  final TasteServerContext _serverContext;
  final TasteLocalStore _localStore;
  final AzureTasteSyncService _azureSync;
  final TasteGenreService _genreService;
  final TasteRefreshService _refreshService;
  final GrokTasteAiService _grokAi;
  late final TasteHistoryAnalyzer _analyzer;
  late final TasteSyncManager _syncManager;

  TasteProfile? _currentProfile;
  TasteProfile? get currentProfile => _currentProfile;

  TasteServerContext get serverContext => _serverContext;
  TasteGenreService get genreService => _genreService;
  TasteRefreshService get refreshService => _refreshService;
  TasteLocalStore get localStore => _localStore;
  AzureTasteSyncService get azureSync => _azureSync;
  GrokTasteAiService get grokAi => _grokAi;
  GrokTasteAiService get aiService => _grokAi;
  TasteSyncManager get syncManager => _syncManager;

  final PreferenceStore _prefs;

  TasteProfileRepository(
    PreferenceStore prefs,
    this._client, {
    TasteServerContext? serverContext,
    TasteLocalStore? localStore,
    AzureTasteSyncService? azureSync,
    TasteGenreService? genreService,
    TasteRefreshService? refreshService,
    GrokTasteAiService? grokAi,
    TasteSyncManager? syncManager,
  })  : _prefs = prefs,
        _serverContext =
            serverContext ?? TasteServerContext(GetItClientFactoryWrapper(_client)),
        _localStore = localStore ?? TasteLocalStore(prefs),
        _azureSync = azureSync ?? AzureTasteSyncService(),
        _genreService = genreService ?? TasteGenreService(_client),
        _grokAi = grokAi ?? GrokTasteAiService(),
        _refreshService = refreshService ??
            TasteRefreshService(
              clientProvider: () => _client,
              serverContext:
                  serverContext ?? TasteServerContext(GetItClientFactoryWrapper(_client)),
            ) {
    _analyzer = TasteHistoryAnalyzer(_client);
    _syncManager = syncManager ??
        TasteSyncManager(
          serverContext: _serverContext,
          localStore: _localStore,
          genreService: _genreService,
          analyzer: _analyzer,
        );

    // Initialize Grok AI and Azure credentials from preferences if saved
    final savedGrokKey = _prefs.get(UserPreferences.grokApiKey);
    if (savedGrokKey.isNotEmpty) {
      _grokAi.setApiKey(savedGrokKey);
    }
    final savedGrokModel = _prefs.get(UserPreferences.grokModel);
    if (savedGrokModel.isNotEmpty) {
      _grokAi.setModel(savedGrokModel);
    }
    final savedAzureConn = _prefs.get(UserPreferences.azureStorageConnectionString);
    if (savedAzureConn.isNotEmpty) {
      _azureSync.storageClient.setConnectionString(savedAzureConn);
    }
    final savedAzureContainer = _prefs.get(UserPreferences.azureBlobContainer);
    if (savedAzureContainer.isNotEmpty) {
      _azureSync.storageClient.setContainerName(savedAzureContainer);
    }
  }

  /// Updates and persists Grok AI credentials at runtime.
  Future<void> updateGrokConfig({
    required String apiKey,
    required String model,
  }) async {
    _prefs.set(UserPreferences.grokApiKey, apiKey);
    _prefs.set(UserPreferences.grokModel, model);
    _grokAi.setApiKey(apiKey);
    _grokAi.setModel(model);
    notifyListeners();
  }

  /// Updates and persists Azure Cloud Storage credentials at runtime.
  Future<void> updateAzureStorageConfig({
    required String connectionString,
    required String container,
  }) async {
    _prefs.set(UserPreferences.azureStorageConnectionString, connectionString);
    _prefs.set(UserPreferences.azureBlobContainer, container);
    _azureSync.storageClient.setConnectionString(connectionString);
    _azureSync.storageClient.setContainerName(container);
    notifyListeners();
  }

  /// Loads the profile for the current user and primary server.
  Future<TasteProfile> loadProfile({
    required String userId,
    required String serverId,
    bool forceReanalyze = false,
  }) async {
    // 1. Verify primary server connection
    _serverContext.setAuthenticatedSession(
      serverId: serverId,
      userId: userId,
      accessToken: _client.accessToken ?? '',
      serverUrl: _client.baseUrl,
    );

    // 2. Check local atomic storage
    final local = await _localStore.loadProfile(
      serverId: serverId,
      userId: userId,
    );

    if (local != null && !forceReanalyze) {
      _currentProfile = local;
      notifyListeners();

      // Silent background sync check if enabled
      if (local.azureBackupEnabled) {
        _azureSync.uploadProfileSilently(profile: local);
      }
      return _currentProfile!;
    }

    // 3. Fallback check: Jellyfin DisplayPreferences (roaming across clients)
    try {
      final disp = await _client.displayPreferencesApi.getDisplayPreferences(
        'voltix_taste_profile',
        client: 'voltix',
      );
      final custom = disp.customPrefs;
      if (custom.containsKey('profile_json')) {
        final map = jsonDecode(custom['profile_json']!) as Map<String, dynamic>;
        _currentProfile = TasteProfile.fromJson(map);
        await _localStore.saveProfileAtomic(_currentProfile!);
        notifyListeners();
        return _currentProfile!;
      }
    } catch (_) {
      // Display preferences not available or network error
    }

    // 4. Fallback check: Azure Cloud Storage backup (for fresh installs / new devices)
    try {
      final remote = await _azureSync
          .fetchRemoteBackup(serverId: serverId, userId: userId)
          .timeout(const Duration(seconds: 4));
      if (remote != null) {
        _currentProfile = remote;
        await _localStore.saveProfileAtomic(remote);
        notifyListeners();
        return _currentProfile!;
      }
    } catch (e) {
      debugPrint('[TasteProfileRepository] Azure cloud restore skipped: $e');
    }

    // 5. Create initial notStarted profile immediately so wizard appears without latency
    final now = DateTime.now().toUtc();
    _currentProfile = TasteProfile(
      profileId: const Uuid().v4(),
      userId: userId,
      serverId: serverId,
      profileRevision: const Uuid().v4(),
      status: TasteProfileStatus.notStarted,
      explicit: const ExplicitTasteProfile(),
      inferred: InferredTasteProfile(),
      languageSettings: const LanguageSettings(),
      createdAtUtc: now,
      updatedAtUtc: now,
      lastUpdated: now,
    );

    await _localStore.saveProfileAtomic(_currentProfile!);
    notifyListeners();

    // 5. Ingest watch history in the background (or synchronously if forceReanalyze is requested)
    if (forceReanalyze) {
      final inferred = await _analyzer.analyzeHistory(userId: userId);
      _currentProfile = _currentProfile!.copyWith(inferred: inferred);
      await _localStore.saveProfileAtomic(_currentProfile!);
      notifyListeners();
    } else {
      unawaited(_analyzer.analyzeHistory(userId: userId).then((inferred) async {
        if (_currentProfile?.userId == userId &&
            _currentProfile?.serverId == serverId) {
          _currentProfile = _currentProfile!.copyWith(inferred: inferred);
          await _localStore.saveProfileAtomic(_currentProfile!);
          notifyListeners();
        }
      }).catchError((e) {
        debugPrint('[TasteProfileRepository] Background history ingestion error: $e');
      }));
    }

    return _currentProfile!;
  }

  /// Saves the profile locally (atomic) and queues silent cloud backup.
  Future<void> saveProfile(TasteProfile profile) async {
    final now = DateTime.now().toUtc();
    _currentProfile = profile.copyWith(
      profileRevision: const Uuid().v4(),
      profileVersion: profile.profileVersion + 1,
      updatedAtUtc: now,
      lastUpdated: now,
      syncStatus: SyncStatus.pendingUpload,
    );

    await _localStore.saveProfileAtomic(_currentProfile!);
    await _syncRoamingPreferences(_currentProfile!);

    // Silent background Azure sync
    if (_currentProfile!.azureBackupEnabled) {
      unawaited(_azureSync.uploadProfileSilently(profile: _currentProfile!).then((ok) async {
        if (ok && _currentProfile != null) {
          _currentProfile = _currentProfile!.copyWith(
            syncStatus: SyncStatus.synced,
            lastSyncedAtUtc: DateTime.now().toUtc(),
          );
          await _localStore.saveProfileAtomic(_currentProfile!);
          notifyListeners();
        }
      }));
    }

    notifyListeners();
  }

  /// Explicitly uploads / syncs current profile to Azure Cloud storage and updates sync state.
  Future<bool> syncProfileToCloud() async {
    if (_currentProfile == null) return false;
    final now = DateTime.now().toUtc();
    final ok = await _azureSync.uploadProfileSilently(
      profile: _currentProfile!,
    );
    if (ok && _currentProfile != null) {
      _currentProfile = _currentProfile!.copyWith(
        syncStatus: SyncStatus.synced,
        lastSyncedAtUtc: now,
        lastUpdated: now,
      );
      await _localStore.saveProfileAtomic(_currentProfile!);
      await _syncRoamingPreferences(_currentProfile!);
      notifyListeners();
    }
    return ok;
  }

  /// Completes onboarding with explicit questionnaire answers and starts gentle background pre-population.
  Future<void> completeOnboarding(ExplicitTasteProfile explicit) async {
    if (_currentProfile == null) return;
    final updated = _currentProfile!.copyWith(
      status: TasteProfileStatus.completed,
      explicit: explicit,
    );
    await saveProfile(updated);
    startSilentBackgroundPopulation();
  }

  /// Silently starts background pre-population of taste profile home rows with zero server impact.
  /// Runs gently with throttled inter-row delays so users can watch and stream with uninterrupted performance.
  void startSilentBackgroundPopulation({
    Duration interRowDelay = const Duration(milliseconds: 650),
  }) {
    unawaited(_runSilentBackgroundPopulation(interRowDelay: interRowDelay));
  }

  Future<void> _runSilentBackgroundPopulation({
    Duration interRowDelay = const Duration(milliseconds: 650),
  }) async {
    final profile = _currentProfile;
    if (profile == null || profile.status != TasteProfileStatus.completed) return;

    try {
      debugPrint('[TasteProfileRepository] Silently populating taste recommendations in background (gentle throttled mode)...');

      // 1. Gently warm candidate library
      await _refreshService.refreshIfStale(
        serverId: profile.serverId,
        userId: profile.userId,
        languageSettings: profile.languageSettings,
      );

      // Yield to event loop
      await Future.delayed(interRowDelay);

      // 2. Pre-compute and cache each enabled row type sequentially with inter-row throttle
      if (GetIt.instance.isRegistered<RowDataSource>()) {
        final dataSource = GetIt.instance<RowDataSource>();
        for (final rowType in PersonalizationRowType.values) {
          final isEnabled = profile.enabledHomeRows[rowType.key] ?? true;
          if (!isEnabled) continue;

          // Yield / pause between rows to protect playback bandwidth and server CPU
          await Future.delayed(interRowDelay);

          try {
            await dataSource.loadTasteProfileSingleRow(
              profile.serverId,
              profile,
              rowType,
            );
          } catch (e) {
            debugPrint('[TasteProfileRepository] Background warmup error for ${rowType.key}: $e');
          }
        }
      }
      debugPrint('[TasteProfileRepository] Gentle background population finished successfully.');
    } catch (e) {
      debugPrint('[TasteProfileRepository] Gentle background population error: $e');
    }
  }

  /// Skips onboarding with a reminder state.
  Future<void> skipOnboarding() async {
    if (_currentProfile == null) return;
    final updated = _currentProfile!.copyWith(
      status: TasteProfileStatus.skippedRemindMe,
    );
    await saveProfile(updated);
  }

  /// Resets inferred profile data by re-analyzing watch history.
  Future<void> resetInferredProfile() async {
    if (_currentProfile == null) return;
    final inferred = await _analyzer.analyzeHistory(
      userId: _currentProfile!.userId,
    );
    final updated = _currentProfile!.copyWith(inferred: inferred);
    await saveProfile(updated);
  }

  /// Resets explicit questionnaire answers.
  Future<void> resetExplicitProfile() async {
    if (_currentProfile == null) return;
    final updated = _currentProfile!.copyWith(
      status: TasteProfileStatus.notStarted,
      explicit: const ExplicitTasteProfile(),
    );
    await saveProfile(updated);
  }

  /// Deletes all local taste profile data.
  Future<void> deleteAllData() async {
    if (_currentProfile == null) return;
    await _localStore.deleteProfile(
      serverId: _currentProfile!.serverId,
      userId: _currentProfile!.userId,
    );
    _currentProfile = null;
    notifyListeners();
  }

  /// Adds a negative feedback signal ("Not Interested").
  Future<void> addNegativeSignal({
    required String id,
    required String title,
    required String type,
  }) async {
    if (_currentProfile == null) return;
    final existing = List<NegativeSignal>.from(_currentProfile!.negativeSignals);
    if (!existing.any((n) => n.id == id)) {
      existing.add(
        NegativeSignal(
          id: id,
          title: title,
          type: type,
          createdAt: DateTime.now().toUtc(),
        ),
      );
      await saveProfile(_currentProfile!.copyWith(negativeSignals: existing));
    }
  }

  /// Removes a negative signal.
  Future<void> removeNegativeSignal(String id) async {
    if (_currentProfile == null) return;
    final existing = List<NegativeSignal>.from(_currentProfile!.negativeSignals)
      ..removeWhere((n) => n.id == id);
    await saveProfile(_currentProfile!.copyWith(negativeSignals: existing));
  }

  /// Adds user feedback signal ("More like this", "Seen It").
  Future<void> addFeedbackSignal({
    required String itemId,
    required String action,
  }) async {
    if (_currentProfile == null) return;
    final existing = List<FeedbackSignal>.from(_currentProfile!.feedbackSignals);
    existing.add(
      FeedbackSignal(
        eventId: const Uuid().v4(),
        itemId: itemId,
        action: action,
        timestamp: DateTime.now().toUtc(),
      ),
    );
    await saveProfile(_currentProfile!.copyWith(feedbackSignals: existing));
  }

  /// Queries Azure Blob Storage for an existing remote profile backup.
  Future<TasteProfile?> checkCloudBackup({
    required String serverId,
    required String userId,
  }) async {
    return _azureSync.fetchRemoteBackup(
      serverId: serverId,
      userId: userId,
    );
  }

  /// Imports a saved cloud profile and applies it locally.
  Future<void> importCloudBackup(TasteProfile backup) async {
    _currentProfile = backup.copyWith(
      syncStatus: SyncStatus.synced,
      lastSyncedAtUtc: DateTime.now().toUtc(),
      lastUpdated: DateTime.now().toUtc(),
    );
    await _localStore.saveProfileAtomic(_currentProfile!);
    await _syncRoamingPreferences(_currentProfile!);
    notifyListeners();
  }

  /// Deletes the cloud backup permanently from Azure.
  Future<bool> deleteCloudBackup({
    required String serverId,
    required String userId,
  }) async {
    return _azureSync.deleteRemoteBackup(
      serverId: serverId,
      userId: userId,
    );
  }

  /// Generates a Grok AI taste persona analysis and attaches it to the profile.
  Future<String?> generateGrokTastePersona() async {
    if (_currentProfile == null) return null;
    final insight = await _grokAi.generateTastePersonaInsight(_currentProfile!);
    if (insight != null && insight.isNotEmpty) {
      final updated = _currentProfile!.copyWith(
        aiFeaturesEnabled: true,
        aiPersonaSummary: insight,
        aiLastInsightUtc: DateTime.now().toUtc(),
      );
      await saveProfile(updated);
    }
    return insight;
  }

  /// Toggles AI feature enhancements on or off.
  Future<void> toggleAiFeatures(bool enabled) async {
    if (_currentProfile == null) return;
    final updated = _currentProfile!.copyWith(aiFeaturesEnabled: enabled);
    await saveProfile(updated);
  }

  /// Refreshes onboarding/recommendation candidate items from primary server.
  Future<List<AggregatedItem>> refreshCandidates({bool force = false}) async {
    final serverId =
        _currentProfile?.serverId ?? _serverContext.primaryServerId ?? '';
    final userId =
        _currentProfile?.userId ?? _serverContext.authenticatedUserId ?? '';
    if (serverId.isEmpty || userId.isEmpty) return [];
    return _refreshService.refreshCandidates(
      serverId: serverId,
      userId: userId,
      languageSettings:
          _currentProfile?.languageSettings ?? const LanguageSettings(),
      force: force,
    );
  }

  /// Loads cached movies from independent local store.
  Future<List<AggregatedItem>> loadCachedMovies() async {
    final serverId =
        _currentProfile?.serverId ?? _serverContext.primaryServerId ?? '';
    final userId =
        _currentProfile?.userId ?? _serverContext.authenticatedUserId ?? '';
    if (serverId.isEmpty || userId.isEmpty) return [];
    return _localStore.loadCachedMovies(
      serverId: serverId,
      userId: userId,
    );
  }

  /// Loads cached series from independent local store.
  Future<List<AggregatedItem>> loadCachedSeries() async {
    final serverId =
        _currentProfile?.serverId ?? _serverContext.primaryServerId ?? '';
    final userId =
        _currentProfile?.userId ?? _serverContext.authenticatedUserId ?? '';
    if (serverId.isEmpty || userId.isEmpty) return [];
    return _localStore.loadCachedSeries(
      serverId: serverId,
      userId: userId,
    );
  }

  /// Alias for checkCloudBackup.
  Future<TasteProfile?> checkForCloudBackup({
    required String serverId,
    required String userId,
  }) => checkCloudBackup(serverId: serverId, userId: userId);

  Future<void> _syncRoamingPreferences(TasteProfile profile) async {
    try {
      final jsonStr = jsonEncode(profile.toJson());
      final dp = await _client.displayPreferencesApi.getDisplayPreferences(
        'voltix_taste_profile',
        client: 'voltix',
      );
      final updated = DisplayPreferences(
        id: dp.id,
        sortBy: dp.sortBy,
        sortOrder: dp.sortOrder,
        viewType: dp.viewType,
        customPrefs: {...dp.customPrefs, 'profile_json': jsonStr},
      );
      await _client.displayPreferencesApi.saveDisplayPreferences(
        'voltix_taste_profile',
        updated,
        client: 'voltix',
      );
    } catch (_) {}
  }
}

/// Fallback wrapper for MediaServerClientFactory
class GetItClientFactoryWrapper implements MediaServerClientFactory {
  final MediaServerClient _client;
  GetItClientFactoryWrapper(this._client);

  @override
  MediaServerClient get activeClientOrNull => _client;

  @override
  MediaServerClient getActiveClient() => _client;

  @override
  MediaServerClient? getClientIfExists(String serverId) => _client;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
