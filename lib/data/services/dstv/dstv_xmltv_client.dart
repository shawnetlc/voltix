import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';

import '../../models/dstv/dstv_epg_models.dart';

/// Reads the community DStv XMLTV feed, which is the only source we have of
/// *per-programme* artwork.
///
/// DStv's own TV Guide API (see [DstvApiClient]) returns nothing but
/// Title/StartTime/EndTime, so every catch-up tile built from it could only
/// ever fall back to the channel's logo -- which is why the catch-up page
/// showed the same picture on every row. This feed publishes one `<icon>` per
/// programme (~99.8% coverage) plus a synopsis, season/episode and rating.
///
/// The feed is a gzipped XMLTV file of roughly 1 MB compressed / 8.7 MB
/// expanded, holding ~168 channels and ~14.5k programmes across a rolling
/// window. It is fetched at most a couple of times a day (see the repository's
/// cache) and parsed straight into trimmed [DstvProgramme] objects, so the
/// large intermediate string is released as soon as the parse returns rather
/// than being retained as a DOM -- that matters on low-memory TV boxes.
class DstvXmltvClient {
  static const feedUrl =
      'https://raw.githubusercontent.com/matthuisman/i.mjh.nz/refs/heads/master/DStv/za.xml.gz';

  final Dio _dio;

