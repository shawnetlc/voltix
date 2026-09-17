import 'package:server_core/server_core.dart';
import 'package:get_it/get_it.dart';
import '../models/aggregated_item.dart';
import '../services/voltix_favorites_registry_service.dart';
class ItemMutationRepository {
  final MediaServerClient _client;

  ItemMutationRepository(this._client);

  Future<void> setFavorite(String itemId, {required bool isFavorite, AggregatedItem? item}) async {
    if (isFavorite) {
      await _client.userLibraryApi.markFavorite(itemId);
    } else {
      await _client.userLibraryApi.unmarkFavorite(itemId);
    }

    try {
      final registry = GetIt.instance<VoltixFavoritesRegistryService>();
      final serverId = _client.baseUrl;
      
      if (isFavorite) {
        if (item != null) {
          await registry.addFavorite(item);
        } else {
          await registry.addFavoriteById(itemId, serverId);
        }
      } else {
        await registry.removeFavoriteById(itemId, serverId);
      }
    } catch (e) {
      // Registry service might not be registered or available, fail silently
    }
  }

  Future<void> setPlayed(String itemId, {required bool isPlayed}) async {
    if (isPlayed) {
      await _client.userLibraryApi.markPlayed(itemId);
    } else {
      await _client.userLibraryApi.unmarkPlayed(itemId);
    }
  }

  Future<void> setRating(String itemId, {required bool likes}) async {
    await _client.userLibraryApi.updateUserRating(itemId, likes: likes);
  }

  Future<void> setNumericRating(String itemId, {required double rating}) async {
    await _client.userLibraryApi.updateNumericUserRating(itemId, rating: rating);
  }

  Future<void> clearRating(String itemId) async {
    await _client.userLibraryApi.deleteUserRating(itemId);
  }

  Future<void> addToCollection(String collectionId, List<String> itemIds) async {
    await _client.itemsApi.addToCollection(collectionId, itemIds);
  }

  Future<Map<String, dynamic>> createCollection({
    required String name,
    List<String>? itemIds,
  }) async {
    return _client.itemsApi.createCollection(name: name, itemIds: itemIds);
  }

  Future<void> refreshMetadata(
    String itemId, {
    bool? recursive,
    bool? replaceAllMetadata,
    bool? replaceAllImages,
  }) async {
    await _client.adminItemsApi.refreshItem(
      itemId,
      recursive: recursive,
      replaceAllMetadata: replaceAllMetadata,
      replaceAllImages: replaceAllImages,
    );
  }
}
