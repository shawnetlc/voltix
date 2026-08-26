import 'package:window_manager/window_manager.dart';

import 'platform_detection.dart';

bool _isFullscreen = false;
bool _wasMaximized = false;

Future<bool> isFullscreen() async {
  if (!PlatformDetection.isDesktop) return false;
  return _isFullscreen;
}

Future<void> setFullscreen(bool value) async {
  if (!PlatformDetection.isDesktop) return;
  if (value == _isFullscreen) return;
  try {
    if (value) {
      _wasMaximized = await windowManager.isMaximized();
      if (_wasMaximized) {
        // If maximized, we must unmaximize/restore first to avoid title bar remaining visible
        await windowManager.unmaximize();
      }
      await windowManager.setFullScreen(true);
      _isFullscreen = true;
    } else {
      await windowManager.setFullScreen(false);
      _isFullscreen = false;
      if (_wasMaximized) {
        await windowManager.maximize();
        _wasMaximized = false;
      }
    }
  } catch (_) {}
}
