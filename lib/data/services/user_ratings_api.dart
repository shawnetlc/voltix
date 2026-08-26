import 'package:dio/dio.dart';
import 'package:server_core/server_core.dart';

/// Everything the user has rated, item id to score out of 10, from the
/// Moonfin server plugin. Null when the endpoint is unreachable or the plugin
/// is not installed, which callers treat as the sort being unavailable.
///
/// Deliberately hardcoded to the `Moonfin` route rather than resolved through
/// [PluginSyncService.pluginPrefix] like other plugin calls: this is a
/// server-side plugin endpoint, not a client-side brand string, and it must
/// match whatever route name the plugin is actually registered under on the
/// server. Only flip this to `Voltix` once the server plugin itself exposes
/// `/Voltix/UserRatings/Mine`.
Future<Map<String, double>?> fetchMyUserRatings(MediaServerClient client) async {
  final token = client.accessToken;
  if (token == null || token.isEmpty) return null;

  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      headers: {
        'Authorization': buildServerAuthorizationHeader(
          scheme: 'MediaBrowser',
          deviceInfo: client.deviceInfo,
          accessToken: token,
        ),
        'Accept': 'application/json',
      },
    ),
  );
  configureServerDio(dio);

  try {
    final response = await dio.get<Map<String, dynamic>>(
      '${client.baseUrl}/Moonfin/UserRatings/Mine',
    );
    final items = response.data?['Items'];
    if (items is! List) return null;

    final ratings = <String, double>{};
    for (final entry in items) {
      if (entry is! Map) continue;
      final id = entry['ItemId']?.toString();
      final rating = entry['Rating'];
      if (id == null || id.isEmpty || rating is! num) continue;
      ratings[id] = rating.toDouble();
    }
    return ratings;
  } catch (_) {
    return null;
  } finally {
    dio.close();
  }
}
