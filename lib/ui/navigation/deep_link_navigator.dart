import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../auth/repositories/session_repository.dart';
import 'app_router.dart';
import 'destinations.dart';

/// Whether [target] is an external URI (http, https, market, intent, mailto, tel).
bool isExternalUrl(String target) {
  final lower = target.trim().toLowerCase();
  return lower.startsWith('http://') ||
      lower.startsWith('https://') ||
      lower.startsWith('market://') ||
      lower.startsWith('intent://') ||
      lower.startsWith('mailto:') ||
      lower.startsWith('tel:');
}

/// Safely dispatches a target route or external URL.
///
/// If [target] is an external URL (e.g. Play Store, web link), it opens the
/// system browser or Google Play app via [launchUrl].
///
/// If [target] is an in-app route, it uses [GoRouter] to navigate internally.
Future<void> navigateOrLaunchUrl(String target, {BuildContext? context}) async {
  final clean = target.trim();
  if (clean.isEmpty) return;

  if (isExternalUrl(clean)) {
    try {
      final uri = Uri.parse(clean);
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) {
        await launchUrl(uri);
      }
      return;
    } catch (e) {
      debugPrint('navigateOrLaunchUrl: Failed to launch external URL $clean: $e');
      return;
    }
  }

  try {
    if (context != null && context.mounted) {
      GoRouter.of(context).go(clean);
    } else {
      appRouter.go(clean);
    }
  } catch (e) {
    debugPrint('navigateOrLaunchUrl: Failed to navigate to route $clean: $e');
  }
}

/// Routes a launch or deep-link path, holding it back past the cold-start auth
/// window so the router's redirect doesn't swallow it. When the session is
/// already authenticated this navigates right away, the warm path from any
/// screen. Otherwise it waits for the first moment the app is authenticated and
/// settled on Home.
///
/// If [route] is an external URL, it launches immediately without waiting for auth.
void navigateWhenReady(String route) {
  if (isExternalUrl(route)) {
    unawaited(navigateOrLaunchUrl(route));
    return;
  }

  if (_isAuthenticated()) {
    appRouter.go(route);
    return;
  }

  var done = false;
  late final VoidCallback listener;
  void finish({required bool navigate}) {
    if (done) return;
    done = true;
    appRouter.routerDelegate.removeListener(listener);
    // Defer off the router-notification call stack. The listener fires
    // synchronously inside the startup navigation to Home (the delegate
    // notifies its listeners during go()), and navigating re-entrantly there
    // would fight go_router mid-transition. A post-frame hop lets Home settle.
    if (navigate) {
      WidgetsBinding.instance.addPostFrameCallback((_) => appRouter.go(route));
    }
  }

  listener = () {
    if (_isAuthenticated() && _currentPath() == Destinations.home) {
      finish(navigate: true);
    }
  };
  appRouter.routerDelegate.addListener(listener);

  // Detach only, never an early drop. This survives long PIN, login, and
  // server-select cold starts, and can't leak a listener if auth never lands.
  Timer(const Duration(minutes: 5), () => finish(navigate: false));
}

bool _isAuthenticated() =>
    GetIt.instance.isRegistered<SessionRepository>() &&
    GetIt.instance<SessionRepository>().activeUserId != null;

String? _currentPath() {
  try {
    return appRouter.routerDelegate.currentConfiguration.uri.path;
  } catch (_) {
    return null;
  }
}
