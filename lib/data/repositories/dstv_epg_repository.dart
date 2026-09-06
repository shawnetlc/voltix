import 'dart:async';

import '../models/dstv/dstv_epg_models.dart';
import '../models/iptv_models.dart';
import '../services/dstv/dstv_api_client.dart';
import '../services/dstv/dstv_xmltv_client.dart';

/// Caches and merges DStv Guide data for the LT page's Guide/Schedule tabs.
///
/// Two independent caches, matching how often each actually changes:
///  - Channels (name/number/logo) barely ever change -- refetched once a day.
///  - Programmes are fetched one calendar date at a time, on demand, exactly
///    as the user asked ("a 14 day breakdown, but not all at the same time").
///    Each date fetched is kept so flipping back to a previously-viewed date
///    in the Guide is instant; the cache is capped so a long browsing session
///    can't grow it unbounded.
class DstvEpgRepository {
  final DstvApiClient _client;
  final DstvXmltvClient _xmltv;

  DstvEpgRepository({DstvApiClient? client, DstvXmltvClient? xmltvClient})
      : _client = client ?? DstvApiClient(),
        _xmltv = xmltvClient ?? DstvXmltvClient();

  static const _maxCachedDates = 16;
  static const _channelsTtl = Duration(hours: 24);
  // The XMLTV feed is a rolling window republished through the day; six hours
  // keeps artwork fresh without re-downloading ~1 MB on every catch-up visit.
  static const _xmltvTtl = Duration(hours: 6);
  static const guideDaySpan = 14;

  List<DstvChannel>? _channels;
  DateTime? _channelsFetchedAt;
  Completer<List<DstvChannel>>? _channelsInFlight;

  // Keyed by 'yyyy-MM-dd'. Insertion order tracked separately so the oldest
  // entry can be evicted once the cache is full.
  final Map<String, List<DstvChannelSchedule>> _programmesByDate = {};
  final List<String> _programmesDateOrder = [];
  final Map<String, Completer<List<DstvChannelSchedule>>> _programmesInFlight =
      {};

  // Per-programme artwork, keyed by DStv channel number. DStv's own guide API
  // returns no images at all, so this feed is the only thing standing between
  // the catch-up page and a wall of identical channel logos.
  Map<String, List<DstvProgramme>>? _xmltvProgrammes;
  DateTime? _xmltvFetchedAt;
  Completer<Map<String, List<DstvProgramme>>>? _xmltvInFlight;

  /// DStv's guide times are SAST (UTC+2) with no offset in the payload, so
  /// "now" for comparing against them has to be computed the same way rather
  /// than relying on the device's own timezone.
  static DateTime nowSast() =>
      DateTime.now().toUtc().add(const Duration(hours: 2));

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static String _dateKey(DateTime d) {
    final date = _dateOnly(d);
    final mm = date.month.toString().padLeft(2, '0');
    final dd = date.day.toString().padLeft(2, '0');
    return '${date.year}-$mm-$dd';
  }

  /// The dates the Guide's date picker should offer: today plus the next
  /// [guideDaySpan] - 1 days.
  static List<DateTime> guideDates({DateTime? from}) {
    final start = _dateOnly(from ?? nowSast());
    return List.generate(guideDaySpan, (i) => start.add(Duration(days: i)));
  }

  Future<List<DstvChannel>> getChannels({bool forceRefresh = false}) async {
    final cached = _channels;
    final fetchedAt = _channelsFetchedAt;
    if (!forceRefresh &&
        cached != null &&
        fetchedAt != null &&
        DateTime.now().difference(fetchedAt) < _channelsTtl) {
      return cached;
    }

    final inFlight = _channelsInFlight;
    if (inFlight != null) return inFlight.future;

    final completer = Completer<List<DstvChannel>>();
    _channelsInFlight = completer;
    try {
      final channels = await _client.getChannels();
      _channels = channels;
      _channelsFetchedAt = DateTime.now();
      completer.complete(channels);
      return channels;
    } catch (e, st) {
      // Fall back to a stale cache rather than an empty guide if we have one.
      if (cached != null) {
        completer.complete(cached);
        return cached;
      }
      completer.completeError(e, st);
      rethrow;
    } finally {
      _channelsInFlight = null;
    }
  }

