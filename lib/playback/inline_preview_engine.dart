import '../preference/preference_constants.dart';
import '../preference/user_preferences.dart';
import '../util/platform_detection.dart';

bool usesMedia3ForInlinePreview(UserPreferences prefs) {
  return PlatformDetection.isAndroid &&
      PlatformDetection.isTV &&
      prefs.get(UserPreferences.playbackEnginePreference) ==
          PlaybackEnginePreference.media3;
}
