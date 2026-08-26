import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:logger/logger.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import '../../auth/repositories/session_repository.dart';
import '../../auth/store/voltix_session_store.dart';
import '../../ui/navigation/app_router.dart';
import '../../ui/navigation/destinations.dart';
import '../../preference/user_preferences.dart';

/// Dart client for the Voltix tRPC API.
///
/// All endpoints are called on the Voltix server at [baseUrl] using the
/// `/api/trpc/voltix.*` convention.  The [directLogin] mutation is the
/// primary entry-point for mobile/TV clients.
class VoltixApiService {
  static const String defaultBaseUrl = 'https://www.voltixstudio.com';

  final Dio _dio;
  final Logger _logger = Logger();
  final String? _baseUrlOverride;

  String get baseUrl {
    if (_baseUrlOverride != null) return _baseUrlOverride;
    try {
      final preferenceStore = GetIt.instance<PreferenceStore>();
      final useTest = preferenceStore.get(UserPreferences.voltixUseTestServer);
      return useTest ? 'http://192.168.0.31:3000' : 'https://www.voltixstudio.com';
    } catch (_) {
      return defaultBaseUrl;
    }
  }

  VoltixApiService({String? baseUrl})
      : _baseUrlOverride = baseUrl,
        _dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          headers: {'Content-Type': 'application/json'},
        )) {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onError: (DioException error, handler) async {
          if (error.response?.statusCode == 401) {
            _logger.w('[VoltixApi] Unauthorized 401 detected. Redirecting to native login.');
            try {
              final voltixStore = GetIt.instance<VoltixSessionStore>();
              await voltixStore.clear();
              final sessionRepo = GetIt.instance<SessionRepository>();
              await sessionRepo.destroyCurrentSession();
            } catch (e) {
              _logger.e('[VoltixApi] Error clearing session: $e');
            }
            appRouter.go(Destinations.voltixLogin);
          }
          return handler.next(error);
        },
      ),
    );
  }

  // ───────────────────────── directLogin ─────────────────────────

  /// Authenticates a Voltix user and returns a session token together with
  /// assigned Lumistream server information.
  Future<VoltixLoginResult> directLogin({
    required String username,
    required String password,
    String? deviceName,
    String? deviceType,
    int? serverId,
    String? macAddress,
    bool forceReplace = false,
  }) async {
    final url = '$baseUrl/api/trpc/voltix.directLogin';
    _logger.i('[VoltixApi] directLogin: username=$username device=$deviceName');

    try {
      final response = await _dio.post(url, data: {
        'json': {
          'username': username,
          'password': password,
          'deviceName':? deviceName,
          'deviceType':? deviceType,
          'serverId':? serverId,
          'macAddress':? macAddress,
          // When true, the backend should disconnect the oldest active session
          // to make room instead of rejecting with a device-limit error.
          'forceReplace': forceReplace,
        },
      });

      final data = response.data;
      final result = (data is Map && data.containsKey('result'))
          ? data['result']
          : data;
      final resultData = (result is Map && result.containsKey('data'))
          ? result['data']
          : result;
      final json = (resultData is Map && resultData.containsKey('json'))
          ? resultData['json']
          : resultData;

      if (json is! Map) {
        throw VoltixApiException(
          'The server returned an unexpected login response '
          '(${json.runtimeType}). Expected a JSON object.',
        );
      }
      return VoltixLoginResult.fromJson(Map<String, dynamic>.from(json));
    } on DioException catch (e) {
      final msg = _extractTrpcError(e) ?? 'Login failed';
      _logger.e('[VoltixApi] directLogin failed: $msg');
      throw VoltixApiException(msg);
    }
  }

  // ───────────────────────── registerAccount ─────────────────────────

  /// Registers a new Voltix account (24h Trial or Paid Subscription).
  ///
  /// Submits trial or paid package & payment details to backend, then performs
  /// automatic login to return session credentials and Lumistream server data.
  Future<VoltixLoginResult> registerAccount({
    required String username,
    required String email,
    required String password,
    required bool isTrial,
    String? packageId,
    String? packageName,
    double? packagePrice,
    String? paymentMethod,
    Map<String, dynamic>? paymentDetails,
    String? deviceName,
    String? deviceType,
    String? macAddress,
  }) async {
    final url = '$baseUrl/api/trpc/voltix.register';
    _logger.i('[VoltixApi] registerAccount: username=$username trial=$isTrial package=$packageId method=$paymentMethod');

    final payload = {
      'username': username,
      'email': email,
      'password': password,
      'isTrial': isTrial,
      'packageId': packageId ?? (isTrial ? 'trial_24h' : 'monthly'),
      'packageName': packageName ?? (isTrial ? '24h Free Trial' : '1 Month Subscription'),
      'packagePrice': packagePrice ?? (isTrial ? 0.0 : 9.99),
      'paymentMethod': paymentMethod ?? (isTrial ? 'free_trial' : 'credit_card'),
      'paymentDetails': paymentDetails ?? {},
      'deviceName': deviceName,
      'deviceType': deviceType,
      'macAddress': macAddress,
    };

    try {
      final response = await _dio.post(url, data: {'json': payload});

      final data = response.data;
      final result = (data is Map && data.containsKey('result')) ? data['result'] : data;
      final resultData = (result is Map && result.containsKey('data')) ? result['data'] : result;
      final json = (resultData is Map && resultData.containsKey('json')) ? resultData['json'] : resultData;

      if (json is Map<String, dynamic> && json.containsKey('sessionToken')) {
        return VoltixLoginResult.fromJson(json);
      }
    } on DioException catch (e) {
      _logger.w('[VoltixApi] tRPC register failed (${e.response?.statusCode}), attempting REST fallback');
    } catch (e) {
      _logger.w('[VoltixApi] tRPC register error: $e, attempting REST fallback');
    }

    // Try REST fallback endpoint /api/auth/register
    try {
      final restResponse = await _dio.post(
        '$baseUrl/api/auth/register',
        data: payload,
      );
      if (restResponse.statusCode == 200 || restResponse.statusCode == 201) {
        final resData = restResponse.data;
        if (resData is Map<String, dynamic> && resData.containsKey('sessionToken')) {
          return VoltixLoginResult.fromJson(resData);
        }
      }
    } catch (e) {
      _logger.w('[VoltixApi] REST register fallback failed, attempting direct login: $e');
    }

    // Attempt direct login with newly created credentials
    return directLogin(
      username: username,
      password: password,
      deviceName: deviceName,
      deviceType: deviceType,
      macAddress: macAddress,
    );
  }

  // ───────────────────── loginByMac ──────────────────────

  /// Authenticates a device by its MAC / Device ID.
  /// Returns null if no account is assigned to this MAC.
  Future<VoltixLoginResult?> loginByMac({
    required String macAddress,
    String? deviceName,
    String? deviceType,
  }) async {
    final url = '$baseUrl/api/trpc/voltix.loginByMac';
    _logger.i('[VoltixApi] loginByMac: mac=$macAddress');

    try {
      final response = await _dio.post(url, data: {
        'json': {
          'macAddress': macAddress,
          'deviceName':? deviceName,
          'deviceType':? deviceType,
        },
      });

      final data = response.data;
      final result = (data is Map && data.containsKey('result'))
          ? data['result']
          : data;
      final resultData = (result is Map && result.containsKey('data'))
          ? result['data']
          : result;
      final json = (resultData is Map && resultData.containsKey('json'))
          ? resultData['json']
          : resultData;

      // Server returns null when no MAC match found
      if (json == null) return null;

      if (json is! Map) {
        throw VoltixApiException(
          'The server returned an unexpected login response '
          '(${json.runtimeType}). Expected a JSON object.',
        );
      }
      return VoltixLoginResult.fromJson(Map<String, dynamic>.from(json));
    } on DioException catch (e) {
      final msg = _extractTrpcError(e) ?? 'MAC login failed';
      _logger.e('[VoltixApi] loginByMac failed: $msg');
      return null; // Non-critical — fall back to normal login
    }
  }

  // ───────────────────── validateSession ──────────────────────

  /// Validates an existing session token without re-entering credentials.
  Future<VoltixSessionResult> validateSession(
    String sessionToken, {
    bool forceReplace = false,
  }) async {
    final url = '$baseUrl/api/trpc/voltix.validateSession';
    _logger.i('[VoltixApi] validateSession (forceReplace: $forceReplace)');

    try {
      final response = await _dio.get(url,
          queryParameters: {
            'input':
                '{"json":{"sessionToken":"$sessionToken","forceReplace":$forceReplace}}',
          },
          options: Options(headers: {
            'Authorization': 'Bearer $sessionToken',
          }));

      final data = response.data;
      final result = (data is Map && data.containsKey('result'))
          ? data['result']
          : data;
      final resultData = (result is Map && result.containsKey('data'))
          ? result['data']
          : result;
      final json = (resultData is Map && resultData.containsKey('json'))
          ? resultData['json']
          : resultData;

      return VoltixSessionResult.fromJson(json as Map<String, dynamic>);
    } on DioException catch (e) {
      final msg = _extractTrpcError(e) ?? 'Session validation failed';
      _logger.e('[VoltixApi] validateSession failed: $msg');
      throw VoltixApiException(msg);
    }
  }

  // ─────────────────────── connectServer ───────────────────────

  /// Switches the active Lumistream server for an existing session.
  Future<Map<String, dynamic>> connectServer({
    required int serverId,
    required String sessionToken,
  }) async {
    final url = '$baseUrl/api/trpc/voltix.connectServer';

    try {
      final response = await _dio.post(url,
          data: {
            'json': {'serverId': serverId},
          },
          options: Options(headers: {
            'Authorization': 'Bearer $sessionToken',
            'Cookie': 'voltix_session=$sessionToken',
          }));

      final data = response.data;
      final result = (data is Map && data.containsKey('result'))
          ? data['result']
          : data;
      final resultData = (result is Map && result.containsKey('data'))
          ? result['data']
          : result;
      final json = (resultData is Map && resultData.containsKey('json'))
          ? resultData['json']
          : resultData;
      return json as Map<String, dynamic>;
    } on DioException catch (e) {
      final msg = _extractTrpcError(e) ?? 'Server connection failed';
      throw VoltixApiException(msg);
    }
  }

  // ───────────────────────── ping ─────────────────────────

  Future<Map<String, dynamic>> ping(String sessionToken) async {
    final url = '$baseUrl/api/trpc/voltix.ping';

    try {
      final response = await _dio.post(url,
          data: {'json': {}},
          options: Options(headers: {
            'Authorization': 'Bearer $sessionToken',
            'Cookie': 'voltix_session=$sessionToken',
          }));

      final data = response.data;
      final result = (data is Map && data.containsKey('result'))
          ? data['result']
          : data;
      final resultData = (result is Map && result.containsKey('data'))
          ? result['data']
          : result;
      final json = (resultData is Map && resultData.containsKey('json'))
          ? resultData['json']
          : resultData;
      return json as Map<String, dynamic>;
    } on DioException catch (e) {
      final msg = _extractTrpcError(e) ?? 'Ping failed';
      throw VoltixApiException(msg);
    }
  }

  // ───────────────────────── logout ─────────────────────────

  Future<void> logout(String sessionToken) async {
    final url = '$baseUrl/api/trpc/voltix.logout';

    try {
      await _dio.post(url,
          data: {'json': {}},
          options: Options(headers: {
            'Authorization': 'Bearer $sessionToken',
            'Cookie': 'voltix_session=$sessionToken',
          }));
    } catch (e) {
      _logger.w('[VoltixApi] logout error (non-critical): $e');
    }
  }

  // ────────────────────── User Settings Sync ──────────────────────

  Future<bool> saveUserSettings({
    required String sessionToken,
    required String username,
    required Map<String, dynamic> settingsData,
  }) async {
    final url = '$baseUrl/api/trpc/voltix.saveUserSettings';
    _logger.i('[VoltixApi] saveUserSettings: username=$username');

    try {
      final response = await _dio.post(
        url,
        data: {
          'json': {
            'username': username,
            'settings': jsonEncode(settingsData),
            'updatedAt': DateTime.now().toUtc().toIso8601String(),
          },
        },
        options: Options(headers: {
          'Authorization': 'Bearer $sessionToken',
          'Cookie': 'voltix_session=$sessionToken',
        }),
      );
      return response.statusCode != null && response.statusCode! >= 200 && response.statusCode! < 300;
    } on DioException catch (e) {
      _logger.w('[VoltixApi] tRPC saveUserSettings failed (${e.response?.statusCode}), falling back to restPost: $e');
      try {
        await restPost(
          '/api/voltix/user-settings',
          body: {
            'username': username,
            'settings': jsonEncode(settingsData),
            'updatedAt': DateTime.now().toUtc().toIso8601String(),
          },
          sessionToken: sessionToken,
        );
        _logger.i('[VoltixApi] restPost /api/voltix/user-settings succeeded');
        return true;
      } catch (err) {
        _logger.e('[VoltixApi] saveUserSettings failed across all endpoints: $err');
        return false;
      }
    }
  }

  /// Resolves Jellyfin/Lumistream usernames to Voltix display names.
  ///
  /// Returns a map keyed by **lowercased** Jellyfin username. Names the backend
  /// could not match are absent from the result rather than echoed back, so the
  /// caller can tell "unknown" apart from "same as input".
  Future<Map<String, String>> resolveSyncPlayUsernames({
    required List<String> jellyfinUsernames,
    String? sessionToken,
  }) async {
    if (jellyfinUsernames.isEmpty) return const {};
    final payload = jsonEncode({
      'json': {'jellyfinUsernames': jellyfinUsernames},
    });
    final url =
        '$baseUrl/api/trpc/voltix.resolveSyncPlayUsernames?input=${Uri.encodeComponent(payload)}';

    try {
      final response = await _dio.get(
        url,
        options: Options(headers: {
          if (sessionToken != null) 'Authorization': 'Bearer $sessionToken',
          if (sessionToken != null) 'Cookie': 'voltix_session=$sessionToken',
        }),
      );
      final data = response.data;
      final result =
          (data is Map && data.containsKey('result')) ? data['result'] : data;
      final resultData = (result is Map && result.containsKey('data'))
          ? result['data']
          : result;
      final json = (resultData is Map && resultData.containsKey('json'))
          ? resultData['json']
          : resultData;
      final mapping = (json is Map) ? json['mapping'] : null;
      if (mapping is Map) {
        return mapping.map(
          (key, value) => MapEntry(key.toString(), value.toString()),
        );
      }
      return const {};
    } on DioException catch (e) {
      _logger.w(
        '[VoltixApi] resolveSyncPlayUsernames failed (${e.response?.statusCode})',
      );
      return const {};
    }
  }

  Future<Map<String, dynamic>?> getUserSettings({
    required String sessionToken,
    required String username,
  }) async {
    final url = '$baseUrl/api/trpc/voltix.getUserSettings?input=${Uri.encodeComponent(jsonEncode({'json': {'username': username}}))}';
    _logger.i('[VoltixApi] getUserSettings: username=$username');

    try {
      final response = await _dio.get(
        url,
        options: Options(headers: {
          'Authorization': 'Bearer $sessionToken',
          'Cookie': 'voltix_session=$sessionToken',
        }),
      );
      final data = response.data;
      final result = (data is Map && data.containsKey('result')) ? data['result'] : data;
      final resultData = (result is Map && result.containsKey('data')) ? result['data'] : result;
      final json = (resultData is Map && resultData.containsKey('json')) ? resultData['json'] : resultData;
      if (json is Map) {
        if (json['settings'] is String) {
          return jsonDecode(json['settings'] as String) as Map<String, dynamic>;
        } else if (json['settings'] is Map) {
          return json['settings'] as Map<String, dynamic>;
        }
      }
      return null;
    } on DioException catch (e) {
      _logger.w('[VoltixApi] tRPC getUserSettings fallback to restGet: $e');
      try {
        final res = await restGet(
          '/api/voltix/user-settings',
          query: {'username': username},
          sessionToken: sessionToken,
        );
        if (res is Map) {
          if (res['settings'] is String) {
            return jsonDecode(res['settings'] as String) as Map<String, dynamic>;
          } else if (res['settings'] is Map) {
            return res['settings'] as Map<String, dynamic>;
          }
        }
      } catch (_) {}
      return null;
    }
  }

  // ───────────────────── getIptvHomeData ─────────────────────

  Future<Map<String, dynamic>> getIptvHomeData(String sessionToken) async {
    final url = '$baseUrl/api/iptv/home-data';
    try {
      final response = await _dio.get(url,
          options: Options(headers: {
            'Authorization': 'Bearer $sessionToken',
          }));
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      final msg = e.message ?? 'Failed to get IPTV home data';
      throw VoltixApiException(msg);
    }
  }

  // ───────────────── Generic authenticated REST helpers ─────────────────
  // Used by VoltixIptvRepository so that all IPTV traffic flows through the
  // same Dio instance (and therefore the same 401-only logout interceptor).

  Future<dynamic> restGet(
    String path, {
    Map<String, dynamic>? query,
    required String sessionToken,
    CancelToken? cancelToken,
    Duration? timeout,
  }) async {
    final response = await _dio.get(
      '$baseUrl$path',
      queryParameters: query,
      cancelToken: cancelToken,
      options: Options(
        headers: {'Authorization': 'Bearer $sessionToken'},
        receiveTimeout: timeout,
        sendTimeout: timeout,
      ),
    );
    return response.data;
  }

  Future<dynamic> restPost(
    String path, {
    Object? body,
    required String sessionToken,
  }) async {
    final response = await _dio.post(
      '$baseUrl$path',
      data: body,
      options: Options(headers: {'Authorization': 'Bearer $sessionToken'}),
    );
    return response.data;
  }

  Future<dynamic> restDelete(
    String path, {
    Object? body,
    required String sessionToken,
  }) async {
    final response = await _dio.delete(
      '$baseUrl$path',
      data: body,
      options: Options(headers: {'Authorization': 'Bearer $sessionToken'}),
    );
    return response.data;
  }

  // ───────────────────── Error extraction ─────────────────────

  String? _extractTrpcError(DioException e) {
    final data = e.response?.data;
    if (data is Map) {
      // tRPC wraps errors in [{error:{json:{message:...}}}]
      if (data['error'] is Map) {
        final errorJson = data['error'];
        if (errorJson['json'] is Map) {
          return errorJson['json']['message'] as String?;
        }
        return errorJson['message'] as String?;
      }
      // Or sometimes in data.error directly
      if (data['message'] is String) {
        return data['message'] as String;
      }
    }
    // tRPC batch response is a list
    if (data is List && data.isNotEmpty) {
      final first = data[0];
      if (first is Map && first['error'] is Map) {
        final errJson = first['error'];
        if (errJson['json'] is Map) {
          return errJson['json']['message'] as String?;
        }
        return errJson['message'] as String?;
      }
    }
    return e.message;
  }

  void dispose() {
    _dio.close();
  }
}