  Future<List<DstvChannelSchedule>> _getProgrammesForDate(
    DateTime date,
  ) async {
    final key = _dateKey(date);
    final cached = _programmesByDate[key];
    if (cached != null) return cached;

    final inFlight = _programmesInFlight[key];
    if (inFlight != null) return inFlight.future;

    final completer = Completer<List<DstvChannelSchedule>>();
    _programmesInFlight[key] = completer;
    try {
      final schedules = await _client.getProgrammes(date);
      _cacheProgrammes(key, schedules);
      completer.complete(schedules);
      return schedules;
    } catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    } finally {
      _programmesInFlight.remove(key);
    }
  }

  void _cacheProgrammes(String key, List<DstvChannelSchedule> schedules) {
    if (!_programmesByDate.containsKey(key)) {
      _programmesDateOrder.add(key);
    }
    _programmesByDate[key] = schedules;
    while (_programmesDateOrder.length > _maxCachedDates) {
      final oldest = _programmesDateOrder.removeAt(0);
      _programmesByDate.remove(oldest);
    }
  }

  /// The merged Guide/Schedule rows for one calendar date: every DStv
  /// channel paired with that date's programmes. Also pulls in the first
  /// couple of hours of the following day so a programme still airing right
  /// at midnight isn't cut off abruptly at the edge of the grid -- the same
  /// "fetch today + tomorrow for continuity" reasoning the backend EPG sync
  /// already uses.
  Future<List<DstvGuideRow>> getGuideRows(DateTime date) async {
    final target = _dateOnly(date);
    final nextDay = target.add(const Duration(days: 1));

    final results = await Future.wait([
      getChannels(),
      _getProgrammesForDate(target),
      _getProgrammesForDate(nextDay).catchError((_) => <DstvChannelSchedule>[]),
    ]);
    final channels = results[0] as List<DstvChannel>;
    final todaySchedules = results[1] as List<DstvChannelSchedule>;
    final nextSchedules = results[2] as List<DstvChannelSchedule>;

    final nextByNumber = <String, DstvChannelSchedule>{
      for (final s in nextSchedules) s.number: s,
    };
    final cutoff = nextDay.add(const Duration(hours: 5));

    final todayByNumber = <String, DstvChannelSchedule>{
      for (final s in todaySchedules) s.number: s,
    };

    final rows = <DstvGuideRow>[];
    for (final channel in channels) {
      final today = todayByNumber[channel.number];
      final overflow = nextByNumber[channel.number]
              ?.programmes
              .where((p) => p.start.isBefore(cutoff)) ??
          const <DstvProgramme>[];
      final programmes = [...?today?.programmes, ...overflow];
      rows.add(DstvGuideRow(channel: channel, programmes: programmes));
    }
    return rows;
  }

  /// Normalizes a channel title for fuzzy matching across IPTV provider naming schemes.
  static String normalizeChannelName(String raw) {
    var s = raw.toLowerCase();
    // Remove country/category prefixes like "za:", "za -", "dstv:", "dstv -", "sa:"
    s = s.replaceAll(RegExp(r'\b(za|dstv|sa)\s*[:\-_|/]\s*'), '');
    s = s.replaceAll(RegExp(r'\[.*?\]|\(.*?\)|<.*?>'), '');
    s = s.replaceAll(RegExp(r'\b(fhd|uhd|4k|hd|sd|hevc|raw|vip|h\.265|1080p|720p|50fps|60fps)\b'), '');
    s = s.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  static const Map<String, String> _knownDstvAliases = {
    // M-Net & Movies
    'm net movies 1': '104',
    'mnet movies 1': '104',
    'm net movie 1': '104',
    'mnet movie 1': '104',
    'm net movies 2': '106',
    'mnet movies 2': '106',
    'm net movie 2': '106',
    'mnet movie 2': '106',
    'm net movies 3': '107',
    'mnet movies 3': '107',
    'm net movie 3': '107',
    'mnet movie 3': '107',
    'm net movies 4': '108',
    'mnet movies 4': '108',
    'm net movie 4': '108',
    'mnet movie 4': '108',
    'm net': '101',
    'mnet': '101',
    'm net 101': '101',
    'mnet 101': '101',
    'm net city': '102',
    'mnet city': '102',
    '1magic': '103',
    '1 magic': '103',
    'tnt': '111',
    'tnt africa': '111',
    'studio universal': '112',
    'movie room': '113',
    'kix': '114',
    'universal tv': '115',
    'universal channel': '115',
    'vuzu': '116',
    'universal plus': '117',
    'telemundo': '118',
    'bbc brit': '120',
    'discovery': '121',
    'discovery channel': '121',
    'comedy central': '122',
    'e entertainment': '124',
    'star life': '167',
    'zee world': '166',
    'mzansi magic': '161',
    'mzansi wethu': '162',
    'mzansi bioskop': '163',
    'novela magic': '165',
    'kyknet': '144',
    'kyknet kie': '145',
    'kyknet and kie': '145',
    'via': '147',

    // Africa Magic
    'am showcase': '151',
    'africa magic showcase': '151',
    'am epic': '152',
    'africa magic epic': '152',
    'am urban': '153',
    'africa magic urban': '153',
    'am family': '154',
    'africa magic family': '154',
    'am hausa': '156',
    'africa magic hausa': '156',
    'am yoruba': '157',
    'africa magic yoruba': '157',
    'am igbo': '159',
    'africa magic igbo': '159',

    // SuperSport
    'ss grandstand': '201',
    'supersport grandstand': '201',
    'ss psl': '202',
    'supersport psl': '202',
    'ss premier league': '203',
    'ss epl': '203',
    'supersport premier league': '203',
    'supersport epl': '203',
    'ss laliga': '204',
    'supersport laliga': '204',
    'ss football': '205',
    'supersport football': '205',
    'ss variety 1': '206',
    'supersport variety 1': '206',
    'ss variety 2': '207',
    'supersport variety 2': '207',
    'ss variety 3': '208',
    'supersport variety 3': '208',
    'ss variety 4': '209',
    'supersport variety 4': '209',
    'ss action': '210',
    'supersport action': '210',
    'ss rugby': '211',
    'supersport rugby': '211',
    'ss cricket': '212',
    'supersport cricket': '212',
    'ss golf': '213',
    'supersport golf': '213',
    'ss tennis': '214',
    'supersport tennis': '214',
    'ss motorsport': '215',
    'supersport motorsport': '215',
    'ss wwe': '216',
    'supersport wwe': '216',
    'ss blitz': '217',
    'supersport blitz': '217',
    'ss maximo 1': '218',
    'supersport maximo 1': '218',
    'ss maximo': '218',
    'ss maximo 2': '241',
    'supersport maximo 2': '241',

    // Free-to-Air / News / Doc
    'sabc 1': '191',
    'sabc1': '191',
    'sabc 2': '192',
    'sabc2': '192',
    'sabc 3': '193',
    'sabc3': '193',
    'etv': '194',
    'e tv': '194',
    'emovies': '195',
    'e movies': '195',
    'eextra': '196',
    'e extra': '196',
    'nat geo': '181',
    'national geographic': '181',
    'nat geo wild': '182',
    'wildearth': '183',
    'enca': '403',
    'sabc news': '404',
    'newzroom afrika': '405',
  };

  /// Finds a matching DStv channel from the official DStv channel catalog.
  Future<DstvChannel?> findMatchingChannel(
    String rawName, {
    String? channelNumber,
  }) async {
    try {
      final channels = await getChannels();
      if (channels.isEmpty) return null;

      // 1. Match by channel number if provided
      if (channelNumber != null && channelNumber.trim().isNotEmpty) {
        final numClean = channelNumber.trim();
        for (final ch in channels) {
          if (ch.number == numClean) return ch;
        }
      }

      final clean = normalizeChannelName(rawName);
      if (clean.isEmpty) return null;

      // 2. Direct alias lookup
      final aliasNum = _knownDstvAliases[clean];
      if (aliasNum != null) {
        for (final ch in channels) {
          if (ch.number == aliasNum) return ch;
        }
      }

      // 3. Exact normalized name or tag match
      for (final ch in channels) {
        final chClean = normalizeChannelName(ch.name);
        if (chClean.isNotEmpty && chClean == clean) return ch;
        final tagClean = normalizeChannelName(ch.tag);
        if (tagClean.isNotEmpty && tagClean == clean) return ch;
      }

      // 4. Substring / containment match
      for (final ch in channels) {
        final chClean = normalizeChannelName(ch.name);
        if (chClean.isNotEmpty && (clean.contains(chClean) || chClean.contains(clean))) {
          return ch;
        }
      }

      // 5. Check if alias exists as a substring
      for (final entry in _knownDstvAliases.entries) {
        if (clean.contains(entry.key) || entry.key.contains(clean)) {
          final ch = channels.where((c) => c.number == entry.value).firstOrNull;
          if (ch != null) return ch;
        }
      }

      return null;
    } catch (_) {
      return null;
    }
  }

  /// The whole XMLTV feed, cached for [_xmltvTtl]. Never throws: artwork is an
  /// enhancement, so a failure degrades to a stale map (or an empty one) and
  /// the catch-up page falls back to channel logos exactly as it did before.
  Future<Map<String, List<DstvProgramme>>> _getXmltvProgrammes() async {
    final cached = _xmltvProgrammes;
    final fetchedAt = _xmltvFetchedAt;
    if (cached != null &&
        fetchedAt != null &&
        DateTime.now().difference(fetchedAt) < _xmltvTtl) {
      return cached;
    }

    final inFlight = _xmltvInFlight;
    if (inFlight != null) return inFlight.future;

    final completer = Completer<Map<String, List<DstvProgramme>>>();
    _xmltvInFlight = completer;
    try {
      final data = await _xmltv.getProgrammesByChannelNumber();
      _xmltvProgrammes = data;
      _xmltvFetchedAt = DateTime.now();
      completer.complete(data);
      return data;
    } catch (_) {
      final fallback = cached ?? const <String, List<DstvProgramme>>{};
      completer.complete(fallback);
      return fallback;
    } finally {
      _xmltvInFlight = null;
    }
  }

  /// Feed programmes for one DStv channel number, empty if unavailable.
  Future<List<DstvProgramme>> getXmltvProgrammesForChannel(
    String channelNumber,
  ) async {
    if (channelNumber.trim().isEmpty) return const <DstvProgramme>[];
    try {
      final all = await _getXmltvProgrammes();
      return all[channelNumber.trim()] ?? const <DstvProgramme>[];
    } catch (_) {
      return const <DstvProgramme>[];
    }
  }

  /// Finds the feed programme that corresponds to [p] from DStv's own guide.
  ///
  /// The two sources agree on what is airing but not always on the exact slot
  /// boundary, so candidates are taken within half an hour of each other and a
  /// matching title is scored ahead of a merely closer start time.
  static DstvProgramme? _matchArtwork(
    List<DstvProgramme> pool,
    DstvProgramme p,
  ) {
    if (pool.isEmpty) return null;
    final title = p.title.trim().toLowerCase();
    DstvProgramme? best;
    var bestScore = 1 << 30;
    for (final candidate in pool) {
      final delta = candidate.start.difference(p.start).inMinutes.abs();
      if (delta > 30) continue;
      final score =
          candidate.title.trim().toLowerCase() == title ? delta : delta + 60;
      if (score < bestScore) {
        bestScore = score;
        best = candidate;
      }
    }
    return best;
  }

  /// Fetches past catch-up programmes for a DStv channel directly from DStv's
  /// official TV Guide API with true English programme metadata, and grafts
  /// the XMLTV feed's per-programme artwork and synopsis on top.
  Future<List<IptvEpgEntry>> getCatchupProgrammesForDstvChannel(
    DstvChannel channel, {
    Duration lookback = const Duration(hours: 24),
  }) async {
    try {
      final now = nowSast();
      final today = _dateOnly(now);
      final yesterday = today.subtract(const Duration(days: 1));

      final results = await Future.wait([
        _getProgrammesForDate(yesterday).catchError((_) => <DstvChannelSchedule>[]),
        _getProgrammesForDate(today).catchError((_) => <DstvChannelSchedule>[]),
      ]);

      final yestSched = results[0].where((s) => s.number == channel.number).firstOrNull;
      final todaySched = results[1].where((s) => s.number == channel.number).firstOrNull;

      final allProgs = <DstvProgramme>[
        if (yestSched != null) ...yestSched.programmes,
        if (todaySched != null) ...todaySched.programmes,
      ];

      // DStv's guide is authoritative for titles and times but ships no
      // images; the feed has the images. Merge the two, and if DStv returned
      // nothing at all for this channel, let the feed stand in on its own
      // rather than showing an empty catch-up list.
      final artwork = await getXmltvProgrammesForChannel(channel.number);
      final sourceProgs = allProgs.isNotEmpty
          ? [for (final p in allProgs) p.mergedWith(_matchArtwork(artwork, p))]
          : artwork;

      final nowEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final earliestEpoch = nowEpoch - lookback.inSeconds;

      final entries = <IptvEpgEntry>[];
      final seenKeys = <String>{};

      for (final p in sourceProgs) {
        // Convert SAST (UTC+2) to UTC epoch seconds
        final startEpoch = DateTime.utc(
          p.start.year,
          p.start.month,
          p.start.day,
          p.start.hour,
          p.start.minute,
        ).subtract(const Duration(hours: 2)).millisecondsSinceEpoch ~/ 1000;

        final endEpoch = DateTime.utc(
          p.end.year,
          p.end.month,
          p.end.day,
          p.end.hour,
          p.end.minute,
        ).subtract(const Duration(hours: 2)).millisecondsSinceEpoch ~/ 1000;

        if (endEpoch > nowEpoch) continue; // upcoming or currently airing
        if (startEpoch < earliestEpoch) continue; // older than lookback window

        final dedupeKey = '$startEpoch|${p.title}';
        if (!seenKeys.add(dedupeKey)) continue;

        // The channel logo is the last resort now, not the default -- it was
        // being applied to every row, which is what made every catch-up tile
        // look identical.
        final icon = p.iconUrl ?? channel.thumbnailUrl ?? channel.logo;
        entries.add(IptvEpgEntry(
          title: p.title,
          description: p.description ?? '',
          startTimestamp: startEpoch,
          stopTimestamp: endEpoch,
          icon: icon,
        ));
      }

      entries.sort((a, b) => (b.startTimestamp ?? 0).compareTo(a.startTimestamp ?? 0));
      return entries;
    } catch (_) {
      return const <IptvEpgEntry>[];
    }
  }

  void dispose() {
    _client.close();
    _xmltv.close();
  }
}
