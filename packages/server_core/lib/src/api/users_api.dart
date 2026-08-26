import '../models/server_models.dart';
import '../models/system_models.dart';

abstract class UsersApi {
  Future<ServerUser> getCurrentUser();
  Future<UserConfiguration> getUserConfiguration();
  Future<void> updateUserConfiguration(UserConfiguration config);

  /// Uploads a new primary (profile) image for the given user.
  Future<void> uploadUserImage(
    String userId, {
    required List<int> bytes,
    required String contentType,
  });

  /// Removes the primary (profile) image of the given user.
  Future<void> deleteUserImage(String userId);
}