// ─────────────────────── Data Models ───────────────────────

class VoltixApiException implements Exception {
  final String message;
  VoltixApiException(this.message);
  @override
  String toString() => 'VoltixApiException: $message';
}

class VoltixLoginResult {
  final String sessionToken;
  final VoltixUser user;
  final VoltixServer activeServer;
  final List<VoltixServer> servers;
  final bool jellyfinReady;
  final bool iptvReady;

  VoltixLoginResult({
    required this.sessionToken,
    required this.user,
    required this.activeServer,
    required this.servers,
    required this.jellyfinReady,
    required this.iptvReady,
  });

  /// Parses a `voltix.directLogin` payload.
  ///
  /// Every field used to be read with a hard cast (`as String`,
  /// `as Map<String, dynamic>`, `as List`). A null or reshaped field therefore
  /// raised a `TypeError`, which is not a [DioException] and so escaped
  /// [VoltixApiService.directLogin] uncaught, landing in the login screen's
  /// catch-all and reporting itself to the user as "Connection failed. Please
  /// check your internet." — sending them to debug a network that was working.
  ///
  /// Now a malformed payload raises a [VoltixApiException] naming what was
  /// missing, which the login screen already surfaces verbatim.
  /// [VoltixSessionResult.fromJson] below has always been null-tolerant; this
  /// brings login into line with it.
  factory VoltixLoginResult.fromJson(Map<String, dynamic> json) {
    String describe() => json.keys.isEmpty
        ? 'the response body was empty'
        : 'fields present: ${json.keys.join(', ')}';

    final sessionToken = json['sessionToken'];
    if (sessionToken is! String || sessionToken.isEmpty) {
      throw VoltixApiException(
        'The server did not return a session token (${describe()}).',
      );
    }

    final user = json['user'];
    if (user is! Map) {
      throw VoltixApiException(
        'The server did not return account details (${describe()}).',
      );
    }

    final activeServer = json['activeServer'];
    if (activeServer is! Map) {
      throw VoltixApiException(
        'No server is assigned to this account yet (${describe()}). '
        'Assign one in the Voltix admin panel, then sign in again.',
      );
    }

    final servers = json['servers'];

    return VoltixLoginResult(
      sessionToken: sessionToken,
      user: VoltixUser.fromJson(Map<String, dynamic>.from(user)),
      activeServer: VoltixServer.fromJson(
        Map<String, dynamic>.from(activeServer),
      ),
      servers: servers is List
          ? servers
                .whereType<Map>()
                .map((s) => VoltixServer.fromJson(Map<String, dynamic>.from(s)))
                .toList()
          : <VoltixServer>[],
      jellyfinReady: json['jellyfinReady'] as bool? ?? false,
      iptvReady: json['iptvReady'] as bool? ?? false,
    );
  }
}

