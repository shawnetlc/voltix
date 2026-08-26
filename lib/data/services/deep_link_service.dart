import 'dart:async';

import 'package:app_links/app_links.dart';

import '../../util/platform_detection.dart';

/// Routes OS-registered `voltix://` deep links into the app. tvOS, Tizen and
/// web are gated off, they have no app_links backend.
class DeepLinkService {
  StreamSubscription<Uri>? _subscription;

  static bool get _enabled =>
      !PlatformDetection.isWeb &&
      !PlatformDetection.isTizen &&
      !PlatformDetection.isAppleTV;

  /// Starts listening for `voltix://` links, including the one the app was
  /// launched with. [onRoute] receives an in-app route path.
  void startListener(void Function(String route) onRoute) {
    if (!_enabled) return;
    _subscription?.cancel();
    // uriLinkStream replays the launch link before live ones, so this is both
    // the cold-start and the warm path.
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

  /// Resolves a `voltix://` deep link into an in-app route path, or null if
  /// the link isn't recognized.
  ///
  /// Recognized forms:
  ///  - `voltix://item?id=<itemId>[&serverId=<serverId>]`
  ///  - `voltix://play?id=<itemId>[&serverId=<serverId>]` (starts playback)
  static String? routeForDeepLink(Uri uri) {
    if (uri.scheme != 'voltix') return null;
    final id = uri.queryParameters['id'];
    if (id == null || id.isEmpty) return null;
    final serverId = uri.queryParameters['serverId'];
    final params = <String, String>{
      if (serverId != null && serverId.isNotEmpty) 'serverId': serverId,
      if (uri.host == 'play') 'autoPlay': 'true',
    };
    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return query.isEmpty ? '/item/$id' : '/item/$id?$query';
  }
}
