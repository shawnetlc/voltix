import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:server_core/server_core.dart';

import '../../preference/user_preferences.dart';

import '../../l10n/current_app_localizations.dart';
import '../models/aggregated_item.dart';
import '../repositories/multi_server_repository.dart';
import '../repositories/search_repository.dart';
import '../repositories/seerr_repository.dart';
import '../services/seerr/seerr_api_models.dart';
import '../../util/user_facing_error.dart';

class SearchResultGroup {
  final String title;
  final List<String> itemTypes;
  final List<AggregatedItem> items;

  const SearchResultGroup({
    required this.title,
    required this.itemTypes,
    this.items = const [],
  });

  SearchResultGroup copyWith({List<AggregatedItem>? items}) =>
      SearchResultGroup(title: title, itemTypes: itemTypes, items: items ?? this.items);
}

enum SearchState { idle, loading, ready, error }

class SearchViewModel extends ChangeNotifier {
  final SearchRepository _searchRepository;
  final MediaServerClient _client;
  final MultiServerRepository? _multiServerRepo;
  final String? _scopedParentId;
  SeerrRepository? _seerrRepository;

  SearchViewModel(
    this._searchRepository,
    this._client, {
    MultiServerRepository? multiServerRepo,
    SeerrRepository? seerrRepository,
    String? scopedParentId,
  }) : _multiServerRepo = multiServerRepo,
       _seerrRepository = seerrRepository,
       _scopedParentId =
           (scopedParentId != null && scopedParentId.isNotEmpty)
               ? scopedParentId
               : null;

  void setSeerrRepository(SeerrRepository repo) {
    _seerrRepository = repo;
  }

  ImageApi get imageApi => _client.imageApi;

  /// Resolves the correct [ImageApi] for an item based on the server it came
  /// from, so multi-server search results load artwork from their own server.
  ImageApi imageApiForServer(String serverId) {
    final repo = _multiServerRepo;
    if (repo != null && serverId.isNotEmpty) {
      return repo.getImageApiForServer(serverId);
    }
    return _client.imageApi;
  }

  SearchState _state = SearchState.idle;
  SearchState get state => _state;

  String _query = '';
  String get query => _query;

  List<SearchResultGroup> _results = const [];
  List<SearchResultGroup> get results => _results;

  /// Variants (server + quality combinations) for a collapsed search result,
  /// keyed by the representative item's server-scoped id. Populated only for
  /// multi-server searches where the same title exists on >1 server/quality.
  /// Single-variant results are never present here.
  final Map<String, List<AggregatedItem>> _variantsByRepKey = {};

  /// Returns the list of variants for a grouped result card. A length of <2
  /// means the item is a plain single result and should behave as before.
  List<AggregatedItem> variantsFor(AggregatedItem item) =>
      _variantsByRepKey[_repKey(item)] ?? const [];

  String _repKey(AggregatedItem item) => '${item.serverId}|${item.id}';

  List<SeerrDiscoverItem> _seerrResults = const [];
  List<SeerrDiscoverItem> get seerrResults => _seerrResults;

  String _errorMessage = '';
  String get errorMessage => _errorMessage;

  Timer? _debounceTimer;

  static const _debounceMs = 600;
  static const _resultLimit = 24;
  static const _globalFetchLimit = 240;

  static List<SearchResultGroup> _bookSearchGroups() {
    final l10n = currentAppLocalizations();
    return [
      SearchResultGroup(title: l10n.books, itemTypes: const ['Book']),
      SearchResultGroup(title: l10n.audiobooks, itemTypes: const ['AudioBook']),
    ];
  }