class VoltixSessionResult {
  final VoltixUser user;
  final VoltixServer? activeServer;
  final List<VoltixServer> servers;
  final bool jellyfinReady;
  final bool iptvReady;

  VoltixSessionResult({
    required this.user,
    this.activeServer,
    required this.servers,
    required this.jellyfinReady,
    required this.iptvReady,
  });

  factory VoltixSessionResult.fromJson(Map<String, dynamic> json) {
    return VoltixSessionResult(
      user: VoltixUser.fromJson(json['user'] as Map<String, dynamic>),
      activeServer: json['activeServer'] != null
          ? VoltixServer.fromJson(json['activeServer'] as Map<String, dynamic>)
          : null,
      servers: (json['servers'] as List?)
              ?.map((s) => VoltixServer.fromJson(s as Map<String, dynamic>))
              .toList() ??
          [],
      jellyfinReady: json['jellyfinReady'] as bool? ?? false,
      iptvReady: json['iptvReady'] as bool? ?? false,
    );
  }
}

class VoltixUser {
  final int id;
  final String username;
  final String? displayName;
  final String? email;
  final bool isActive;
  final int maxConcurrentDevices;
  final bool isAdmin;

  VoltixUser({
    required this.id,
    required this.username,
    this.displayName,
    this.email,
    required this.isActive,
    required this.maxConcurrentDevices,
    this.isAdmin = false,
  });

