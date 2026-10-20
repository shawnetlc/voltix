/// Default audio-track choice when a title's main track is a "heavy" lossless
/// format TVs usually can't decode (TrueHD, DTS-HD, DTS, PCM Blu-ray): use a
/// track in the same language that every TV plays - AC3 (Dolby Digital) 5.1
/// first, then E-AC3 5.1+, then other AC3/E-AC3, then AAC.
class AudioTrackPreference {
  AudioTrackPreference._();

  static const heavyCodecs = {
    'truehd', 'mlp', 'dts', 'dca', 'dtshd', 'dts-hd', 'pcm_bluray',
  };
  static const lightCodecs = {
    'eac3', 'ac3', 'aac', 'mp3', 'opus', 'vorbis',
  };

  static String codecOf(Map<String, dynamic> s) =>
      (s['Codec']?.toString() ?? '').toLowerCase();

  static int channelsOf(Map<String, dynamic> s) =>
      (s['Channels'] as num?)?.toInt() ?? 0;

  static bool isHeavy(Map<String, dynamic> s) => heavyCodecs.contains(codecOf(s));

  /// Higher is better.
  static int rank(Map<String, dynamic> s) {
    final c = codecOf(s);
    final ch = channelsOf(s);
    if (c == 'ac3' && ch >= 6) return 100; // AC3 5.1
    if (c == 'eac3' && ch >= 6) return 90;
    if (c == 'ac3') return 80;
    if (c == 'eac3') return 70;
    if (c == 'aac' && ch >= 6) return 60;
    if (c == 'aac') return 50;
    if (lightCodecs.contains(c)) return 40;
    return 10;
  }

  static String _lang(Map<String, dynamic> s) =>
      (s['Language']?.toString() ?? '').toLowerCase();

  /// When [current] is a heavy track, the best light track in the same
  /// language (or with no language tag) from [audioStreams]; null otherwise.
  static Map<String, dynamic>? lighterAlternative(
    List<Map<String, dynamic>> audioStreams,
    Map<String, dynamic> current,
  ) {
    if (!isHeavy(current)) return null;
    final lang = _lang(current);
    final candidates = audioStreams.where((s) {
      if (!lightCodecs.contains(codecOf(s))) return false;
      final l = _lang(s);
      return lang.isEmpty || l.isEmpty || l == lang;
    }).toList()
      ..sort((a, b) {
        final r = rank(b).compareTo(rank(a));
        if (r != 0) return r;
        return channelsOf(b).compareTo(channelsOf(a));
      });
    return candidates.isEmpty ? null : candidates.first;
  }
}
