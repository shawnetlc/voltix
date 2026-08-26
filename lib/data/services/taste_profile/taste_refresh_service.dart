import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:server_core/server_core.dart';
import '../../models/aggregated_item.dart';
import '../../models/taste_profile/taste_profile_models.dart';
import 'taste_recommendation_engine.dart';
import 'taste_server_context.dart';

/// State of candidate title refresh operations.
enum RefreshState { idle, refreshing, success, error }

/// Service managing stale-while-revalidate caching, request deduplication,
/// and automated / manual candidate refresh pipelines against the primary Jellyfin server.
class TasteRefreshService extends ChangeNotifier {
  final MediaServerClient Function() _clientProvider;
  final TasteServerContext _serverContext;

  static const Duration defaultRefreshInterval = Duration(hours: 6);
  static const int _batchSize = 200;
  static const int _maxCandidates = 1000;

  RefreshState _state = RefreshState.idle;
  RefreshState get state => _state;

  DateTime? _lastRefreshedAt;
  DateTime? get lastRefreshedAt => _lastRefreshedAt;

  String? _lastErrorMessage;
  String? get lastErrorMessage => _lastErrorMessage;

  List<AggregatedItem> _cachedCandidates = [];
  List<AggregatedItem> get cachedCandidates => List.unmodifiable(_cachedCandidates);

  // In-flight refresh deduplication future
  Future<List<AggregatedItem>>? _activeRefreshFuture;

  TasteRefreshService({
    required MediaServerClient Function() clientProvider,
    required TasteServerContext serverContext,
  })  : _clientProvider = clientProvider,
        _serverContext = serverContext;

  /// Checks if candidate cache is stale and should be refreshed.
  bool get isStale {
    if (_lastRefreshedAt == null || _cachedCandidates.isEmpty) return true;
    return DateTime.now().difference(_lastRefreshedAt!) >= defaultRefreshInterval;
  }

  /// Triggers a refresh if stale (stale-while-revalidate).
  Future<List<AggregatedItem>> refreshIfStale({
    required String serverId,
    required String userId,
    LanguageSettings languageSettings = const LanguageSettings(),
  }) async {
    if (isStale) {
      return refreshCandidates(
        serverId: serverId,
        userId: userId,
        languageSettings: languageSettings,
      );
    }
    return _cachedCandidates;
  }

  /// Performs a full candidate refresh with deduplication, batching, and retry.
  Future<List<AggregatedItem>> refreshCandidates({
    required String serverId,
    required String userId,
    LanguageSettings languageSettings = const LanguageSettings(),
    bool force = false,
  }) async {
    // 1. Validate primary server context
    if (!_serverContext.validateRequest(serverId: serverId)) {
      debugPrint('[TasteRefreshService] Refresh skipped: Not connected to primary server');
      return _cachedCandidates;
    }

    // 2. Request deduplication: return in-flight future if already running
    if (_activeRefreshFuture != null) {
      return _activeRefreshFuture!;
    }

    _state = RefreshState.refreshing;
    _lastErrorMessage = null;
    notifyListeners();

    _activeRefreshFuture = _executeRefresh(
      serverId: serverId,
      userId: userId,
      languageSettings: languageSettings,
    );

    try {
      final results = await _activeRefreshFuture!;
      _cachedCandidates = results;
      _lastRefreshedAt = DateTime.now();
      _state = RefreshState.success;
      return results;
    } catch (e, st) {
      debugPrint('[TasteRefreshService] Refresh failed: $e\n$st');
      _lastErrorMessage = e.toString();
      _state = RefreshState.error;
      return _cachedCandidates; // Return stale cache on error (stale-while-revalidate)
    } finally {
      _activeRefreshFuture = null;
      notifyListeners();
    }
  }

  Future<List<AggregatedItem>> _executeRefresh({
    required String serverId,
    required String userId,
    required LanguageSettings languageSettings,
  }) async {
    final client = _clientProvider();
    final itemsList = <AggregatedItem>[];

    // Retry with exponential backoff (up to 3 attempts)
    int attempt = 0;
    const maxAttempts = 3;

    while (attempt < maxAttempts) {
      attempt++;
      try {
        int startIndex = 0;
        int totalRecords = _maxCandidates;

        while (startIndex < totalRecords && itemsList.length < _maxCandidates) {
          final res = await client.itemsApi.getItems(
            recursive: true,
            includeItemTypes: const ['Movie', 'Series'],
            fields:
                'Genres,People,Studios,Tags,Overview,CommunityRating,VoteCount,RunTimeTicks,PremiereDate,ProductionYear,UserData,SeriesId,OriginalLanguage,MediaStreams,SpokenLanguages',
            sortBy: 'CommunityRating,ProductionYear',
            sortOrder: 'Descending',
            startIndex: startIndex,
            limit: _batchSize,
          );

          final rawItems = (res['Items'] as List? ?? [])
              .whereType<Map<String, dynamic>>()
              .toList();

          totalRecords = (res['TotalRecordCount'] as num?)?.toInt() ?? rawItems.length;

          if (rawItems.isEmpty) break;

          for (final raw in rawItems) {
            final id = raw['Id']?.toString() ?? '';
            if (id.isEmpty) continue;

            final aggregated = AggregatedItem(
              id: id,
              serverId: serverId,
              rawData: raw,
            );

            // Filter out inaccessible/foreign items per settings
            if (TasteRecommendationEngine.isLanguageAllowed(
              item: aggregated,
              languageSettings: languageSettings,
            )) {
              itemsList.add(aggregated);
            }
          }

          startIndex += _batchSize;
        }

        return itemsList;
      } catch (e) {
        if (attempt >= maxAttempts) rethrow;
        final backoffMs = (500 * (1 << attempt));
        await Future.delayed(Duration(milliseconds: backoffMs));
      }
    }

    return itemsList;
  }

  /// Clears in-memory candidate cache (e.g. on server switch or logout).
  void clearCache() {
    _cachedCandidates = [];
    _lastRefreshedAt = null;
    _state = RefreshState.idle;
    _lastErrorMessage = null;
    _activeRefreshFuture = null;
    notifyListeners();
  }
}
