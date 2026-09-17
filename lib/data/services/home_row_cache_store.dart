import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../util/platform_detection.dart';
import '../models/aggregated_item.dart';
import '../models/home_row.dart';

/// Persists the home rows to a single JSON file so a cold start can paint
/// cached content immediately, then revalidate in the background.
///
/// Single-slot: only the last-written (server + section config) signature is
/// kept, so switching servers or changing the home layout invalidates it on the
/// next read. All operations are best-effort and never throw to the caller.
class HomeRowCacheStore {
  static const _fileName = 'home_rows_cache.json';

  /// How old a cache may be and still be worth painting.
  ///
  /// This was six hours, which meant it almost never hit. Someone watches in
  /// the evening and comes back the next evening — twenty-four hours later the
  /// cache is thrown away and they are back to a spinner and a cold network
  /// round trip. Every single time. Which is exactly what people reported: fast
  /// once, slow ever after.
  ///
  /// Seven days is not a claim that week-old rows are accurate. The cache is
  /// only ever the FIRST PAINT — HomeViewModel.load() refetches everything
  /// immediately afterwards and swaps the real rows in a moment later — so all
  /// a long expiry changes is whether that second or two is spent looking at
  /// last night's home screen or at nothing at all. Stale rows replaced in
  /// place beat an empty screen.
  ///
  /// The cache is dropped outright whenever the server, user, section layout or
  /// parental filter changes (see the key check in [read]), so "stale" here only
  /// ever means "the same shelves, possibly a second behind on new titles".
  static const _maxAge = Duration(days: 7);

  /// When the cached copy was written, or null if there is none to read.
  ///
  /// Drives the once-a-day full resync in [HomeViewModel]: the timestamp is
  /// already in the file, so scheduling needs no second piece of bookkeeping
  /// that could disagree with it.
  Future<DateTime?> savedAt() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final saved = decoded['savedAt'];
      if (saved is! int) return null;
      return DateTime.fromMillisecondsSinceEpoch(saved);
    } catch (_) {
      return null;
    }
  }

  Future<File> _file() async {
    final dir = PlatformDetection.isAppleTV
        ? await getApplicationCacheDirectory()
        : await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  /// Returns the cached rows for [cacheKey], or null on any miss (no file,
  /// signature mismatch, too old, corrupt, or empty).
  Future<List<HomeRow>?> read(String cacheKey) async {
    try {
      final file = await _file();
      if (!file.existsSync()) {
        debugPrint('⚡🏠 [HomeCache] No cache file found');
        return null;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['key'] != cacheKey) {
        debugPrint('⚡🏠 [HomeCache] Key mismatch — invalidating');
        return null;
      }
      final savedAt = decoded['savedAt'];
      if (savedAt is int) {
        final age = DateTime.now().millisecondsSinceEpoch - savedAt;
        if (age < 0 || age > _maxAge.inMilliseconds) {
          debugPrint('⚡🏠 [HomeCache] Expired (age=${(age / 1000 / 60).toStringAsFixed(0)}m)');
          return null;
        }
      }
      final rawRows = decoded['rows'];
      if (rawRows is! List) return null;
      final rows = <HomeRow>[];
      for (final raw in rawRows) {
        if (raw is! Map) continue;
        final row = _rowFromJson(raw.cast<String, dynamic>());
        if (row != null) rows.add(row);
      }
      if (rows.isEmpty) {
        debugPrint('⚡🏠 [HomeCache] Empty after deserialization');
        return null;
      }
      debugPrint('⚡🏠 [HomeCache] HIT — ${rows.length} rows restored');
      return rows;
    } catch (e) {
      debugPrint('⚡🏠 [HomeCache] Read error: $e');
      return null;
    }
  }

  /// Persists the populated, non-placeholder rows under [cacheKey].
  Future<void> write(String cacheKey, List<HomeRow> rows) async {
    try {
      final serializable = rows
          .where((r) => !r.isLoading && r.items.isNotEmpty)
          .map(_rowToJson)
          .toList(growable: false);
      if (serializable.isEmpty) {
        debugPrint('⚡🏠 [HomeCache] Skip write — no non-empty rows');
        return;
      }
      final payload = jsonEncode({
        'key': cacheKey,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'rows': serializable,
      });
      final file = await _file();
      await file.writeAsString(payload, flush: true);
      debugPrint('⚡🏠 [HomeCache] Wrote ${serializable.length} rows (${(payload.length / 1024).toStringAsFixed(1)} KB)');
    } catch (e) {
      debugPrint('⚡🏠 [HomeCache] Write error: $e');
    }
  }

  Map<String, dynamic> _rowToJson(HomeRow row) => {
    'id': row.id,
    'title': row.title,
    'rowType': row.rowType.name,
    'totalCount': row.totalCount,
    'items': row.items
        .map((i) => {'id': i.id, 'serverId': i.serverId, 'rawData': i.rawData})
        .toList(growable: false),
  };

  HomeRow? _rowFromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString();
    final title = json['title'] as String?;
    final rowTypeName = json['rowType'] as String?;
    if (id == null || title == null || rowTypeName == null) return null;

    HomeRowType? rowType;
    for (final t in HomeRowType.values) {
      if (t.name == rowTypeName) {
        rowType = t;
        break;
      }
    }
    if (rowType == null) return null;

    final items = <AggregatedItem>[];
    final rawItems = json['items'];
    if (rawItems is List) {
      for (final raw in rawItems) {
        if (raw is! Map) continue;
        final m = raw.cast<String, dynamic>();
        final itemId = m['id']?.toString();
        final serverId = m['serverId']?.toString();
        final rawData = m['rawData'];
        if (itemId == null || serverId == null || rawData is! Map) continue;
        items.add(
          AggregatedItem(
            id: itemId,
            serverId: serverId,
            rawData: rawData.cast<String, dynamic>(),
          ),
        );
      }
    }

    return HomeRow(
      id: id,
      title: title,
      items: items,
      rowType: rowType,
      totalCount: (json['totalCount'] as num?)?.toInt() ?? items.length,
      isLoading: false,
    );
  }
}
