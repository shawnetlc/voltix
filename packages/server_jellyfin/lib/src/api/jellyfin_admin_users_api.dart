import 'package:dio/dio.dart';
import 'package:server_core/server_core.dart';

class JellyfinAdminUsersApi implements AdminUsersApi {
  final Dio _dio;

  JellyfinAdminUsersApi(this._dio);

  @override
  Future<List<ServerUser>> getUsers({bool? isDisabled, bool? isHidden}) async {
    final results = <String, ServerUser>{};
    Object? lastError;

    // 1. Query main /Users endpoint
    try {
      final params = <String, dynamic>{};
      if (isDisabled != null) params['isDisabled'] = isDisabled;
      if (isHidden != null) params['isHidden'] = isHidden;
      final response = await _dio.get('/Users', queryParameters: params);
      if (response.data is List) {
        for (final item in response.data as List) {
          if (item is Map<String, dynamic>) {
            final u = ServerUser.fromJson(item);
            if (u.id.isNotEmpty) results[u.id] = u;
          }
        }
      }
    } catch (e) {
      lastError = e;
    }

    // 2. Query /Users/Public to ensure public accounts are captured
    try {
      final response = await _dio.get('/Users/Public');
      if (response.data is List) {
        for (final item in response.data as List) {
          if (item is Map<String, dynamic>) {
            final u = ServerUser.fromJson(item);
            if (u.id.isNotEmpty && !results.containsKey(u.id)) {
              results[u.id] = u;
            }
          }
        }
      }
    } catch (e) {
      lastError ??= e;
    }

    if (results.isEmpty && lastError != null) {
      throw lastError;
    }

    return results.values.toList();
  }

  @override
  Future<ServerUser> getUserById(String userId) async {
    final response = await _dio.get('/Users/$userId');
    return ServerUser.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<ServerUser> createUser(String name, String? password) async {
    final response = await _dio.post(
      '/Users/New',
      data: {
        'Name': name,
        'Password': ?password,
      },
    );
    return ServerUser.fromJson(response.data as Map<String, dynamic>);
  }

  @override
  Future<void> deleteUser(String userId) async {
    await _dio.delete('/Users/$userId');
  }

  @override
  Future<void> updateUser(String userId, Map<String, dynamic> userData) async {
    final payload = <String, dynamic>{
      'Name': userData['Name'],
      'Configuration': userData['Configuration'] ?? <String, dynamic>{},
    };

    try {
      await _dio.post(
        '/Users',
        queryParameters: {'userId': userId},
        data: payload,
      );
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 400 || status == 404 || status == 405) {
        await _dio.post('/Users/$userId', data: payload);
        return;
      }
      rethrow;
    }
  }

  @override
  Future<void> updateUserPolicy(
    String userId,
    Map<String, dynamic> policy,
  ) async {
    await _dio.post('/Users/$userId/Policy', data: policy);
  }

  @override
  Future<void> updateUserPassword(
    String userId, {
    String? newPassword,
    bool resetPassword = false,
  }) async {
    await _dio.post(
      '/Users/$userId/Password',
      data: {
        'NewPw': ?newPassword,
        'ResetPassword': resetPassword,
      },
    );
  }
}
