import 'package:get_it/get_it.dart';
import 'package:server_core/server_core.dart';

import 'voltix_watch_registry_service.dart';

/// What the viewer has watched recently, newest first, from the Voltix watch
/// registry (the app's own record of every play, kept on the device and in
/// Azure).
///
/// The home rows "Since you watched", "More with <actor>" and the taste
/// profile's "Because you watched" used to ask the media server instead
/// (IsPlayed, sorted by DatePlayed). On supersilo that comes back empty or
/// unreliable - and it only counts titles watched to the END, so nothing
/// appeared while a film or series was still being watched. The registry
/// knows both.
class RecentlyWatchedSource {
  RecentlyWatchedSource._();

  /// A title counts once it has been watched for 5 minutes or 10 %.
  static const _minTicks = 5 * 60 * 10000000;

  /// Item ids, newest first. Episodes become their series (one entry per
  /// show). [movies] / [series] choose the kinds.
  static List<String> recentIds({
    int limit = 30,
    bool movies = true,
    bool series = true,
  }) {
    if (!GetIt.instance.isRegistered<VoltixWatchRegistryService>()) return const [];
    final entries = GetIt.instance<VoltixWatchRegistryService>()
        .allEntries
        .where((e) =>
            e.isPlayed ||
            e.playCount > 0 ||
            e.playbackPositionTicks >= _minTicks ||
            e.progressPercent >= 10)
        .toList()
      ..sort((a, b) => b.lastWatchedAt.compareTo(a.lastWatchedAt));
    final ids = <String>[];
    final seen = <String>{};
    for (final e in entries) {
      final type = e.type.toLowerCase();
      String? id;
      if (type == 'movie' && movies) {
        id = e.itemId;
      } else if ((type == 'episode' || type == 'series') && series) {
        id = (e.seriesId != null && e.seriesId!.isNotEmpty) ? e.seriesId : (type == 'series' ? e.itemId : null);
      }
      if (id == null || id.isEmpty || !seen.add(id)) continue;
      ids.add(id);
      if (ids.length >= limit) break;
    }
    return ids;
  }

  /// Those titles as server items (Movies and Series, with [fields]), newest
  /// first. Titles the current server doesn't have (e.g. watched on another
  /// server) are simply left out.
  static Future<List<Map<String, dynamic>>> fetch(
    MediaServerClient client, {
    required String fields,
    int limit = 30,
    bool movies = true,
    bool series = true,
  }) async {
    final ids = recentIds(limit: limit, movies: movies, series: series);
    if (ids.isEmpty) return const [];
    try {
      final res = await client.itemsApi
          .getItems(ids: ids, fields: fields, enableTotalRecordCount: false)
          .timeout(const Duration(seconds: 20));
      final byId = <String, Map<String, dynamic>>{
        for (final r in (res['Items'] as List? ?? const []).whereType<Map<String, dynamic>>())
          if (r['Id'] != null) r['Id'].toString(): r,
      };
      return [for (final id in ids) if (byId[id] != null) byId[id]!];
    } catch (_) {
      return const [];
    }
  }
}
