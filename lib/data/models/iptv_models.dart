/// Typed models for the Voltix backend IPTV API (`/api/iptv/*`).
///
/// These mirror the JSON shapes produced by `server/iptvProxy.ts` on the
/// Voltix web portal backend.
library;

/// Content section of the IPTV catalogue.
enum IptvSection { live, movies, series }

extension IptvSectionApi on IptvSection {
  /// The `type` query value expected by the backend.
  String get apiType => switch (this) {
        IptvSection.live => 'live',
        IptvSection.movies => 'vod',
        IptvSection.series => 'series',
      };
}

/// A category returned by `GET /api/iptv/categories`.
///
/// The backend prepends pseudo-categories `favorites` and `all`.
class IptvCategory {
  final String id;
  final String name;
  final int? count;

  const IptvCategory({required this.id, required this.name, this.count});

  bool get isFavorites => id == 'favorites';
  bool get isAll => id == 'all';

  factory IptvCategory.fromJson(Map<String, dynamic> json) => IptvCategory(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        count: json['count'] is num ? (json['count'] as num).toInt() : null,
      );
}

/// A single EPG programme entry from `GET /api/iptv/epg/simple`
/// (also embedded as `currentProgram` on live content items).
class IptvEpgEntry {
  final String title;
  final String description;
  final int? startTimestamp; // epoch seconds
  final int? stopTimestamp; // epoch seconds
  final String? icon;

  const IptvEpgEntry({
    required this.title,
    required this.description,
    this.startTimestamp,
    this.stopTimestamp,
    this.icon,
  });

  factory IptvEpgEntry.fromJson(Map<String, dynamic> json) => IptvEpgEntry(
        title: json['title']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
        startTimestamp:
            json['startTimestamp'] is num ? (json['startTimestamp'] as num).toInt() : null,
        stopTimestamp:
            json['stopTimestamp'] is num ? (json['stopTimestamp'] as num).toInt() : null,
        icon: json['icon']?.toString(),
      );

  IptvEpgEntry copyWith({
    String? title,
    String? description,
    int? startTimestamp,
    int? stopTimestamp,
    String? icon,
  }) =>
      IptvEpgEntry(
        title: title ?? this.title,
        description: description ?? this.description,
        startTimestamp: startTimestamp ?? this.startTimestamp,
        stopTimestamp: stopTimestamp ?? this.stopTimestamp,
        icon: icon ?? this.icon,
      );

  bool get hasTimes => startTimestamp != null && stopTimestamp != null;

  bool isAiringAt(int epochSeconds) =>
      hasTimes && startTimestamp! <= epochSeconds && stopTimestamp! > epochSeconds;

  /// 0.0–1.0 progress through the programme at [epochSeconds].
  double progressAt(int epochSeconds) {
    if (!hasTimes || stopTimestamp! <= startTimestamp!) return 0;
    final p = (epochSeconds - startTimestamp!) / (stopTimestamp! - startTimestamp!);
    return p.clamp(0.0, 1.0);
  }

  /// Key used to deduplicate guide entries (start + title).
  String get dedupeKey => '${startTimestamp ?? 0}|$title';
}

/// A live channel, movie or series returned by `GET /api/iptv/content`.
class IptvContentItem {
  final String id;
  final String title;
  final String categoryId;
  final String? poster;
  final String? description;
  final String? genre;
  final String? year;
  final String? epgChannelId;
  final bool hasArchive;
  final String? rating;
  final String? duration;
  final String? containerExtension;
  final int? streamId;
  final int? seriesId;
  final String? channelNumber;
  final IptvEpgEntry? currentProgram;

  const IptvContentItem({
    required this.id,
    required this.title,
    required this.categoryId,
    this.poster,
    this.description,
    this.genre,
    this.year,
    this.epgChannelId,
    this.hasArchive = false,
    this.rating,
    this.duration,
    this.containerExtension,
    this.streamId,
    this.seriesId,
    this.channelNumber,
    this.currentProgram,
  });

