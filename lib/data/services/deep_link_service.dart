import 'dart:async';

import 'package:app_links/app_links.dart';

import '../../util/platform_detection.dart';

/// Routes links opened outside the app into a screen inside it.
///
/// ─── Two link shapes, and why both ───────────────────────────────────────────
///
///   voltix://item?id=…            the app's own scheme
///   https://voltixstudio.com/…    an Android App Link / iOS Universal Link
///
/// The custom scheme is the simpler of the two and needs nothing but a manifest
/// entry. It is also close to useless for what these are actually for — telling
/// people a film has landed — because WhatsApp, SMS clients and most mail apps
/// only turn `http(s)` into something tappable. A `voltix://` URL arrives as
/// plain grey text nobody can click.
///
/// So the https form is the one to put in a broadcast: it opens the app when it
/// is installed and falls back to the website when it is not, which is what
/// people expect a link to do. The custom scheme stays supported for in-app use
/// and QR codes.
///
/// ─── Recognised links ────────────────────────────────────────────────────────
///
/// ```
/// voltix://item?id=<itemId>[&serverId=…]      open a film or show
/// voltix://play?id=<itemId>[&serverId=…]      open it and start playing
/// voltix://channel?id=<channelId>             open a Live TV channel
/// voltix://search?q=<text>                    open search for a term
///
/// https://voltixstudio.com/watch/<itemId>[?autoPlay=1&serverId=…]
/// https://voltixstudio.com/live/<channelId>
/// ```
///
/// Anything unrecognised returns null and is ignored, so a stray link cannot
/// send the app somewhere meaningless.
class DeepLinkService {
  StreamSubscription<Uri>? _subscription;

  /// Hosts whose https links belong to this app.
  ///
  /// A link from any other host is ignored outright. The manifest should never
  /// hand us one, but a link handler that acts on whatever arrives is a bad
  /// thing to have in an app that can start playback.
  static const _appLinkHosts = {'voltixstudio.com', 'www.voltixstudio.com'};

  static bool get _enabled =>
      !PlatformDetection.isWeb &&
      !PlatformDetection.isTizen &&
      !PlatformDetection.isAppleTV;

  /// Starts listening for deep links, including the one the app was launched
  /// with. [onRoute] receives an in-app route path.
  void startListener(void Function(String route) onRoute) {
    if (!_enabled) return;
    _subscription?.cancel();
    // uriLinkStream replays the launch link before live ones, so this covers
    // both the cold start and a link arriving while the app is already open.
    _subscription = AppLinks().uriLinkStream.listen(
      (uri) {
        final route = routeForDeepLink(uri);
        if (route != null) onRoute(route);
      },
      onError: (_) {},
    );
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }

  /// Resolves a deep link into an in-app route path, or null if it is not ours.
  static String? routeForDeepLink(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'voltix') return _fromCustomScheme(uri);
    if (scheme == 'https' || scheme == 'http') return _fromWebLink(uri);
    return null;
  }

  // ── voltix://<action>?id=… ─────────────────────────────────────────────────

  static String? _fromCustomScheme(Uri uri) {
    final action = uri.host.toLowerCase();

    if (action == 'search') {
      final query = uri.queryParameters['q'] ?? uri.queryParameters['query'];
      if (query == null || query.trim().isEmpty) return null;
      return '/search?query=${Uri.encodeComponent(query.trim())}';
    }

    // The id may be a query parameter or the first path segment, so both
    // `voltix://item?id=X` and `voltix://item/X` work. People hand-write these.
    final id = _firstNonEmpty([
      uri.queryParameters['id'],
      uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null,
    ]);

    if (action == 'channel' || action == 'live' || action == 'livetv') {
      // A channel may be named instead of numbered — that is how programme
      // reminders address one, because stream ids do not survive a provider
      // re-import and names do.
      final name = uri.queryParameters['name'] ?? uri.queryParameters['channelName'];
      if (id == null && (name == null || name.trim().isEmpty)) return null;
      return _channelRoute(id ?? '', channelName: name?.trim());
    }

    if (id == null) return null;
    if (action == 'item' || action == 'play' || action == 'watch') {
      return _itemRoute(
        id,
        serverId: uri.queryParameters['serverId'],
        autoPlay: action == 'play' || _isTruthy(uri.queryParameters['autoPlay']),
      );
    }
    return null;
  }

  // ── https://voltixstudio.com/watch/<id> ───────────────────────────────────

  static String? _fromWebLink(Uri uri) {
    if (!_appLinkHosts.contains(uri.host.toLowerCase())) return null;

    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length < 2) return null;

    final kind = segments[0].toLowerCase();
    final id = segments[1];
    if (id.isEmpty) return null;

    if (kind == 'live' || kind == 'channel') return _channelRoute(id);
    if (kind == 'watch' || kind == 'item') {
      return _itemRoute(
        id,
        serverId: uri.queryParameters['serverId'],
        autoPlay: _isTruthy(uri.queryParameters['autoPlay']),
      );
    }
    return null;
  }

  // ── Route building ────────────────────────────────────────────────────────

  static String _itemRoute(
    String id, {
    String? serverId,
    bool autoPlay = false,
  }) {
    final params = <String>[
      if (serverId != null && serverId.isNotEmpty)
        'serverId=${Uri.encodeQueryComponent(serverId)}',
      if (autoPlay) 'autoPlay=true',
    ];
    final base = '/item/${Uri.encodeComponent(id)}';
    return params.isEmpty ? base : '$base?${params.join('&')}';
  }

  /// A Live TV channel link opens the VOLTIX player, not the Jellyfin one.
  ///
  /// `/live-tv/player` is the Jellyfin player and takes a Jellyfin item id;
  /// `/live-tv/iptv` is the Voltix one and takes an Xtream stream id or a
  /// channel name. This pointed at the former, which meant every channel deep
  /// link — and every tapped programme reminder — landed on "Unable to open
  /// channel". The two routes take different kinds of id, so sending one to the
  /// other cannot work.
  ///
  /// Both spellings are accepted because both are useful: a stream id is exact,
  /// a name survives a provider re-importing its line-up and reissuing every id.
  static String _channelRoute(String channelId, {String? channelName}) {
    final params = <String>[
      if (channelId.isNotEmpty) 'streamId=${Uri.encodeQueryComponent(channelId)}',
      if (channelName != null && channelName.isNotEmpty)
        'channelName=${Uri.encodeQueryComponent(channelName)}',
    ];
    return '/live-tv/iptv?${params.join('&')}';
  }

  static String? _firstNonEmpty(List<String?> candidates) {
    for (final candidate in candidates) {
      if (candidate != null && candidate.trim().isNotEmpty) {
        return candidate.trim();
      }
    }
    return null;
  }

  /// Accepts the several things a hand-written link might say for "yes".
  static bool _isTruthy(String? value) {
    if (value == null) return false;
    final v = value.trim().toLowerCase();
    return v == '1' || v == 'true' || v == 'yes';
  }
}
