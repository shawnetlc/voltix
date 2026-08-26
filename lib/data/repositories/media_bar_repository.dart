import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:server_core/server_core.dart';

import '../../preference/user_preferences.dart';
import '../models/media_bar_slide_item.dart';
import '../models/media_bar_state.dart';

class MediaBarRepository {
  static const _precacheBackdropCount = 1;
  static const _precacheLogoCount = 1;

  final MediaServerClient _client;
  final UserPreferences _prefs;

  static const _fields =
      'Type,Genres,OfficialRating,CommunityRating,CriticRating,'
      'RunTimeTicks,ProductionYear,ImageTags,BackdropImageTags,'
      'Overview,ProviderIds';

  MediaBarRepository(this._client, this._prefs);

  Future<MediaBarState> loadItems() async {
    final mediaBarMode = _prefs.get(UserPreferences.mediaBarMode);
    if (!UserPreferences.isMediaBarModeEnabled(mediaBarMode)) {
      return const MediaBarDisabled();
    }

    final contentType = _prefs.get(UserPreferences.mediaBarContentType);
    final pluginSyncEnabled = _prefs.get(UserPreferences.pluginSyncEnabled);

    final maxItems = pluginSyncEnabled
        ? (int.tryParse(_prefs.get(UserPreferences.mediaBarItemCount)) ?? 10)
        : 5;
    final libraryIds = pluginSyncEnabled
        ? _prefs
              .get(UserPreferences.mediaBarLibraryIds)
              .split(',')
              .where((s) => s.isNotEmpty)
              .toList()
        : <String>[];
    final collectionIds = pluginSyncEnabled
        ? _prefs
              .get(UserPreferences.mediaBarCollectionIds)
              .split(',')
              .where((s) => s.isNotEmpty)
              .toList()
        : <String>[];
    final excludedGenres = _prefs
        .get(UserPreferences.mediaBarExcludedGenres)
        .split(',')
        .where((s) => s.isNotEmpty)
        .toSet();

    final fetchLimit = maxItems + 2;

    final includeTypes = switch (contentType) {
      'movies' => const ['Movie'],
      'tvshows' => const ['Series'],
      _ => const ['Movie', 'Series'],
    };

    try {
      final allItems = <Map<String, dynamic>>[];

      final fetchTasks = <Future<List<Map<String, dynamic>>>>[];

      if (libraryIds.isEmpty && collectionIds.isEmpty) {
        fetchTasks.add(
          _fetchItems(includeTypes, fetchLimit)
              .catchError((_) => <Map<String, dynamic>>[]),
        );
      } else {
        for (final libraryId in libraryIds) {
          fetchTasks.add(
            _fetchItems(includeTypes, fetchLimit, parentId: libraryId)
                .catchError((_) => <Map<String, dynamic>>[]),
          );
        }
      }

      for (final collectionId in collectionIds) {
        fetchTasks.add(
          _fetchItems(includeTypes, fetchLimit, parentId: collectionId)
              .catchError((_) => <Map<String, dynamic>>[]),
        );
      }

      final fetchedBatches = await Future.wait(fetchTasks);
      for (final batch in fetchedBatches) {
        allItems.addAll(batch);
      }

      // If specific library/collection fetches returned nothing, try unrestricted fetch from the entire server
      if (allItems.isEmpty && (libraryIds.isNotEmpty || collectionIds.isNotEmpty)) {
        try {
          final fallback = await _fetchItems(includeTypes, fetchLimit);
          allItems.addAll(fallback);
        } catch (_) {}
      }

      // If still empty, try fallback with all types
      if (allItems.isEmpty) {
        try {
          final fallback = await _fetchItems(const ['Movie', 'Series'], fetchLimit);
          allItems.addAll(fallback);
        } catch (_) {}
      }

      // If still empty, try the first series/movies library directly (upstream 2.2.0 fallback)
      if (allItems.isEmpty) {
        try {
          final fallback = await _fetchItemsFromFirstSeriesOrMoviesLibrary(
            includeTypes,
            fetchLimit,
            contentType: contentType,
          );
          allItems.addAll(fallback);
        } catch (_) {}
      }

      // ── FILTERING & FALLBACK PATHS ──
      // Attempt 1: Strict filtering (has backdrop, not boxset, not excluded genre)
      var filtered = allItems
          .where((item) =>
              _hasBackdrop(item) &&
              !_isBoxSet(item) &&
              !_hasExcludedGenre(item, excludedGenres))
          .toList();

      // Attempt 2: Ignore excluded genres/boxsets if no items matched
      if (filtered.isEmpty) {
        filtered = allItems.where(_hasBackdrop).toList();
      }

      // Attempt 3: Fall back to items with ANY image (e.g. Primary image tag) if no backdrops exist
      if (filtered.isEmpty) {
        filtered = allItems.where((item) =>
            _hasBackdrop(item) ||
            (item['ImageTags'] as Map?)?.containsKey('Primary') == true ||
            (item['ImageTags'] as Map?)?.isNotEmpty == true
        ).toList();
      }

      // Attempt 4: Use all returned items directly
      if (filtered.isEmpty) {
        filtered = allItems;
      }

      filtered.shuffle();
      final selected = filtered.take(maxItems).toList();

      // We should never return MediaBarError to prevent UI crashes. Hide silently if nothing is found.
      if (selected.isEmpty) {
        return const MediaBarReady([]);
      }

      final items = selected.map(_toSlideItem).toList();
      return MediaBarReady(items);
    } catch (e) {
      debugPrint('[MediaBarRepository] Gracefully caught loadItems error: $e');
      try {
        final firstLibraryItems =
            await _fetchItemsFromFirstSeriesOrMoviesLibrary(
              includeTypes,
              fetchLimit,
              contentType: contentType,
            );
        final selected = _selectItemsWithBackdrops(
          firstLibraryItems,
          maxItems,
          excludedGenres,
        );
        if (selected.isNotEmpty) {
          final items = selected.map(_toSlideItem).toList();
          return MediaBarReady(items);
        }
      } catch (_) {}
      return const MediaBarReady([]);
    }
  }