  static List<SearchResultGroup> _searchGroups() {
    final l10n = currentAppLocalizations();
    return [
      SearchResultGroup(title: l10n.books, itemTypes: const ['Book']),
      SearchResultGroup(title: l10n.movies, itemTypes: const ['Movie']),
      SearchResultGroup(title: l10n.series, itemTypes: const ['Series']),
      SearchResultGroup(title: l10n.seasons, itemTypes: const ['Season']),
      SearchResultGroup(title: l10n.episodes, itemTypes: const ['Episode']),
      SearchResultGroup(title: l10n.videos, itemTypes: const ['Video']),
      SearchResultGroup(title: l10n.musicVideos, itemTypes: const ['MusicVideo']),
      SearchResultGroup(title: l10n.trailers, itemTypes: const ['Trailer']),
      SearchResultGroup(title: l10n.programs, itemTypes: const ['Program']),
      SearchResultGroup(title: l10n.channels, itemTypes: const ['LiveTvChannel']),
      SearchResultGroup(title: l10n.playlists, itemTypes: const ['Playlist']),
      SearchResultGroup(
        title: l10n.artists,
        itemTypes: const ['MusicArtist', 'AlbumArtist'],
      ),
      SearchResultGroup(title: l10n.albums, itemTypes: const ['MusicAlbum']),
      SearchResultGroup(title: l10n.songs, itemTypes: const ['Audio']),
      SearchResultGroup(title: l10n.photoAlbums, itemTypes: const ['PhotoAlbum']),
      SearchResultGroup(title: l10n.photos, itemTypes: const ['Photo']),
      SearchResultGroup(title: l10n.collections, itemTypes: const ['BoxSet']),
      SearchResultGroup(title: l10n.people, itemTypes: const ['Person']),
      SearchResultGroup(
        title: l10n.folders,
        itemTypes: const ['Folder', 'CollectionFolder', 'UserView'],
      ),
    ];
  }

  void searchDebounced(String query) {
    final trimmed = query.trim();
    if (trimmed == _query) return;
    _query = trimmed;

    _debounceTimer?.cancel();

    if (trimmed.isEmpty) {
      _results = const [];
      _seerrResults = const [];
      _variantsByRepKey.clear();
      _state = SearchState.idle;
      notifyListeners();
      return;
    }

    _state = SearchState.loading;
    notifyListeners();

    _debounceTimer = Timer(
      const Duration(milliseconds: _debounceMs),
      () => _executeSearch(trimmed),
    );
  }

  void searchImmediate(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    _query = trimmed;
    _debounceTimer?.cancel();
    _state = SearchState.loading;
    notifyListeners();
    _executeSearch(trimmed);
  }

  Future<void> _executeSearch(String query) async {
    if (query != _query) return;

    _variantsByRepKey.clear();

    try {
        final activeGroups = _scopedParentId != null
          ? _bookSearchGroups()
          : _searchGroups();
      final seerrFuture = _fetchSeerrResults(query);

      final groups = _scopedParentId != null
          ? await Future.wait(activeGroups.map((group) async {
              final items = await _searchRepository.search(
                query,
                includeItemTypes: group.itemTypes,
                parentId: _scopedParentId,
                limit: _resultLimit,
              );
              return group.copyWith(items: items);
            }))
          : await _buildGroupedGlobalResults(query, activeGroups);
      final seerr = await seerrFuture;

      if (query != _query) return;

      _results = groups.where((g) => g.items.isNotEmpty).toList();
      _seerrResults = seerr;
      _state = SearchState.ready;
    } catch (e) {
      if (query != _query) return;
      _errorMessage = userFacingError(e);
      _state = SearchState.error;
    }
    notifyListeners();
  }

  /// Whether search should fan out across every signed-in server. Controlled by
  /// Settings > Personalization > Libraries > "Enable multi-server search"
  /// (on by default). Falls back to enabled if preferences aren't available.
  bool get _multiServerSearchEnabled {
    if (!GetIt.instance.isRegistered<UserPreferences>()) return true;
    return GetIt.instance<UserPreferences>()
        .get(UserPreferences.enableMultiServerSearch);
  }

  /// Fetches the flat item list for a global (non-scoped) search. When the
  /// account is connected to more than one server, the search fans out across
  /// every connected server and merges the results (each tagged with its
  /// origin server + quality). With a single server the behaviour is unchanged.
  ///
  /// [includeItemTypes] MUST be passed to the server. Person entries are not
  /// part of the recursive media-library tree the way Movies/Series are --
  /// Jellyfin/Emby only look in the separate People index when a query
  /// explicitly asks for the 'Person' type. Leaving includeItemTypes null
  /// (as this used to) made the server quietly drop actors from every
  /// global/home search, even though the client already had a ready-to-show
  /// "People" result group waiting for them.
  Future<List<AggregatedItem>> _fetchGlobalItems(
    String query,
    List<String> includeItemTypes,
  ) async {
    final repo = _multiServerRepo;
    if (repo != null && _multiServerSearchEnabled) {
      try {
        final sessions = await repo.getLoggedInServers();
        if (sessions.length > 1) {
          return repo.searchAllServers(
            query,
            includeItemTypes: includeItemTypes,
            limit: _globalFetchLimit,
          );
        }
      } catch (_) {
        // Fall through to single-server search on any resolution error.
      }
    }
    return _searchRepository.search(
      query,
      includeItemTypes: includeItemTypes,
      parentId: _scopedParentId,
      limit: _globalFetchLimit,
    );
  }

