/// Models for the public DStv TV Guide API
/// (https://www.dstv.com/umbraco/api/TvGuide/...). Unauthenticated, used
/// directly by the app to populate the LT (native Live TV) page's Guide and
/// Schedule tabs with real DStv channel and programme data.
library;

/// One row from GetChannels: a DStv channel's static info (name/number/logo).
/// Refreshed roughly daily -- this never changes within a session.
class DstvChannel {
  final String number;
  final String name;
  final String tag;
  final String? logo;
  final String? logoDark;
  final String? detail;
  final String? thumbnailUrl;

  const DstvChannel({
    required this.number,
    required this.name,
    required this.tag,
    this.logo,
    this.logoDark,
    this.detail,
    this.thumbnailUrl,
  });

  factory DstvChannel.fromJson(Map<String, dynamic> json) {
    String? str(dynamic v) {
      if (v == null) return null;
      final s = v.toString().trim();
      return s.isEmpty ? null : s;
    }

    return DstvChannel(
      number: str(json['Number']) ?? '',
      name: str(json['Name']) ?? '',
      tag: str(json['Tag']) ?? '',
      logo: str(json['Logo']),
      logoDark: str(json['ChannelLogoDark']),
      detail: str(json['ChannelDetail']),
      thumbnailUrl: str(json['ThumbnailImageUrl']),
    );
  }
}

/// One scheduled programme on a channel, as returned by GetProgrammes.
///
/// [start]/[end] are parsed as-is from the API and are SAST (UTC+2) wall-clock
/// values with no timezone suffix -- they are intentionally kept as naive
/// DateTimes rather than converted, so they can be compared directly against
/// [DstvEpgRepository.nowSast] without depending on the device's own timezone.
class DstvProgramme {
  final String title;
  final DateTime start;
  final DateTime end;

  /// Per-programme artwork. DStv's GetProgrammes JSON does not carry this --
  /// it only ever returns Title/StartTime/EndTime -- so it is null on
  /// programmes built from that API and populated from the XMLTV feed
  /// (see DstvXmltvClient), which does publish one image per programme.
  /// Already percent-encoded, because ~6% of the feed's image paths contain
  /// raw spaces that would otherwise fail to load.
  final String? iconUrl;

  /// Synopsis, likewise only available from the XMLTV feed.
  final String? description;

  final int? season;
  final int? episode;

  /// Age restriction as published (e.g. '16', 'PG'), XMLTV feed only.
  final String? rating;

  const DstvProgramme({
    required this.title,
    required this.start,
    required this.end,
    this.iconUrl,
    this.description,
    this.season,
    this.episode,
    this.rating,
  });

  Duration get duration => end.difference(start);

  bool isAiringAt(DateTime sastTime) =>
      !sastTime.isBefore(start) && sastTime.isBefore(end);

  /// Returns a copy carrying [other]'s artwork and metadata wherever this
  /// programme has none. Used to graft XMLTV artwork onto the DStv API's
  /// authoritative titles and times without losing either side.
  DstvProgramme mergedWith(DstvProgramme? other) {
    if (other == null) return this;
    return DstvProgramme(
      title: title.isNotEmpty ? title : other.title,
      start: start,
      end: end,
      iconUrl: iconUrl ?? other.iconUrl,
      description: (description != null && description!.isNotEmpty)
          ? description
          : other.description,
      season: season ?? other.season,
      episode: episode ?? other.episode,
      rating: rating ?? other.rating,
    );
  }

  static DstvProgramme? fromJson(Map<String, dynamic> json) {
    final title = json['Title']?.toString().trim() ?? '';
    final startRaw = json['StartTime']?.toString();
    final endRaw = json['EndTime']?.toString();
    if (startRaw == null || endRaw == null) return null;
    final start = DateTime.tryParse(startRaw);
    final end = DateTime.tryParse(endRaw);
    if (start == null || end == null) return null;
    return DstvProgramme(title: title, start: start, end: end);
  }
}

/// A channel's full schedule for one requested date, as one entry of a
/// GetProgrammes response.
class DstvChannelSchedule {
  final String number;
  final String tag;
  final String name;
  final List<DstvProgramme> programmes;

  const DstvChannelSchedule({
    required this.number,
    required this.tag,
    required this.name,
    required this.programmes,
  });

  factory DstvChannelSchedule.fromJson(Map<String, dynamic> json) {
    final rawProgrammes = json['Programmes'] as List? ?? const [];
    final programmes = rawProgrammes
        .whereType<Map<String, dynamic>>()
        .map(DstvProgramme.fromJson)
        .whereType<DstvProgramme>()
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    return DstvChannelSchedule(
      number: json['Number']?.toString().trim() ?? '',
      tag: json['Tag']?.toString().trim() ?? '',
      name: json['Name']?.toString().trim() ?? '',
      programmes: programmes,
    );
  }
}

/// A single row the Guide/Schedule grid renders: a channel merged with its
/// programmes for whichever date is currently selected.
class DstvGuideRow {
  final DstvChannel channel;
  final List<DstvProgramme> programmes;

  const DstvGuideRow({required this.channel, required this.programmes});
}
