
import 'package:injectable/injectable.dart';
import '../../auth/store/voltix_session_store.dart';
import '../models/voltix_profile.dart';
import '../services/voltix_api_service.dart';

@lazySingleton
class VoltixProfileRepository {
  final VoltixApiService _apiService;
  final VoltixSessionStore _sessionStore;

  VoltixProfileRepository(this._apiService, this._sessionStore);

  String get _sessionToken {
    final token = _sessionStore.sessionToken;
    if (token == null) {
      throw Exception('No active session token');
    }
    return token;
  }

  Future<List<VoltixProfile>> listProfiles() async {
    final results = await _apiService.listProfiles(_sessionToken);
    return results.map((json) => VoltixProfile.fromJson(json)).toList();
  }

  Future<VoltixProfile> createProfile({
    required String name,
    String? avatarColor,
    String? avatarEmoji,
    String? avatarUrl,
    bool isKids = false,
  }) async {
    final result = await _apiService.createProfile(
      sessionToken: _sessionToken,
      name: name,
      avatarColor: avatarColor,
      avatarEmoji: avatarEmoji,
      avatarUrl: avatarUrl,
      isKids: isKids,
    );
    return VoltixProfile.fromJson(result);
  }

  Future<VoltixProfile> updateProfile(
    int id, {
    String? name,
    String? avatarColor,
    String? avatarEmoji,
    String? avatarUrl,
    bool? isKids,
  }) async {
    final result = await _apiService.updateProfile(
      sessionToken: _sessionToken,
      id: id,
      name: name,
      avatarColor: avatarColor,
      avatarEmoji: avatarEmoji,
      avatarUrl: avatarUrl,
      isKids: isKids,
    );
    return VoltixProfile.fromJson(result);
  }

  Future<void> deleteProfile(int id) async {
    final profiles = await listProfiles();
    final nonOwner = profiles.where((p) => !p.isOwner).toList();
    if (nonOwner.length <= 1) {
      throw Exception('Cannot delete the only profile. At least one profile must exist.');
    }
    await _apiService.deleteProfile(
      sessionToken: _sessionToken,
      id: id,
    );
  }

  Future<void> selectProfile(int id) async {
    await _apiService.selectProfile(
      sessionToken: _sessionToken,
      id: id,
    );
  }
}
