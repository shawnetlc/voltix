import 'dart:io';

String osVersionRaw() => Platform.operatingSystemVersion;

int osMajorVersion() {
  final match = RegExp(r'\d+').firstMatch(Platform.operatingSystemVersion);
  if (match == null) return 0;
  return int.tryParse(match.group(0)!) ?? 0;
}

bool detectTizenRuntime() {
  if (!Platform.isLinux) return false;
  try {
    return File('/etc/tizen-release').existsSync() ||
        Directory('/opt/usr/apps').existsSync() ||
        Directory('/opt/share').existsSync() ||
        Platform.environment.containsKey('AUL_APP_ID') ||
        Platform.environment.containsKey('TIZEN_APP_ID') ||
        Platform.operatingSystemVersion.toLowerCase().contains('tizen');
  } catch (_) {
    return false;
  }
}
