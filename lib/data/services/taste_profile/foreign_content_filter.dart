import 'package:flutter/foundation.dart';
import 'package:server_core/server_core.dart';

/// Keeps foreign-language titles out of the taste-profile wizard.
///
/// Jellyfin does not report an item's original language, so the language
/// rules in TasteRecommendationEngine let most titles through as "unknown".
/// The reliable signal is the LIBRARY a title lives in: foreign titles sit in
/// libraries such as "Movies International" / "TV International". This looks
/// those libraries up once and collects the ids of every title in them, so the
/// wizard can (a) draw only from the other libraries and (b) drop any foreign
/// title already in a cached candidate list.
class ForeignContentFilter {
  ForeignContentFilter._();

  static final RegExp _foreignName = RegExp(
    r'international|foreign|world cinema|bollywood|hindi|korean|k-?drama|'
    r'asian|spanish|latino|french|german|turkish|arabic|telenovela|nordic|'
    r'scandi|danish|swedish|norwegian|finnish|dutch|italian|polish|russian|'
    r'portuguese|brazil|japanese|chinese|thai|indian|tamil|telugu|afrikaans',
    caseSensitive: false,
  );

  /// Sport libraries (sport events, PPV, wrestling, motorsport, ...) are not
  /// "taste" content either and are kept out the same way.
  static final RegExp _sportName = RegExp(
    r'\bsports?\b|sport events|pay-?per-?view|\bppv\b|\bwwe\b|\bufc\b|'
    r'wrestling|boxing|motorsport|formula ?1|\bf1\b|rugby|cricket|football|'
    r'soccer|\bnba\b|\bnfl\b|golf|tennis|racing',
    caseSensitive: false,
  );

  /// Libraries the wizard never draws from: foreign-language and sport.
  static bool isForeignLibraryName(String? name) =>
      name != null && (_foreignName.hasMatch(name) || _sportName.hasMatch(name));

  static const _englishCountries = {
    'us', 'usa', 'united states', 'united states of america', 'gb', 'uk',
    'united kingdom', 'great britain', 'england', 'scotland', 'wales',
    'ireland', 'ie', 'canada', 'ca', 'australia', 'au', 'new zealand', 'nz',
    'south africa', 'za',
  };
  static const _englishAudio = {'en', 'eng', 'english'};
  static const _unknownAudio = {'und', 'unk', 'unknown', 'mis', 'zxx', ''};

  /// Foreign-language title judged from its own metadata, for foreign titles
  /// filed in an ordinary library (e.g. Danish films in "Movies"):
  ///  * every audio track is tagged with a non-English language, or
  ///  * production countries are known and none is English-speaking, or
  ///  * the age rating carries a non-English country prefix (e.g. "DK-15").
  /// Titles without a poster are also left out: the wizard is for titles
  /// people recognise, and those are almost always obscure foreign entries.
  static bool isLikelyForeignItem(Map<String, dynamic> raw) {
    final tags = raw['ImageTags'];
    if (tags is! Map || tags['Primary'] == null) return true;

    final audio = <String>{};
    final streams = raw['MediaStreams'];
    if (streams is List) {
      for (final st in streams) {
        if (st is Map && st['Type']?.toString().toLowerCase() == 'audio') {
          final l = st['Language']?.toString().trim().toLowerCase() ?? '';
          if (!_unknownAudio.contains(l)) audio.add(l);
        }
      }
    }
    if (audio.isNotEmpty && !audio.any(_englishAudio.contains)) return true;

    final places = raw['ProductionLocations'];
    if (places is List && places.isNotEmpty) {
      final hasEnglish = places.any(
          (p) => _englishCountries.contains(p.toString().trim().toLowerCase()));
      if (!hasEnglish) return true;
    }

    final rating = raw['OfficialRating']?.toString() ?? '';
    final m = RegExp(r'^([A-Za-z]{2})-').firstMatch(rating);
    if (m != null && !_englishCountries.contains(m.group(1)!.toLowerCase())) {
      return true;
    }
    return false;
  }

  /// True when [id] is in a foreign/sport library already looked up this
  /// session (see [load]); false when nothing has been looked up yet.
  static bool isKnownExcludedId(String id) =>
      _cache.values.any((info) => info.isForeign(id));

  /// Everything the wizard must not offer: foreign or sport.
  static bool isExcludedItem(Map<String, dynamic> raw) =>
      isSportItem(raw) || isLikelyForeignItem(raw);

