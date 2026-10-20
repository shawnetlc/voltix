import 'package:get_it/get_it.dart';

import '../data/services/voltix_api_service.dart';

/// Voltix branding for a "My Media" library tile: a renamed display label plus
/// the URL of the Voltix category artwork that overrides the default
/// Jellyfin/Lumistream library image.
class VoltixLibraryBranding {
  final String displayName;
  final String imageUrl;

  const VoltixLibraryBranding({
    required this.displayName,
    required this.imageUrl,
  });
}

/// Maps a library to its Voltix branding, mirroring the web client's
/// `jellyfinProxy.ts` matching logic.
///
/// [rawName] is the library's raw display name (the label shown on the tile).
/// [serverName] is the name of the server the library came from and is used
/// only to derive the tier variant (primary / extra / base) for the five
/// tier-variant categories. When it cannot be resolved, the base tier is used.
///
/// Returns `null` when the library does not map to a known Voltix category, in
/// which case the caller should leave the original image and name untouched.
/// Prefix marking an image bundled with the app (MediaCard loads it with
/// Image.asset instead of from the network).
const String kAppAssetImagePrefix = 'asset:';

/// My Media artwork shipped inside the app (assets/categories), keyed by the
/// server's library name (lower-case, decorations stripped). Injected on the
/// device -- no server or web front end involved.
const Map<String, (String, String)> _voltixMyMediaArtwork = {
  '4k movies': ('4K Movies', 'assets/categories/4k_movies.jpg'),
  '4k movies - dolbyvision': ('4K Movies - DolbyVision', 'assets/categories/4k_movies_dv.jpg'),
  '4k tv shows - dolbyvision': ('4K Series - DolbyVision', 'assets/categories/4k_series_dv.jpg'),
  '4k movies dolbyvision': ('4K Movies - DolbyVision', 'assets/categories/4k_movies_dv.jpg'),
  '4k tv shows dolbyvision': ('4K Series - DolbyVision', 'assets/categories/4k_series_dv.jpg'),
  '4k tv shows': ('4K Series', 'assets/categories/4k_series.jpg'),
  'anime': ('Anime Series', 'assets/categories/anime_series.jpg'),
  'anime movies': ('Anime Movies', 'assets/categories/anime_movies.jpg'),
  'collections': ('Collections', 'assets/categories/collections.jpg'),
  'movies': ('Movies', 'assets/categories/movies.jpg'),
  'tv shows': ('Series', 'assets/categories/series.jpg'),
  'series': ('Series', 'assets/categories/series.jpg'),
  'playlists': ('Playlists', 'assets/categories/playlists.jpg'),
  'sports': ('Sport', 'assets/categories/sport.jpg'),
  'sports events': ('Sport Events', 'assets/categories/sport_events.jpg'),
  // supersilo library names
  'television': ('TV Series', 'assets/categories/series.jpg'),
  'movies 3d': ('3D Movies', 'assets/categories/3d_movies.jpg'),
  'anime tv': ('Anime Series', 'assets/categories/anime_series.jpg'),
  'movies international': ('Movies Foreign', 'assets/categories/foreign_movies.jpg'),
  'tv international': ('TV Series Foreign', 'assets/categories/foreign_series.jpg'),
  'movies 4k': ('4K Movies', 'assets/categories/4k_movies.jpg'),
  'movies 4k dv': ('4K Movies DV', 'assets/categories/4k_movies_dv.jpg'),
  'movies 4k-dv': ('4K Movies DV', 'assets/categories/4k_movies_dv.jpg'),
  'tv 4k': ('4K TV Series', 'assets/categories/4k_series.jpg'),
  'tv 4k-dv': ('4K TV Series DolbyVision', 'assets/categories/4k_series_dv.jpg'),
  'tv 4k dv': ('4K TV Series DolbyVision', 'assets/categories/4k_series_dv.jpg'),
};

