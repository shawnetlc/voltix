import 'dart:ffi';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/open.dart';

import '../../util/platform_detection.dart';

QueryExecutor openConnection() {
  return LazyDatabase(() async {
    final docs = PlatformDetection.isAppleTV
        ? await getApplicationCacheDirectory()
        : await getApplicationDocumentsDirectory();
    final dbDir = Directory('${docs.path}/Voltix/DB');
    if (!dbDir.existsSync()) {
      await dbDir.create(recursive: true);
    }
    final file = File('${dbDir.path}/offline.db');

    if (PlatformDetection.isTizen || PlatformDetection.isAppleTV) {
      open.overrideForAll(
        PlatformDetection.isAppleTV ? _openAppleSqlite : _openTizenSqlite,
      );
      return NativeDatabase(file);
    }

    return NativeDatabase.createInBackground(file);
  });
}

DynamicLibrary _openTizenSqlite() {
  for (final name in const ['libsqlite3.so.0', 'libsqlite3.so']) {
    try {
      return DynamicLibrary.open(name);
    } catch (_) {
      // Try the next candidate name.
    }
  }
  // Last resort: symbols may be statically available in the process.
  return DynamicLibrary.process();
}

DynamicLibrary _openAppleSqlite() {
  for (final name in const ['libsqlite3.dylib', 'libsqlite3.0.dylib']) {
    try {
      return DynamicLibrary.open(name);
    } catch (_) {}
  }
  return DynamicLibrary.process();
}
