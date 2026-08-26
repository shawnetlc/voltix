import 'package:flutter/foundation.dart';
import 'package:server_core/server_core.dart';

import '../models/aggregated_library.dart';

class UserViewsRepository extends ChangeNotifier {
  final MediaServerClient _client;
  UserConfiguration? _cachedConfig;

  UserViewsRepository(this._client);

  Future<List<AggregatedLibrary>> getAllViews() async {
    final response = await _client.userViewsApi.getUserViews();
    final items = response['Items'] as List? ?? [];

    return items.map((item) {
      final data = item as Map<String, dynamic>;
      return AggregatedLibrary(
        id: data['Id']?.toString() ?? '',
        name: data['Name'] as String,
        collectionType: data['CollectionType'] as String? ?? '',
        serverId: data['ServerId']?.toString() ?? '',
        primaryImageAspectRatio: (data['PrimaryImageAspectRatio'] as num?)
            ?.toDouble(),
        imageTags: data['ImageTags'] != null
            ? Map<String, dynamic>.from(data['ImageTags'] as Map)
            : null,
        backdropImageTags: (data['BackdropImageTags'] as List?)
            ?.map((e) => e.toString())
            .toList(),
      );
    }).toList();
  }

  Future<List<AggregatedLibrary>> getAllViewsIncludingHidden() async {
    try {
      final folders = await _client.adminLibraryApi.getMediaFolders();
      return folders
          .map(
            (folder) => AggregatedLibrary(
              id: folder.itemId,
              name: folder.name,
              collectionType: folder.collectionType ?? '',
              serverId: '',
            ),
          )
          .toList();
    } catch (_) {
      return getAllViews();
    }
  }

  Future<List<AggregatedLibrary>> getUserViews() async {
    final views = await getAllViews();
    try {
      final config = await _getUserConfig();
      final excludes = config.myMediaExcludes.toSet();
      if (excludes.isEmpty) return views;
      return views.where((v) => !excludes.contains(v.id)).toList();
    } catch (_) {
      return views;
    }
  }

  /// What the user hid from My Media, read from the cached configuration so a
  /// caller can ask on every row without a round trip each time. Empty when
  /// nothing is hidden or the list can't be read.
  ///
  /// Used by Moonfin Recommends to decide whether a candidate search needs to
  /// visit libraries individually or can sweep the whole server in one query.
  Future<Set<String>> getMyMediaExcludes() async {
    try {
      final config = await _getUserConfig();
      return config.myMediaExcludes.toSet();
    } catch (_) {
      return const {};
    }
  }

  Future<UserConfiguration> _getUserConfig() async {
    _cachedConfig ??= await _client.usersApi.getUserConfiguration();
    return _cachedConfig!;
  }

  Future<UserConfiguration> getUserConfiguration() async {
    _cachedConfig = await _client.usersApi.getUserConfiguration();
    return _cachedConfig!;
  }

  Future<void> updateUserConfiguration(UserConfiguration config) async {
    await _client.usersApi.updateUserConfiguration(config);
    _cachedConfig = config;
    notifyListeners();
  }

  void invalidateConfigCache() => _cachedConfig = null;
}