/// Built-in posters for studio / network collections (Collections library).
/// Matched on the collection name with punctuation and spacing ignored, so
/// "HBO / Max", "HBO Max", "Warner Bros." and "Netflix Originals" all match.
const List<(List<String>, String)> _voltixCollectionArtwork = [
  (['a24'], 'assets/vault/vault_a24.jpg'),
  (['appletv', 'appletvplus'], 'assets/vault/vault_apple_tv.jpg'),
  (['bbc'], 'assets/vault/vault_bbc.jpg'),
  (['disney'], 'assets/vault/vault_disney.jpg'),
  (['hbomax', 'hbo'], 'assets/vault/vault_hbo_max.jpg'),
  (['hulu'], 'assets/vault/vault_hulu.jpg'),
  (['netflix'], 'assets/vault/vault_netflix.jpg'),
  (['nickelodeon', 'nick'], 'assets/vault/vault_nickelodeon.jpg'),
  (['paramount'], 'assets/vault/vault_paramount.jpg'),
  (['primevideo', 'amazonprimevideo', 'amazonprime', 'prime'], 'assets/vault/vault_prime_video.jpg'),
  (['universal'], 'assets/vault/vault_universal_studios.jpg'),
  (['warnerbros', 'warnerbrothers', 'warner'], 'assets/vault/vault_warner_bros.jpg'),
];

/// App-bundled poster (with [kAppAssetImagePrefix]) for a studio / network
/// collection such as "Netflix" or "HBO / Max"; null for any other name.
String? voltixCollectionArtwork(String rawName) {
  final key = rawName.toLowerCase().replaceAll('+', 'plus').replaceAll(RegExp(r'[^a-z0-9]'), '');
  if (key.isEmpty) return null;
  if (key == 'max') return '${kAppAssetImagePrefix}assets/vault/vault_hbo_max.jpg';
  for (final (prefixes, asset) in _voltixCollectionArtwork) {
    for (final p in prefixes) {
      if (key == p || key.startsWith(p)) return '$kAppAssetImagePrefix$asset';
    }
  }
  return null;
}

/// Exact-name My Media artwork for [rawName]: (display name, image ref with
/// [kAppAssetImagePrefix]). Null when the library is not one of the above.
(String, String)? voltixMyMediaArtwork(String rawName) {
  final key = rawName
      .replaceAll(RegExp(r'[★☆*]'), '')
      .replaceAll(RegExp(r'[\u2013\u2014]'), '-')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .toLowerCase();
  final hit = _voltixMyMediaArtwork[key] ??
      _voltixMyMediaArtwork[key.replaceAll(RegExp(r'\s*-\s*'), '-')] ??
      _voltixMyMediaArtwork[key.replaceAll(RegExp(r'\s*-\s*'), ' ')];
  if (hit == null) return null;
  return (hit.$1, '$kAppAssetImagePrefix${hit.$2}');
}