  Future<List<SearchResultGroup>> _buildGroupedGlobalResults(
    String query,
    List<SearchResultGroup> activeGroups,
  ) async {
    final allItems = await _fetchGlobalItems(
      query,
      activeGroups.expand((g) => g.itemTypes).toSet().toList(),
    );

    final grouped = <SearchResultGroup>[];
    for (final group in activeGroups) {
      final matched = allItems
          .where((item) => group.itemTypes.contains(item.type))
          .toList();
      final collapsed = _collapseVariants(matched).take(_resultLimit).toList();
      grouped.add(group.copyWith(items: collapsed));
    }

    return grouped;
  }

  /// Collapses items that represent the SAME title (across servers/qualities)
  /// into a single representative entry, preserving first-seen order. When a
  /// title has >=2 variants the highest-quality variant becomes the card shown,
  /// and the full variant list is recorded in [_variantsByRepKey] so the UI can
  /// offer a chooser. Titles with a single variant are returned unchanged.
  List<AggregatedItem> _collapseVariants(List<AggregatedItem> items) {
    final order = <String>[];
    final byKey = <String, List<AggregatedItem>>{};
    for (final item in items) {
      final key = _variantGroupKey(item);
      final existing = byKey[key];
      if (existing == null) {
        order.add(key);
        byKey[key] = [item];
      } else {
        existing.add(item);
      }
    }

    final collapsed = <AggregatedItem>[];
    for (final key in order) {
      final variants = byKey[key]!;
      if (variants.length < 2) {
        collapsed.add(variants.first);
        continue;
      }
      final representative = _pickRepresentative(variants);
      _variantsByRepKey[_repKey(representative)] = variants;
      collapsed.add(representative);
    }
    return collapsed;
  }

  /// Normalises a title to a grouping key: lower-cased trimmed name + type
  /// (+ production year when known) so the same movie on two servers collapses
  /// while distinct titles/types/years stay separate.
  String _variantGroupKey(AggregatedItem item) {
    final title = item.name.trim().toLowerCase();
    final type = item.type ?? '';
    final year = item.productionYear;
    return year != null ? '$type|$title|$year' : '$type|$title';
  }

  /// Picks the variant to show for a collapsed card, preferring the highest
  /// video quality (8K > 4K > 1440 > 1080 > 720 > lower); ties and unknown
  /// qualities keep the first-seen item.
  AggregatedItem _pickRepresentative(List<AggregatedItem> variants) {
    var best = variants.first;
    var bestRank = _qualityRank(best);
    for (final variant in variants.skip(1)) {
      final rank = _qualityRank(variant);
      if (rank > bestRank) {
        best = variant;
        bestRank = rank;
      }
    }
    return best;
  }

  int _qualityRank(AggregatedItem item) {
    final res = item.videoResolution?.toLowerCase() ?? '';
    if (res.startsWith('8k')) return 6;
    if (res.startsWith('4k')) return 5;
    if (res.startsWith('1440')) return 4;
    if (res.startsWith('1080')) return 3;
    if (res.startsWith('720')) return 2;
    if (res.isNotEmpty) return 1;
    return 0;
  }

  Future<List<SeerrDiscoverItem>> _fetchSeerrResults(String query) async {
    if (_scopedParentId != null) return const [];
    if (query.trim().toLowerCase().startsWith('studio:')) return const [];
    final repo = _seerrRepository;
    if (repo == null) return const [];
    try {
      await repo.ensureInitialized();
      if (!repo.isAvailable) return const [];
      final page = await repo.search(query, limit: _resultLimit);
      return page.results;
    } catch (_) {
      return const [];
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    super.dispose();
  }
}
