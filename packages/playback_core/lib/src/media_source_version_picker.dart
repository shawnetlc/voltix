/// Picks which version (MediaSource) of a title to play when a title has
/// several (e.g. a 2160p and a 1080p file) and the viewer did not choose one.
///
/// [maxHeight] is the viewer's maximum video resolution (1080 for "1080p");
/// 0 / null means no limit, and then the server's first version is kept.
/// The best version at or below the limit wins (highest resolution, then the
/// highest bitrate); when every version is above the limit, the smallest one.
class MediaSourceVersionPicker {
  MediaSourceVersionPicker._();

  /// The viewer's limit, set by the app from its playback settings.
  static int maxHeight = 0;

  /// Versions the server could not deliver (both stream addresses failed).
  /// They are hidden from the Versions list and never picked automatically.
  /// The app loads/saves this set (see [onUnplayableChanged]).
  static final Set<String> unplayable = <String>{};
  static void Function(Set<String> ids)? onUnplayableChanged;

  static bool isUnplayable(Object? id) =>
      id != null && unplayable.contains(id.toString());

  static void markUnplayable(String id) {
    if (id.isEmpty) return;
    if (unplayable.add(id)) onUnplayableChanged?.call(unplayable);
  }

  /// [sources] without the versions known not to play (all of them when every
  /// version is marked, so a title never ends up with nothing to try).
  static List<Map<String, dynamic>> playable(List<Map<String, dynamic>> sources) {
    final ok = sources.where((s) => !isUnplayable(s['Id'])).toList();
    return ok.isEmpty ? sources : ok;
  }

  /// Index of the version to use in [sources] (each a MediaSource JSON map).
  static int pickIndex(List<Map<String, dynamic>> sources, {int? limit}) {
    final max = limit ?? maxHeight;
    if (sources.length < 2) return 0;
    // 3D versions (side-by-side / over-under / MVC) are never chosen
    // automatically - only when the viewer picks one in Versions, or when
    // every version is 3D.
    final candidates = <int>[
      for (var i = 0; i < sources.length; i++)
        if (!is3D(sources[i]) && !isUnplayable(sources[i]['Id'])) i,
    ];
    if (candidates.isEmpty) return 0;
    if (max <= 0) return candidates.first;
    var best = -1;
    var bestTier = -1;
    var bestBitrate = -1;
    var smallest = 0;
    var smallestTier = 1 << 30;
    for (final i in candidates) {
      final tier = tierOf(sources[i]);
      final bitrate = (sources[i]['Bitrate'] as num?)?.toInt() ?? 0;
      if (tier > 0 && tier < smallestTier) {
        smallest = i;
        smallestTier = tier;
      }
      if (tier <= 0 || tier > max) continue;
      if (tier > bestTier || (tier == bestTier && bitrate > bestBitrate)) {
        best = i;
        bestTier = tier;
        bestBitrate = bitrate;
      }
    }
    if (best >= 0) return best;
    return smallestTier < (1 << 30) ? smallest : candidates.first;
  }

  static String? pickId(List<Map<String, dynamic>> sources, {int? limit}) {
    if (sources.isEmpty) return null;
    return sources[pickIndex(sources, limit: limit)]['Id']?.toString();
  }

  static final RegExp _threeDName = RegExp(
    r'(^|[^a-z0-9])(3d|sbs|h-?sbs|f-?sbs|half-?sbs|h-?ou|f-?ou|h-?tab|f-?tab|mvc)([^a-z0-9]|$)',
    caseSensitive: false,
  );

  /// A 3D version: Jellyfin's Video3DFormat on the version or its video
  /// stream, or a 3D marker in its name / file path (".3D.", "HSBS", "MVC"...).
  static bool is3D(Map<String, dynamic> source) {
    final fmt = source['Video3DFormat']?.toString() ?? '';
    if (fmt.isNotEmpty) return true;
    final streams = source['MediaStreams'];
    if (streams is List) {
      for (final s in streams) {
        if (s is Map && s['Type']?.toString() == 'Video') {
          if ((s['Video3DFormat']?.toString() ?? '').isNotEmpty) return true;
        }
      }
    }
    final path = source['Path']?.toString() ?? '';
    final file = path.split(RegExp(r'[\\/]')).last;
    return _threeDName.hasMatch(source['Name']?.toString() ?? '') ||
        _threeDName.hasMatch(file);
  }

  /// Resolution class of a version: 2160, 1440, 1080, 720, 480 or the raw
  /// height; 0 when unknown. Uses width too, so a 3840x1600 "scope" film counts
  /// as 2160p and 1920x800 as 1080p.
  static int tierOf(Map<String, dynamic> source) {
    final streams = source['MediaStreams'];
    if (streams is! List) return _tierFromName(source['Name']?.toString());
    for (final s in streams) {
      if (s is Map && s['Type']?.toString() == 'Video') {
        final w = (s['Width'] as num?)?.toInt() ?? 0;
        final h = (s['Height'] as num?)?.toInt() ?? 0;
        if (w >= 3200 || h >= 1700) return 2160;
        if (w >= 2400 || h >= 1300) return 1440;
        if (w >= 1700 || h >= 950) return 1080;
        if (w >= 1200 || h >= 650) return 720;
        if (h > 0) return h <= 576 ? 480 : h;
      }
    }
    return _tierFromName(source['Name']?.toString());
  }

  static int _tierFromName(String? name) {
    final n = (name ?? '').toLowerCase();
    if (n.contains('2160') || n.contains('4k') || n.contains('uhd')) return 2160;
    if (n.contains('1440')) return 1440;
    if (n.contains('1080')) return 1080;
    if (n.contains('720')) return 720;
    if (n.contains('480') || n.contains('576') || n.contains('sd')) return 480;
    return 0;
  }
}