VoltixLibraryBranding? voltixLibraryBranding(
  String rawName,
  String? serverName,
) {
  // Strip star / asterisk decorations, then uppercase for matching.
  final clean = rawName.replaceAll(RegExp(r'[★☆*]'), '').trim();
  final name = clean.toUpperCase();

  String renameTo = '';
  String imageKey = '';

  final serverLower = (serverName ?? '').toLowerCase();
  final is4kServer = serverLower.contains('4k') || serverLower.contains('4 k');
  final is4kName = name.contains('4K') || name.contains('4 K');
  final is4k = is4kServer || is4kName;

  // 4K server / content matches first.
  if (is4k && name.contains('VAULT')) {
    renameTo = 'Vault';
    imageKey = 'Vault 4K';
  } else if (is4k && name.contains('MOVIE')) {
    renameTo = 'Movies';
    imageKey = 'Movies 4K';
  } else if (is4k && (name.contains('SHOW') || name.contains('SERIES'))) {
    renameTo = 'Series';
    imageKey = 'Series 4K';
  }
  // Regular matches.
  else if (name.contains('ANIME') && name.contains('MOVIE')) {
    renameTo = 'Anime Movies';
    imageKey = 'Anime Movies';
  } else if (name.contains('ANIME') &&
      (name.contains('SHOW') || name.contains('SERIES'))) {
    renameTo = 'Anime Series';
    imageKey = 'Anime Series';
  } else if (name.contains('REQUEST') && name.contains('MOVIE')) {
    renameTo = 'Movie Requests';
    imageKey = 'Movie Requests';
  } else if (name.contains('REQUEST') &&
      (name.contains('SHOW') || name.contains('SERIES'))) {
    renameTo = 'Series Requests';
    imageKey = 'Series Requests';
  } else if (name.contains('DOCUMENTARY') || name.contains('DOCUMENTARIES')) {
    renameTo = 'Documentaries';
    imageKey = 'Documentaries';
  } else if (name.contains('FOREIGN') && name.contains('MOVIE')) {
    renameTo = 'Foreign Movies';
    imageKey = 'Foreign Movies';
  } else if (name.contains('FOREIGN') &&
      (name.contains('SHOW') || name.contains('SERIES'))) {
    renameTo = 'Foreign Series';
    imageKey = 'Foreign Series';
  } else if (name.contains('KIDS') && name.contains('MOVIE')) {
    renameTo = 'Kids Movies';
    imageKey = 'Kids Movies';
  } else if (name.contains('KIDS') &&
      (name.contains('SHOW') || name.contains('SERIES'))) {
    renameTo = 'Kids Series';
    imageKey = 'Kids Series';
  } else if (name.contains('STAND-UP') || name.contains('COMEDY')) {
    renameTo = 'Stand-up Comedy';
    imageKey = 'Stand-up Comedy';
  } else if (name.contains('REALITY')) {
    renameTo = 'Reality Shows';
    imageKey = 'Reality Shows';
  } else if (name.contains('PPV') || name.contains('PAY-PER-VIEW')) {
    renameTo = 'Sport Pay-per-View';
    imageKey = 'Sport Pay-per-View';
  } else if (name.contains('SPORT')) {
    renameTo = 'Sports';
    imageKey = 'Sports';
  } else if (name.contains('VAULT')) {
    renameTo = 'Vault';
    imageKey = 'Vault';
  } else if (name.contains('MOVIE')) {
    renameTo = 'Movies';
    imageKey = 'Movies';
  } else if (name.contains('SHOW') || name.contains('SERIES')) {
    renameTo = 'Series';
    imageKey = 'Series';
  }

  if (renameTo.isEmpty || imageKey.isEmpty) return null;

  final relativePath = _relativePathForImageKey(imageKey, serverName);
  if (relativePath == null) return null;

  var baseUrl = _voltixBaseUrl();
  if (baseUrl.endsWith('/')) {
    baseUrl = baseUrl.substring(0, baseUrl.length - 1);
  }

  return VoltixLibraryBranding(
    displayName: renameTo,
    imageUrl: '$baseUrl$relativePath',
  );
}

String _voltixBaseUrl() {
  try {
    return GetIt.instance<VoltixApiService>().baseUrl;
  } catch (_) {
    return VoltixApiService.defaultBaseUrl;
  }
}

/// File stems for the five tier-variant categories. The tier suffix
/// (` primary` / ` extra` / none) is appended before URL-encoding.
const Map<String, String> _tierStems = {
  'Anime Movies': 'anime movies',
  'Anime Series': 'anime series',
  'Movies': 'movies',
  'Series': 'series',
  'Vault': 'vault',
};

/// Fixed (non-tiered) category paths, already URL-encoded.
const Map<String, String> _fixedPaths = {
  'Movie Requests': '/categories/movie%20requests.png',
  'Series Requests': '/categories/series%20requests.png',
  'Documentaries': '/categories/documentaries.png',
  'Foreign Movies': '/categories/foreign%20movies.png',
  'Foreign Series': '/categories/foreign%20series.png',
  'Kids Movies': '/categories/kids%20movies.png',
  'Kids Series': '/categories/kids%20series.png',
  'Stand-up Comedy': '/categories/stand-up%20comedy.png',
  'Reality Shows': '/categories/reality%20shows.png',
  'Sports': '/categories/sports.png',
  'Sport Pay-per-View': '/categories/sport%20pay-per-view.png',
  'Movies 4K': '/categories/movies%204k.png',
  'Series 4K': '/categories/series%204k.png',
  'Vault 4K': '/categories/vault%204k.png',
};

String? _relativePathForImageKey(String imageKey, String? serverName) {
  final stem = _tierStems[imageKey];
  if (stem != null) {
    final server = (serverName ?? '').toLowerCase();
    final tier = server.contains('primary')
        ? ' primary'
        : server.contains('extra')
        ? ' extra'
        : '';
    final file = '$stem$tier'.replaceAll(' ', '%20');
    return '/categories/$file.png';
  }
  return _fixedPaths[imageKey];
}