  factory IptvContentItem.fromJson(Map<String, dynamic> json) => IptvContentItem(
        id: json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        categoryId: json['categoryId']?.toString() ?? '',
        poster: json['poster']?.toString(),
        description: json['description']?.toString(),
        genre: json['genre']?.toString(),
        year: json['year']?.toString(),
        epgChannelId: json['epgChannelId']?.toString(),
        hasArchive: json['hasArchive'] == true,
        rating: json['rating']?.toString(),
        duration: json['duration']?.toString(),
        containerExtension: json['containerExtension']?.toString(),
        streamId: json['streamId'] is num ? (json['streamId'] as num).toInt() : null,
        seriesId: json['seriesId'] is num ? (json['seriesId'] as num).toInt() : null,
        channelNumber: json['channelNumber']?.toString(),
        currentProgram: json['currentProgram'] is Map<String, dynamic>
            ? IptvEpgEntry.fromJson(json['currentProgram'] as Map<String, dynamic>)
            : null,
      );

  /// Rating formatted to one decimal, or null when absent/unparseable.
  String? get displayRating {
    final v = double.tryParse(rating ?? '');
    if (v == null || v <= 0) return null;
    return v.toStringAsFixed(1);
  }
}

/// A page of content plus pagination info from `GET /api/iptv/content`.
class IptvContentPage {
  final List<IptvContentItem> items;
  final int total;
  final bool hasMore;
  final int? nextOffset;

  const IptvContentPage({
    required this.items,
    required this.total,
    required this.hasMore,
    this.nextOffset,
  });

  factory IptvContentPage.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] as List? ?? const [];
    final pagination = json['pagination'] as Map<String, dynamic>? ?? const {};
    return IptvContentPage(
      items: rawItems
          .whereType<Map<String, dynamic>>()
          .map(IptvContentItem.fromJson)
          .toList(growable: false),
      total: pagination['total'] is num ? (pagination['total'] as num).toInt() : rawItems.length,
      hasMore: pagination['hasMore'] == true,
      nextOffset:
          pagination['nextOffset'] is num ? (pagination['nextOffset'] as num).toInt() : null,
    );
  }
}

/// A single series episode from `GET /api/iptv/series-info`.
class IptvEpisode {
  final int id;
  final String title;
  final int? episodeNumber;
  final int? seasonNumber;
  final String containerExtension;
  final String? poster;
  final String? plot;
  final double? rating;
  final String? airDate;

  const IptvEpisode({
    required this.id,
    required this.title,
    this.episodeNumber,
    this.seasonNumber,
    this.containerExtension = 'mp4',
    this.poster,
    this.plot,
    this.rating,
    this.airDate,
  });

  factory IptvEpisode.fromJson(Map<String, dynamic> json) => IptvEpisode(
        id: json['id'] is num ? (json['id'] as num).toInt() : 0,
        title: json['title']?.toString() ?? '',
        episodeNumber:
            json['episodeNumber'] is num ? (json['episodeNumber'] as num).toInt() : null,
        seasonNumber:
            json['seasonNumber'] is num ? (json['seasonNumber'] as num).toInt() : null,
        containerExtension: json['containerExtension']?.toString() ?? 'mp4',
        poster: json['poster']?.toString(),
        plot: json['plot']?.toString(),
        rating: json['rating'] is num ? (json['rating'] as num).toDouble() : null,
        airDate: json['airDate']?.toString(),
      );
}

/// Series details from `GET /api/iptv/series-info` (TMDB/TVmaze enriched).
class IptvSeriesInfo {
  final String name;
  final String? cover;
  final String? plot;
  final String? genre;
  final String? rating;
  final String? releaseDate;

  /// Comma-separated cast list from get_series_info. Returned by
  /// /api/iptv/series-info but not parsed here until now.
  final String? cast;
  final String? director;

