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
