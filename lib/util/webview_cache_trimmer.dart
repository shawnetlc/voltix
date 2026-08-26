import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Trims the WebView disk cache on app startup to prevent unbounded growth.
///
/// This mirrors the native Android `VoltixApplication.trimWebViewCache()`:
///   - Removes cache files older than [maxAgeMs] (3 days)
///   - If total cache exceeds [maxCacheBytes] (50 MB), LRU-deletes oldest files
///
/// Runs on a background isolate to avoid blocking the UI thread.
class WebViewCacheTrimmer {
  static const int _maxCacheBytes = 50 * 1024 * 1024; // 50 MB
  static const int _maxAgeMs = 3 * 24 * 60 * 60 * 1000; // 3 days

  /// Trims the WebView cache. Safe to call on any platform — no-ops on non-Android.
  static Future<void> trim() async {
    // Only relevant on Android where WebView stores disk cache
    if (!Platform.isAndroid) return;

    try {
      await compute(_trimInBackground, await _getCachePaths());
    } catch (e) {
      debugPrint('[VoltixCache] Cache trim failed: $e');
    }
  }

  static Future<List<String>> _getCachePaths() async {
    final paths = <String>[];
    try {
      final cacheDir = await getTemporaryDirectory();
      paths.add(cacheDir.path);
    } catch (_) {}
    try {
      final appDir = await getApplicationSupportDirectory();
      // Android WebView stores cache under app_webview/Cache
      final webViewCache = Directory('${appDir.parent.path}/app_webview/Cache');
      if (await webViewCache.exists()) {
        paths.add(webViewCache.path);
      }
    } catch (_) {}
    return paths;
  }

  /// Runs in a background isolate to avoid jank.
  static void _trimInBackground(List<String> cachePaths) {
    final now = DateTime.now().millisecondsSinceEpoch;
    var totalRemoved = 0;

    // Phase 1: Remove files older than maxAge from each cache directory
    final survivingFiles = <_CacheFile>[];
    for (final path in cachePaths) {
      final dir = Directory(path);
      if (!dir.existsSync()) continue;

      try {
        for (final entity in dir.listSync(recursive: true)) {
          if (entity is! File) continue;
          try {
            final stat = entity.statSync();
            final ageMs = now - stat.modified.millisecondsSinceEpoch;
            if (ageMs > _maxAgeMs) {
              entity.deleteSync();
              totalRemoved++;
            } else {
              survivingFiles.add(_CacheFile(
                path: entity.path,
                size: stat.size,
                modified: stat.modified.millisecondsSinceEpoch,
              ));
            }
          } catch (_) {
            // Skip files we can't stat or delete
          }
        }
      } catch (_) {
        // Skip directories we can't list
      }
    }

    // Phase 2: If total size exceeds max, LRU-delete oldest files
    var totalSize = survivingFiles.fold<int>(0, (sum, f) => sum + f.size);
    if (totalSize > _maxCacheBytes) {
      // Sort oldest first for LRU eviction
      survivingFiles.sort((a, b) => a.modified.compareTo(b.modified));
      for (final file in survivingFiles) {
        if (totalSize <= _maxCacheBytes) break;
        try {
          File(file.path).deleteSync();
          totalSize -= file.size;
          totalRemoved++;
        } catch (_) {}
      }
    }

    if (totalRemoved > 0) {
      // Can't use debugPrint in isolate, but this is fine for release builds
      // ignore: avoid_print
      print('[VoltixCache] Trimmed $totalRemoved cache files on startup');
    }
  }
}

class _CacheFile {
  final String path;
  final int size;
  final int modified;

  _CacheFile({required this.path, required this.size, required this.modified});
}