  List<Map<String, dynamic>> _selectItemsWithBackdrops(
    List<Map<String, dynamic>> source,
    int maxItems,
    Set<String> excludedGenres,
  ) {
    final withBackdrops =
        source
            .where(
              (item) =>
                  _hasBackdrop(item) &&
                  !_isBoxSet(item) &&
                  !_hasExcludedGenre(item, excludedGenres),
            )
            .toList()
          ..shuffle();
    return withBackdrops.take(maxItems).toList();
  }

  Future<List<Map<String, dynamic>>> _fetchItemsFromFirstSeriesOrMoviesLibrary(
    List<String>? itemTypes,
    int limit, {
    required String contentType,
  }) async {
    try {
      final viewsResponse = await _client.userViewsApi.getUserViews().timeout(
        const Duration(seconds: 4),
      );
      final views = (viewsResponse['Items'] as List? ?? [])
          .cast<Map<String, dynamic>>();
      if (views.isEmpty) {
        return const <Map<String, dynamic>>[];
      }

      final preferredCollectionTypes = switch (contentType) {
        'movies' => const ['movies'],
        'tvshows' => const ['tvshows'],
        _ => const ['tvshows', 'movies'],
      };

      String? libraryId;

      for (final preferredType in preferredCollectionTypes) {
        for (final view in views) {
          final collectionType = _normalizeCollectionType(
            view['CollectionType'],
          );
          if (collectionType != preferredType) {
            continue;
          }
          final id = view['Id']?.toString();
          if (id != null && id.isNotEmpty) {
            libraryId = id;
            break;
          }
        }
        if (libraryId != null) {
          break;
        }
      }

      if (libraryId == null) {
        for (final view in views) {
          final collectionType = _normalizeCollectionType(
            view['CollectionType'],
          );
          if (collectionType != 'tvshows' && collectionType != 'movies') {
            continue;
          }
          final id = view['Id']?.toString();
          if (id != null && id.isNotEmpty) {
            libraryId = id;
            break;
          }
        }
      }

      if (libraryId == null) {
        return const <Map<String, dynamic>>[];
      }

      return _fetchItems(itemTypes, limit, parentId: libraryId);
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  String _normalizeCollectionType(Object? value) {
    return value?.toString().trim().toLowerCase() ?? '';
  }

  void precacheImages(BuildContext context, List<MediaBarSlideItem> items) {
    for (final item in items.take(_precacheBackdropCount)) {
      if (item.backdropUrl != null) {
        precacheImage(CachedNetworkImageProvider(item.backdropUrl!), context);
      }
    }
    for (final item in items.take(_precacheLogoCount)) {
      if (item.logoUrl != null) {
        precacheImage(CachedNetworkImageProvider(item.logoUrl!), context);
      }
    }
  }

  Future<List<Map<String, dynamic>>> _fetchItems(
    List<String>? itemTypes,
    int limit, {
    String? parentId,
  }) async {
    try {
      final response = await _client.itemsApi
          .getItems(
            includeItemTypes: itemTypes,
            sortBy: 'Random',
            sortOrder: 'Descending',
            recursive: true,
            parentId: parentId,
            limit: limit,
            fields: _fields,
            enableTotalRecordCount: false,
            enableImageTypes: 'Backdrop,Logo',
          )
          .timeout(const Duration(seconds: 3));
      final rawItems = response['Items'] as List? ?? [];
      return rawItems.cast<Map<String, dynamic>>();
    } on TimeoutException {
      return _fetchItemsFromFallbackSource(
        itemTypes,
        limit,
        parentId: parentId,
      );
    } on DioException catch (e) {
      final statusCode = e.response?.statusCode ?? 0;
      if (statusCode == 401 || statusCode == 403) {
        return const <Map<String, dynamic>>[];
      }
      return _fetchItemsFromFallbackSource(
        itemTypes,
        limit,
        parentId: parentId,
      );
    } catch (_) {
      return _fetchItemsFromFallbackSource(
        itemTypes,
        limit,
        parentId: parentId,
      );
    }
  }

  Future<List<Map<String, dynamic>>> _fetchItemsFromFallbackSource(
    List<String>? itemTypes,
    int limit, {
    String? parentId,
  }) async {
    final reducedLimit = limit > 24 ? 24 : limit;

    try {
      final latestResponse = await _client.itemsApi
          .getLatestItems(
            includeItemTypes: itemTypes,
            parentId: parentId,
            limit: reducedLimit,
            fields: _fields,
          )
          .timeout(const Duration(seconds: 4));
      final rawItems = latestResponse['Items'] as List? ?? [];
      return rawItems.cast<Map<String, dynamic>>();
    } catch (_) {}

    try {
      final fallbackResponse = await _client.itemsApi
          .getItems(
            includeItemTypes: itemTypes,
            sortBy: 'SortName',
            sortOrder: 'Ascending',
            recursive: true,
            parentId: parentId,
            limit: reducedLimit,
            fields: _fields,
            enableTotalRecordCount: false,
            enableImageTypes: 'Backdrop,Logo',
          )
          .timeout(const Duration(seconds: 4));
      final rawItems = fallbackResponse['Items'] as List? ?? [];
      return rawItems.cast<Map<String, dynamic>>();
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  bool _hasBackdrop(Map<String, dynamic> item) {
    final tags = item['BackdropImageTags'] as List?;
    return tags != null && tags.isNotEmpty;
  }

  bool _isBoxSet(Map<String, dynamic> item) {
    return item['Type'] == 'BoxSet';
  }

  bool _hasExcludedGenre(Map<String, dynamic> item, Set<String> excluded) {
    if (excluded.isEmpty) return false;
    final genres = (item['Genres'] as List?)?.cast<String>() ?? [];
    return genres.any((g) => excluded.contains(g));
  }

  /// Items for the setup wizard previews, free of the bar's own rules.
  ///
  /// The bar refuses to run without a movies or series library, and again
  /// without backdrop artwork, and both refusals hold for the whole session
  /// no matter how often it is asked. The previews only need something real
  /// to draw, so this takes the newest items across everything the user can
  /// see and keeps whatever comes back, posters and all.
  Future<List<MediaBarSlideItem>> fetchPreviewItems({int limit = 10}) async {
    try {
      final response = await _client.itemsApi
          .getItems(
            includeItemTypes: const ['Movie', 'Series'],
            sortBy: 'DateCreated',
            sortOrder: 'Descending',
            recursive: true,
            limit: limit,
            fields: _fields,
          )
          .timeout(const Duration(seconds: 15));
      final items = (response['Items'] as List? ?? [])
          .cast<Map<String, dynamic>>();
      return items.map(_toSlideItem).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  MediaBarSlideItem _toSlideItem(Map<String, dynamic> data) {
    final itemId = data['Id']?.toString() ?? '';
    final serverId = data['ServerId']?.toString() ?? '';
    final providerIds = data['ProviderIds'] as Map<String, dynamic>?;

    final backdropTags = data['BackdropImageTags'] as List?;
    var backdropUrl = (backdropTags != null && backdropTags.isNotEmpty)
        ? _client.imageApi.getBackdropImageUrl(
            itemId,
            tag: backdropTags[0] as String,
            maxWidth: 1280,
          )
        : null;

    if (backdropUrl == null) {
      final primaryTag = (data['ImageTags'] as Map?)?['Primary'] as String?;
      if (primaryTag != null) {
        backdropUrl = _client.imageApi.getPrimaryImageUrl(itemId, tag: primaryTag, maxWidth: 1280);
      }
    }

    final logoTag = (data['ImageTags'] as Map?)?['Logo'] as String?;
    final logoUrl = logoTag != null
        ? _client.imageApi.getLogoImageUrl(itemId, tag: logoTag, maxWidth: 600)
        : null;

    final primaryTag = (data['ImageTags'] as Map?)?['Primary'] as String?;
    final posterUrl = _client.imageApi.getPrimaryImageUrl(
      itemId,
      tag: primaryTag,
    );

    final runTimeTicks = data['RunTimeTicks'] as int?;

    return MediaBarSlideItem(
      itemId: itemId,
      serverId: serverId,
      title: data['Name'] as String? ?? '',
      overview: data['Overview'] as String?,
      backdropUrl: backdropUrl,
      logoUrl: logoUrl,
      posterUrl: posterUrl,
      officialRating: data['OfficialRating'] as String?,
      year: data['ProductionYear'] as int?,
      genres:
          (data['Genres'] as List?)?.cast<String>().take(3).toList() ??
          const [],
      runtime: runTimeTicks != null
          ? Duration(microseconds: runTimeTicks ~/ 10)
          : null,
      communityRating: (data['CommunityRating'] as num?)?.toDouble(),
      criticRating: (data['CriticRating'] as num?)?.toInt(),
      tmdbId: providerIds?['Tmdb'] as String?,
      imdbId: providerIds?['Imdb'] as String?,
      itemType: data['Type'] as String? ?? 'Movie',
      remoteTrailers:
          (data['RemoteTrailers'] as List?)?.cast<Map<String, dynamic>>() ??
          const [],
    );
  }
}
