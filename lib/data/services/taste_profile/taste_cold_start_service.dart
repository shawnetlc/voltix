import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';

import '../../../auth/store/voltix_session_store.dart';
import '../voltix_api_service.dart';

/// Starting signals for a profile that has nothing to infer from yet.
///
/// The taste engine works by turning watch history into genre, actor and
/// studio affinities, then querying the user's own server with them. A brand
/// new account has no history, so those affinities are empty, every row falls
/// back to the same broad popularity query, and the first impression of a
/// "personalized" home screen is one that looks identical for everyone.
///
/// The backend already maintains a cold-start set in blob storage (see
/// `setup-cold-start-recommendations.ts` and
/// `/api/voltix/recommendations/cold-start`) built from what is currently
/// popular. Its titles are TMDb entries rather than items on the viewer's
/// server, so they cannot be shown as a row directly — but the genre and
/// actor *names* it indexes travel perfectly well, and those are exactly what
/// the candidate queries need. So this uses the set as a seed for the query,
/// not as a source of content.
class TasteColdStartService {
  /// The set changes only when the backend regenerates it, so this refresh is
  /// generous and costs one request.
  static const _ttl = Duration(hours: 6);

  List<String>? _genres;
  List<String>? _actors;
  DateTime? _fetchedAt;
  Future<void>? _inFlight;

  bool get _isFresh {
    final at = _fetchedAt;
    return at != null && DateTime.now().difference(at) < _ttl;
  }

  /// Genre names to query with, strongest first. Empty when unavailable.
  Future<List<String>> seedGenres() async {
    await _ensureLoaded();
    return _genres ?? const [];
  }

  /// Actor names to query with, strongest first. Empty when unavailable.
  Future<List<String>> seedActors() async {
    await _ensureLoaded();
    return _actors ?? const [];
  }

  Future<void> _ensureLoaded() {
    if (_isFresh) return Future.value();
    return _inFlight ??= _load().whenComplete(() => _inFlight = null);
  }

  Future<void> _load() async {
    try {
      if (!GetIt.instance.isRegistered<VoltixApiService>() ||
          !GetIt.instance.isRegistered<VoltixSessionStore>()) {
        return;
      }
      final token = GetIt.instance<VoltixSessionStore>().sessionToken;
      if (token == null || token.isEmpty) return;

      final data = await GetIt.instance<VoltixApiService>().restGet(
        '/api/voltix/recommendations/cold-start',
        sessionToken: token,
      );
      if (data is! Map) return;

      final metadata = data['metadata'];
      if (metadata is Map) {
        _genres = _stringList(metadata['genresIndexed']);
        _actors = _stringList(metadata['topActorsIndexed']);
      }

      // Older sets may predate the metadata block; the highlight maps carry
      // the same names as their keys, so they stand in.
      final categories = data['categories'];
      if (categories is Map) {
        if (_genres == null || _genres!.isEmpty) {
          _genres = _keysOf(categories['genreHighlights']);
        }
        if (_actors == null || _actors!.isEmpty) {
          _actors = _keysOf(categories['actorHighlights']);
        }
      }

      _fetchedAt = DateTime.now();
    } catch (e) {
      // A cold start without seeds is the behaviour that already exists, so a
      // failure here degrades rather than breaks.
      debugPrint('[TasteColdStart] seed fetch failed: $e');
    }
  }

  static List<String> _stringList(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .map((e) => e?.toString().trim() ?? '')
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }

  static List<String> _keysOf(dynamic raw) {
    if (raw is! Map) return const [];
    return raw.keys
        .map((k) => k.toString().trim())
        .where((k) => k.isNotEmpty)
        .toList(growable: false);
  }

  void clear() {
    _genres = null;
    _actors = null;
    _fetchedAt = null;
  }
}
