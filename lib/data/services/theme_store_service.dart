import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:voltix_design/voltix_design.dart';

import 'storage_path_service.dart';

/// Thrown when a store theme reuses a built-in id. Distinct from a network or
/// parse failure so the UI can explain which of the three actually happened.
class ThemeStoreReservedIdException implements Exception {
  const ThemeStoreReservedIdException(this.id);

  final String id;

  @override
  String toString() =>
      'Theme id "$id" is reserved by a built-in theme and cannot be saved.';
}

class ThemeStoreCatalogEntry {
  final String id;
  final String displayName;
  final String? description;
  final String file;

  const ThemeStoreCatalogEntry({
    required this.id,
    required this.displayName,
    this.description,
    required this.file,
  });
}

/// Fetches the community theme catalog from the Moonfin Themes repo and
/// persists store-saved themes in a dedicated directory, isolated from the
/// server-theme cache (which plugin sync rewrites). Saved themes are kept in
/// [ThemeRegistry]'s store bucket so server syncs never clear them.
class ThemeStoreService {
  ThemeStoreService(this._storagePaths);

  final StoragePathService _storagePaths;

  static const String _baseUrl =
      'https://raw.githubusercontent.com/Moonfin-Client/Themes/main/';

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
      responseType: ResponseType.plain,
    ),
  );

  /// Catalog entries hidden from the Theme Store.
  ///
  /// The catalog is fetched from a third-party repo we do not control, and
  /// "pruplemax" (Purple Max) points at themes/pruplemax.theme.json - a file
  /// that has never been published and returns 404. Every attempt to save it
  /// therefore fails, so it is filtered out rather than shown as a broken
  /// entry. Remove the id here if the file is ever published upstream.
  static const Set<String> hiddenCatalogIds = {'pruplemax'};

  Future<List<ThemeStoreCatalogEntry>> fetchCatalog() async {
    final response = await _dio.get<String>('${_baseUrl}index.json');
    final decoded = jsonDecode(response.data ?? '{}');
    final themes = decoded is Map ? decoded['themes'] : null;
    if (themes is! List) return const [];
    return themes
        .whereType<Map>()
        .map(
          (entry) => ThemeStoreCatalogEntry(
            id: entry['id']?.toString() ?? '',
            displayName:
                entry['displayName']?.toString() ?? entry['id']?.toString() ?? '',
            description: entry['description']?.toString(),
            file: entry['file']?.toString() ?? '',
          ),
        )
        .where((e) => e.id.isNotEmpty && e.file.isNotEmpty)
        .where((e) => !hiddenCatalogIds.contains(e.id))
        .toList();
  }

  /// Fetches and validates a theme. Throws [ThemeSpecParseException] on a
  /// malformed theme.
  Future<ThemeSpec> fetchThemeSpec(String file) async {
    final response = await _dio.get<String>('$_baseUrl$file');
    final decoded = jsonDecode(response.data ?? '');
    return ThemeSpec.fromJson(Map<String, dynamic>.from(decoded as Map));
  }

  Future<Directory> _storeDir() async {
    final root = await _storagePaths.getThemeCacheDir();
    final dir = Directory('${root.path}/_store');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// The directory store-saved themes live in. Saved Themes reads this in
  /// addition to the server-scoped cache.
  Future<Directory> storeDirectory() => _storeDir();

  String _fileStem(String id) =>
      id.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]+'), '_');

  /// Themes shipped inside the app bundle.
  ///
  /// voltix_classic is our own reference palette. The rest are snapshots of the
  /// Moonfin community catalog, bundled deliberately: the Theme Store fetches
  /// them from a third-party GitHub repo at runtime, so without a local copy an
  /// upstream rename, deletion or outage loses them. (That repo already lists a
  /// "Purple Max" entry whose file 404s.) Bundled copies are seeded once and
  /// then owned by the user like any other saved theme.
  static const List<String> bundledThemeAssets = [
    'assets/themes/voltix.theme.json',
    'assets/themes/voltix_classic.theme.json',
    'assets/themes/cyberpunk_neon.theme.json',
    'assets/themes/emerald_luxury.theme.json',
    'assets/themes/solar_flare.theme.json',
    'assets/themes/amethyst_dream.theme.json',
    'assets/themes/crimson_noir.theme.json',
    'assets/themes/arctic_aurora.theme.json',
    'assets/themes/sunset_boulevard.theme.json',
    'assets/themes/studio_oled.theme.json',
    'assets/themes/tokyo_drift.theme.json',
    'assets/themes/dracula_prime.theme.json',
    'assets/themes/bluesneyplus.theme.json',
    'assets/themes/greenlu.theme.json',
    'assets/themes/midnight.theme.json',
    'assets/themes/redflix.theme.json',
  ];

  /// Copies the bundled reference themes into the store directory on first run
  /// so Saved Themes is populated out of the box.
  Future<void> seedBundledThemes() async {
    try {
      final dir = await _storeDir();
      // v3: v2 was written by builds where 11 of the 16 bundled themes failed
      // to parse (semantic.mediaTypeBadgeSeries vs mediaTypeBadgeShow). Anyone
      // who launched one of those holds a v2 marker and would never see them,
      // so the fix needs a new marker to re-seed.
      final marker = File('${dir.path}/.seeded_v3');
      if (await marker.exists()) return;

      for (final asset in bundledThemeAssets) {
        try {
          final raw = await rootBundle.loadString(asset);
          final decoded = jsonDecode(raw);
          if (decoded is! Map) continue;
          final spec = ThemeSpec.fromJson(Map<String, dynamic>.from(decoded));
          if (ThemeRegistry.builtInIds.contains(spec.id)) continue;
          final file = File('${dir.path}/${_fileStem(spec.id)}.json');
          if (!await file.exists()) {
            await file.writeAsString(raw);
          }
          ThemeRegistry.registerStoreTheme(spec);
        } catch (e) {
          // One bad asset must not stop the rest from seeding -- but it must
          // not be silent either. A swallowed ThemeSpecParseException here is
          // exactly how 11 bundled themes went missing without a trace.
          debugPrint('Bundled theme "$asset" failed to seed: $e');
        }
      }
      await marker.writeAsString('1');
    } catch (_) {}
  }

  /// Loads persisted store themes from disk and registers them. Call once at
  /// startup, before the active theme is resolved.
  Future<void> loadAndRegister() async {
    try {
      final dir = await _storeDir();
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.json'));
      for (final file in files) {
        try {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is! Map) continue;
          final spec = ThemeSpec.fromJson(Map<String, dynamic>.from(decoded));
          if (ThemeRegistry.builtInIds.contains(spec.id)) continue;
          ThemeRegistry.registerStoreTheme(spec);
        } catch (e) {
          debugPrint('Saved theme "${file.path}" failed to load: $e');
        }
      }
    } catch (_) {}
  }

  Future<void> saveStoreTheme(ThemeSpec spec) async {
    // Checked BEFORE writing. registerStoreTheme throws on a reserved id, and
    // the previous order wrote the file first - leaving an orphan that
    // loadAndRegister then skipped on every launch.
    if (ThemeRegistry.builtInIds.contains(spec.id)) {
      throw ThemeStoreReservedIdException(spec.id);
    }
    final dir = await _storeDir();
    final file = File('${dir.path}/${_fileStem(spec.id)}.json');
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(spec.toJson()),
    );
    ThemeRegistry.registerStoreTheme(spec);
  }

  Future<void> deleteStoreTheme(String id) async {
    final dir = await _storeDir();
    final file = File('${dir.path}/${_fileStem(id)}.json');
    if (await file.exists()) {
      await file.delete();
    }
    ThemeRegistry.removeStoreTheme(id);
  }

  Set<String> savedStoreThemeIds() =>
      ThemeRegistry.storeThemes.map((s) => s.id).toSet();
}