  /// Sport by genre, for sport titles filed in an ordinary library.
  static bool isSportItem(Map<String, dynamic> raw) {
    final genres = raw['Genres'];
    if (genres is! List) return false;
    return genres.any((g) {
      final s = g.toString().toLowerCase();
      return s == 'sport' || s == 'sports' || s.contains('sporting') ||
          s.contains('wrestling') || s.contains('motorsport');
    });
  }

  static final Map<String, ForeignLibraryInfo> _cache = {};
  static final Map<String, Future<ForeignLibraryInfo>> _inflight = {};
  static final Map<String, ForeignLibraryInfo> _viewsCache = {};

  /// Library list only (one quick request) - enough to choose which libraries
  /// to read from. [isForeign] is always false on this result; use [load]
  /// when the ids of titles in excluded libraries are needed.
  static Future<ForeignLibraryInfo> loadViews(MediaServerClient client) async {
    final key = client.baseUrl;
    final full = _cache[key];
    if (full != null) return full;
    final hit = _viewsCache[key];
    if (hit != null) return hit;
    try {
      final res = await client.userViewsApi
          .getUserViews()
          .timeout(const Duration(seconds: 15));
      final views = (res['Items'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();
      return _viewsCache[key] =
          ForeignLibraryInfo(views: views, foreignIds: const {});
    } catch (e) {
      debugPrint('[ForeignContentFilter] getUserViews failed: $e');
      return ForeignLibraryInfo(views: const [], foreignIds: const {});
    }
  }

  /// Library split plus ids of every title in excluded libraries, cached for
  /// the app session. Slow on big servers - never await it on a loading path.
  static Future<ForeignLibraryInfo> load(MediaServerClient client) {
    final key = client.baseUrl;
    final hit = _cache[key];
    if (hit != null) return Future.value(hit);
    return _inflight[key] ??= _load(client).then((info) {
      _cache[key] = info;
      return info;
    }).whenComplete(() => _inflight.remove(key));
  }

  static Future<ForeignLibraryInfo> _load(MediaServerClient client) async {
    List<Map<String, dynamic>> views;
    try {
      final res = await client.userViewsApi
          .getUserViews()
          .timeout(const Duration(seconds: 15));
      views = (res['Items'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();
    } catch (e) {
      debugPrint('[ForeignContentFilter] getUserViews failed: $e');
      return ForeignLibraryInfo(views: const [], foreignIds: const {});
    }

    final foreignViews =
        views.where((v) => isForeignLibraryName(v['Name']?.toString())).toList();
    final ids = <String>{};
    for (final v in foreignViews) {
      final parentId = v['Id']?.toString();
      if (parentId == null || parentId.isEmpty) continue;
      // Ids only (no fields, no images): a few hundred KB even for big libraries.
      for (var start = 0; start < 6000; start += 2000) {
        try {
          final res = await client.itemsApi.getItems(
            parentId: parentId,
            recursive: true,
            includeItemTypes: const ['Movie', 'Series'],
            startIndex: start,
            limit: 2000,
            fields: '',
            enableImageTypes: '',
            imageTypeLimit: 0,
            enableTotalRecordCount: false,
          ).timeout(const Duration(seconds: 15));
          final items = (res['Items'] as List? ?? [])
              .whereType<Map<String, dynamic>>()
              .toList();
          for (final i in items) {
            final id = i['Id']?.toString();
            if (id != null && id.isNotEmpty) ids.add(id);
          }
          if (items.length < 2000) break;
        } catch (e) {
          debugPrint('[ForeignContentFilter] ids for "${v['Name']}" failed: $e');
          break;
        }
      }
    }
    debugPrint('[ForeignContentFilter] ${foreignViews.length} foreign/sport '
        'librar${foreignViews.length == 1 ? 'y' : 'ies'}, ${ids.length} titles excluded');
    return ForeignLibraryInfo(views: views, foreignIds: ids);
  }
}

class ForeignLibraryInfo {
  ForeignLibraryInfo({required this.views, required this.foreignIds});

  final List<Map<String, dynamic>> views;
  final Set<String> foreignIds;

  bool get hasForeignLibraries => views.any(
      (v) => ForeignContentFilter.isForeignLibraryName(v['Name']?.toString()));

  /// Non-foreign libraries of [collectionType] ('movies' / 'tvshows').
  List<Map<String, dynamic>> englishViews(String collectionType) => views
      .where((v) =>
          (v['CollectionType']?.toString().toLowerCase() ?? '') ==
              collectionType &&
          !ForeignContentFilter.isForeignLibraryName(v['Name']?.toString()))
      .toList();

  bool isForeign(String id) => foreignIds.contains(id);
}
