import 'package:server_core/server_core.dart';

/// Genre filtering that works on servers that ignore the `Genres` name filter.
///
/// supersilo answered `Genres=Thriller` with titles from every genre (a
/// documentary, comedies, UFC...). So genre queries here also send the genre's
/// id (`GenreIds`, looked up once per server) and, whatever the server did,
/// keep only titles whose own genre list contains the genre.
class GenreQuery {
  GenreQuery._();

  static final Map<String, Map<String, String>> _idsByServer = {};
  static final Map<String, Future<Map<String, String>>> _inflight = {};

  static String _norm(String s) => s.trim().toLowerCase();

  /// Does the item's own genre list contain [genre]?
  static bool itemHasGenre(Map<String, dynamic> raw, String genre) {
    final want = _norm(genre);
    final list = raw['Genres'];
    if (list is List) {
      for (final g in list) {
        if (_norm(g.toString()) == want) return true;
      }
    }
    final items = raw['GenreItems'];
    if (items is List) {
      for (final g in items) {
        if (g is Map && _norm(g['Name']?.toString() ?? '') == want) return true;
      }
    }
    return false;
  }

  /// True when [raw] has at least one of [genres] (any match).
  static bool itemHasAnyGenre(Map<String, dynamic> raw, Iterable<String> genres) =>
      genres.any((g) => itemHasGenre(raw, g));

  /// The server's id for [genre], or null (unknown / lookup failed).
  static Future<String?> genreId(MediaServerClient client, String genre) async {
    final key = client.baseUrl;
    var map = _idsByServer[key];
    if (map == null) {
      try {
        map = await (_inflight[key] ??= _loadIds(client))
            .timeout(const Duration(seconds: 10));
        _idsByServer[key] = map;
      } catch (_) {
        return null;
      } finally {
        _inflight.remove(key);
      }
    }
    return map[_norm(genre)];
  }

  static Future<Map<String, String>> _loadIds(MediaServerClient client) async {
    final res = await client.itemsApi.getGenres(
      userId: client.userId,
      recursive: true,
      limit: 1000,
      sortBy: 'SortName',
    );
    final out = <String, String>{};
    for (final g in (res['Items'] as List? ?? const [])) {
      if (g is! Map) continue;
      final name = g['Name']?.toString() ?? '';
      final id = g['Id']?.toString() ?? '';
      if (name.isNotEmpty && id.isNotEmpty) out[_norm(name)] = id;
    }
    return out;
  }

  /// Ids for [genres] that the server knows (may be empty).
  static Future<List<String>> genreIds(
    MediaServerClient client,
    Iterable<String> genres,
  ) async {
    final out = <String>[];
    for (final g in genres) {
      final id = await genreId(client, g);
      if (id != null) out.add(id);
    }
    return out;
  }
}