  DstvXmltvClient({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 60),
            ));

  /// Every programme in the feed, grouped by DStv channel number ('101',
  /// '104', ...) so it can be joined against [DstvChannel.number]. Each
  /// channel's list is sorted by start time. Throws on network failure --
  /// the repository decides how to degrade.
  Future<Map<String, List<DstvProgramme>>> getProgrammesByChannelNumber() async {
    final response = await _dio.get<List<int>>(
      feedUrl,
      options: Options(responseType: ResponseType.bytes),
    );
    final bytes = response.data;
    if (bytes == null || bytes.isEmpty) return const {};

    // Some clients/proxies transparently inflate a .gz response. Sniff the
    // gzip magic number rather than assuming either way.
    final isGzip = bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;
    final raw = isGzip ? GZipDecoder().decodeBytes(bytes) : bytes;

    return parseXmltv(utf8.decode(raw, allowMalformed: true));
  }

  /// Parses an XMLTV document into programmes keyed by DStv channel number.
  ///
  /// Deliberately a hand-rolled forward scan rather than a DOM parse: we need
  /// six fields out of ~14.5k nodes, and building a full document tree for
  /// that costs several times the memory on the cheapest devices we ship to.
  /// Exposed for testing.
  static Map<String, List<DstvProgramme>> parseXmltv(String xml) {
    // Pass 1: '<channel id="101.dstv_com">' -> '101'. The feed also carries an
    // explicit <channel_id>, which is preferred; the id's numeric prefix is
    // the fallback if that element ever disappears.
    final channelNumbers = <String, String>{};
    var i = xml.indexOf('<channel ');
    while (i >= 0) {
      final openEnd = xml.indexOf('>', i);
      if (openEnd < 0) break;
      final closeStart = xml.indexOf('</channel>', openEnd);
      if (closeStart < 0) break;

      final id = _attr(xml, i, openEnd, 'id');
      if (id != null && id.isNotEmpty) {
        final body = xml.substring(openEnd + 1, closeStart);
        final explicit = _childText(body, 'channel_id');
        final number = (explicit != null && explicit.isNotEmpty)
            ? explicit
            : (id.contains('.') ? id.substring(0, id.indexOf('.')) : id);
        if (number.isNotEmpty) channelNumbers[id] = number;
      }

      i = xml.indexOf('<channel ', closeStart);
    }

    // Pass 2: programmes.
    final byChannel = <String, List<DstvProgramme>>{};
    i = xml.indexOf('<programme ');
    while (i >= 0) {
      final openEnd = xml.indexOf('>', i);
      if (openEnd < 0) break;
      final closeStart = xml.indexOf('</programme>', openEnd);
      if (closeStart < 0) break;

      final channelRef = _attr(xml, i, openEnd, 'channel');
      final start = _parseTimeAsSast(_attr(xml, i, openEnd, 'start'));
      final stop = _parseTimeAsSast(_attr(xml, i, openEnd, 'stop'));
      final number = channelRef == null ? null : channelNumbers[channelRef];

      if (number != null && start != null && stop != null) {
        final body = xml.substring(openEnd + 1, closeStart);
        final title = _childText(body, 'title') ?? '';
        if (title.isNotEmpty) {
          byChannel.putIfAbsent(number, () => <DstvProgramme>[]).add(
                DstvProgramme(
                  title: title,
                  start: start,
                  end: stop,
                  iconUrl: _encodeUrl(_iconSrc(body)),
                  description: _childText(body, 'desc'),
                  season: int.tryParse(_childText(body, 'season') ?? ''),
                  episode: int.tryParse(_childText(body, 'episode') ?? ''),
                  rating: _childText(body, 'rating'),
                ),
              );
        }
      }

      i = xml.indexOf('<programme ', closeStart);
    }

    for (final list in byChannel.values) {
      list.sort((a, b) => a.start.compareTo(b.start));
    }
    return byChannel;
  }

  /// Reads `name="value"` from within a single open tag.
  static String? _attr(String s, int tagStart, int tagEnd, String name) {
    final needle = '$name="';
    final at = s.indexOf(needle, tagStart);
    if (at < 0 || at > tagEnd) return null;
    final valueStart = at + needle.length;
    final valueEnd = s.indexOf('"', valueStart);
    if (valueEnd < 0 || valueEnd > tagEnd) return null;
    return _unescape(s.substring(valueStart, valueEnd));
  }

  /// Text of the first `<tag>...</tag>` child, or null. Self-closing tags and
  /// longer tag names that merely share a prefix (`<season>` vs `<seasonfoo>`)
  /// are skipped rather than mismatched.
  static String? _childText(String body, String tag) {
    final open = '<$tag';
    var at = body.indexOf(open);
    while (at >= 0) {
      final after = at + open.length;
      if (after >= body.length) return null;
      final next = body[after];
      final isThisTag = next == '>' || next == ' ' || next == '/';
      final openEnd = body.indexOf('>', at);
      if (openEnd < 0) return null;

      if (isThisTag && body[openEnd - 1] != '/') {
        final closeAt = body.indexOf('</$tag>', openEnd);
        if (closeAt < 0) return null;
        final text = _unescape(body.substring(openEnd + 1, closeAt)).trim();
        return text.isEmpty ? null : text;
      }
      at = body.indexOf(open, openEnd);
    }
    return null;
  }

  /// `<icon src="..."/>` inside a programme body.
  static String? _iconSrc(String body) {
    final at = body.indexOf('<icon');
    if (at < 0) return null;
    final openEnd = body.indexOf('>', at);
    if (openEnd < 0) return null;
    final src = _attr(body, at, openEnd, 'src');
    return (src == null || src.isEmpty) ? null : src;
  }

  /// About 6% of the feed's image paths contain raw spaces
  /// (`.../767371_MINIATURE WIFE THE S01_2026_01.jpg`), which image loaders
  /// reject. encodeFull escapes those without touching already-encoded
  /// sequences or the URL's reserved punctuation.
  static String? _encodeUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    try {
      return Uri.encodeFull(url);
    } catch (_) {
      return url;
    }
  }

  /// Parses `20260904235500 +0200` into a *naive* SAST wall-clock DateTime,
  /// which is the convention every other DStv guide time in this app follows
  /// (see [DstvProgramme] and DstvEpgRepository.nowSast). The feed is all
  /// +0200 today, but the offset is honoured so a DST-style change or a
  /// re-published UTC feed would still land correctly.
  static DateTime? _parseTimeAsSast(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.length < 14) return null;

    final year = int.tryParse(s.substring(0, 4));
    final month = int.tryParse(s.substring(4, 6));
    final day = int.tryParse(s.substring(6, 8));
    final hour = int.tryParse(s.substring(8, 10));
    final minute = int.tryParse(s.substring(10, 12));
    final second = int.tryParse(s.substring(12, 14));
    if (year == null ||
        month == null ||
        day == null ||
        hour == null ||
        minute == null ||
        second == null) {
      return null;
    }

    var utc = DateTime.utc(year, month, day, hour, minute, second);

    final offset = s.length > 14 ? s.substring(14).trim() : '';
    if (offset.length >= 5 && (offset[0] == '+' || offset[0] == '-')) {
      final sign = offset[0] == '-' ? -1 : 1;
      final offHours = int.tryParse(offset.substring(1, 3)) ?? 0;
      final offMinutes = int.tryParse(offset.substring(3, 5)) ?? 0;
      utc = utc.subtract(
        Duration(hours: sign * offHours, minutes: sign * offMinutes),
      );
    }

    final sast = utc.add(const Duration(hours: 2));
    return DateTime(
      sast.year,
      sast.month,
      sast.day,
      sast.hour,
      sast.minute,
      sast.second,
    );
  }

  /// `&amp;` is resolved last so `&amp;lt;` stays the literal text `&lt;`
  /// instead of collapsing all the way to `<`.
  static String _unescape(String s) {
    if (!s.contains('&')) return s;
    var out = s
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'");
    if (out.contains('&#')) {
      out = out.replaceAllMapped(RegExp(r'&#(x?)([0-9a-fA-F]+);'), (m) {
        final code = int.tryParse(m[2]!, radix: m[1]!.isEmpty ? 10 : 16);
        return code == null ? m[0]! : String.fromCharCode(code);
      });
    }
    return out.replaceAll('&amp;', '&');
  }

  void close() => _dio.close();
}