  factory VoltixUser.fromJson(Map<String, dynamic> json) {
    // Admin is recognised from either an explicit `isAdmin` bool or a
    // `role`/`serverRole` string of "admin"/"voltixadmin" (case-insensitive).
    final role = (json['role'] ?? json['serverRole'])?.toString().toLowerCase();
    return VoltixUser(
      id: json['id'] as int,
      username: json['username'] as String,
      displayName: json['displayName'] as String?,
      email: json['email'] as String?,
      isActive: json['isActive'] as bool? ?? true,
      maxConcurrentDevices: json['maxConcurrentDevices'] as int? ?? 1,
      isAdmin: json['isAdmin'] == true ||
          role == 'admin' ||
          role == 'voltixadmin',
    );
  }
}

/// Picks the server a user should land on by default: **Voltix Primary**
/// (a.k.a. Main) whenever it's assigned, rather than the shared Extra or 4K
/// servers. Falls back to [fallback], then the first assigned server.
VoltixServer? preferPrimaryServer(
  List<VoltixServer> servers, {
  VoltixServer? fallback,
}) {
  if (servers.isEmpty) return fallback;
  for (final server in servers) {
    final name = server.name.toLowerCase();
    if (name.contains('primary') || name.contains('main')) return server;
  }
  // Server id 1 is Primary in the Voltix deployment.
  for (final server in servers) {
    if (server.id == 1) return server;
  }
  return fallback ?? servers.first;
}

class VoltixServer {
  final int id;
  final String name;
  final String proxyUrl;

  VoltixServer({
    required this.id,
    required this.name,
    required this.proxyUrl,
  });

  factory VoltixServer.fromJson(Map<String, dynamic> json) {
    return VoltixServer(
      id: json['id'] as int,
      name: json['name'] as String,
      proxyUrl: json['proxyUrl'] as String,
    );
  }

  /// Returns the fully-qualified proxy URL (absolute).
  String absoluteProxyUrl(String baseUrl) {
    if (proxyUrl.startsWith('http')) return proxyUrl;
    final base = baseUrl.replaceAll(RegExp(r'/+$'), '');
    return '$base$proxyUrl';
  }
}