  /// Wide artwork URLs. The provider returns an array; usually 0 or 1 entry.
  final List<String> backdropPath;

  final List<int> seasonNumbers;
  final Map<int, List<IptvEpisode>> episodesBySeason;

  const IptvSeriesInfo({
    required this.name,
    this.cover,
    this.plot,
    this.genre,
    this.rating,
    this.releaseDate,
    this.cast,
    this.director,
    this.backdropPath = const <String>[],
    required this.seasonNumbers,
    required this.episodesBySeason,
  });

  factory IptvSeriesInfo.fromJson(Map<String, dynamic> json) {
    final info = json['info'] as Map<String, dynamic>? ?? const {};
    final rawSeasons = json['seasons'] as List? ?? const [];
    final rawEpisodes = json['episodesBySeason'] as Map<String, dynamic>? ?? const {};

    final episodesBySeason = <int, List<IptvEpisode>>{};
    for (final entry in rawEpisodes.entries) {
      final seasonNumber = int.tryParse(entry.key);
      if (seasonNumber == null || entry.value is! List) continue;
      episodesBySeason[seasonNumber] = (entry.value as List)
          .whereType<Map<String, dynamic>>()
          .map(IptvEpisode.fromJson)
          .toList(growable: false);
    }

    final seasonNumbers = rawSeasons
        .whereType<Map<String, dynamic>>()
        .map((s) => s['seasonNumber'] is num ? (s['seasonNumber'] as num).toInt() : null)
        .whereType<int>()
        .toList(growable: false);

    return IptvSeriesInfo(
      name: info['name']?.toString() ?? '',
      cover: info['cover']?.toString(),
      plot: info['plot']?.toString(),
      genre: info['genre']?.toString(),
      rating: info['rating']?.toString(),
      releaseDate: info['releaseDate']?.toString(),
      cast: info['cast']?.toString(),
      director: info['director']?.toString(),
      backdropPath: (info['backdropPath'] as List?)
              ?.map((b) => b?.toString() ?? '')
              .where((b) => b.isNotEmpty)
              .toList(growable: false) ??
          const <String>[],
      seasonNumbers: seasonNumbers.isNotEmpty
          ? seasonNumbers
          : (episodesBySeason.keys.toList()..sort()),
      episodesBySeason: episodesBySeason,
    );
  }
}

// ─── Watch progress (`/api/progress`) ────────────────────────────────────────

/// The `type` values accepted by the watch-progress API.
///
/// These are the exact strings the Voltix web player writes
/// (`client/src/pages/iptv-player/lib/api.ts`), so progress recorded here shows
/// up there and vice versa. `vod` also matches
/// [IptvSectionApi.apiType] for [IptvSection.movies].
class IptvProgressType {
  const IptvProgressType._();

  /// VOD movies.
  static const String movie = 'vod';

  /// Individual series episodes (the `itemId` is the episode id).
  static const String episode = 'series_episode';
}

/// Formats [seconds] as `m:ss` or `h:mm:ss`.
String formatIptvPosition(double seconds) {
  final total = seconds.isFinite && seconds > 0 ? seconds.round() : 0;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  return '$m:$ss';
}

/// A single watch-progress row from `GET /api/progress`.
class IptvProgress {
  final String itemId;
  final double currentTime; // seconds
  final double totalDuration; // seconds
  final bool isWatched;
  final bool needsTranscode;
  final int updatedAt; // epoch seconds

  const IptvProgress({
    required this.itemId,
    this.currentTime = 0,
    this.totalDuration = 0,
    this.isWatched = false,
    this.needsTranscode = false,
    this.updatedAt = 0,
  });

  factory IptvProgress.fromJson(Map<String, dynamic> json) => IptvProgress(
        itemId: json['itemId']?.toString() ?? '',
        currentTime:
            json['currentTime'] is num ? (json['currentTime'] as num).toDouble() : 0,
        totalDuration: json['totalDuration'] is num
            ? (json['totalDuration'] as num).toDouble()
            : 0,
        isWatched: json['isWatched'] == true,
        needsTranscode: json['needsTranscode'] == true,
        updatedAt: json['updatedAt'] is num ? (json['updatedAt'] as num).toInt() : 0,
      );

  /// Minimum saved position (seconds) that is worth offering a resume for.
  static const double resumeThresholdSeconds = 15;

  /// 0.0–1.0 through the item (0 when the total duration is unknown).
  double get fraction {
    if (totalDuration <= 0) return 0;
    return (currentTime / totalDuration).clamp(0.0, 1.0);
  }

  /// Whether playback should resume mid-stream rather than start from zero.
  bool get canResume =>
      !isWatched &&
      currentTime >= resumeThresholdSeconds &&
      (totalDuration <= 0 ||
          totalDuration - currentTime > resumeThresholdSeconds);

  /// `m:ss` / `h:mm:ss` label for the saved position.
  String get positionLabel => formatIptvPosition(currentTime);

  Duration get position => Duration(milliseconds: (currentTime * 1000).round());
}

/// The most recently watched episode of a series, from
/// `GET /api/progress/series` (`lastEpisode`).
class IptvEpisodeProgress {
  final String episodeId;
  final int? seasonNumber;
  final int? episodeNumber;
  final double currentTime;
  final double totalDuration;
  final bool isWatched;
  final bool needsTranscode;

  const IptvEpisodeProgress({
    required this.episodeId,
    this.seasonNumber,
    this.episodeNumber,
    this.currentTime = 0,
    this.totalDuration = 0,
    this.isWatched = false,
    this.needsTranscode = false,
  });

  factory IptvEpisodeProgress.fromJson(Map<String, dynamic> json) =>
      IptvEpisodeProgress(
        episodeId: json['episodeId']?.toString() ?? '',
        seasonNumber:
            json['seasonNumber'] is num ? (json['seasonNumber'] as num).toInt() : null,
        episodeNumber: json['episodeNumber'] is num
            ? (json['episodeNumber'] as num).toInt()
            : null,
        currentTime:
            json['currentTime'] is num ? (json['currentTime'] as num).toDouble() : 0,
        totalDuration: json['totalDuration'] is num
            ? (json['totalDuration'] as num).toDouble()
            : 0,
        isWatched: json['isWatched'] == true,
        needsTranscode: json['needsTranscode'] == true,
      );

  /// Same rule as [IptvProgress.canResume].
  bool get canResume =>
      !isWatched &&
      currentTime >= IptvProgress.resumeThresholdSeconds &&
      (totalDuration <= 0 ||
          totalDuration - currentTime > IptvProgress.resumeThresholdSeconds);

  String get positionLabel => formatIptvPosition(currentTime);

  Duration get position => Duration(milliseconds: (currentTime * 1000).round());

  /// `S1E4`, or null when the season/episode numbers are unknown.
  String? get episodeCode => (seasonNumber != null && episodeNumber != null)
      ? 'S${seasonNumber}E$episodeNumber'
      : null;
}

/// Series-wide progress summary from `GET /api/progress/series`.
class IptvSeriesProgress {
  final IptvEpisodeProgress? lastEpisode;
  final Set<String> watchedEpisodeIds;

  const IptvSeriesProgress({
    this.lastEpisode,
    this.watchedEpisodeIds = const <String>{},
  });

  factory IptvSeriesProgress.fromJson(Map<String, dynamic> json) =>
      IptvSeriesProgress(
        lastEpisode: json['lastEpisode'] is Map<String, dynamic>
            ? IptvEpisodeProgress.fromJson(
                json['lastEpisode'] as Map<String, dynamic>)
            : null,
        watchedEpisodeIds: (json['watchedEpisodeIds'] as List? ?? const [])
            .map((e) => e.toString())
            .toSet(),
      );

  bool isWatchedEpisode(int episodeId) =>
      watchedEpisodeIds.contains(episodeId.toString());
}
