/// Neutral display text for a Jellyfin participant whose Voltix name is not
/// known yet.
///
/// Jellyfin reports SyncPlay participants under their provisioned upstream
/// account names (`lumistream_ab12`, per-tier accounts, pooled accounts). Those
/// should never reach the UI. Real names come from the backend via
/// `SyncPlayUsernameResolver`; this is only the stand-in for the window before
/// that resolves, or when the backend has no match.
///
/// A previous version of this file tried to derive the real name locally and
/// could not: it treated any name starting with `lumistream`/`jellyfin`/
/// `admin_`/`user_` as the local user and returned *their* Voltix name. Since
/// that prefix is the shape of everyone's Jellyfin account, a group of four
/// people rendered as the same person four times. Identity resolution is a
/// backend concern - do not reintroduce prefix guessing here.
String syncPlayNamePlaceholder(String jellyfinUsername) {
  final clean = jellyfinUsername.trim();
  if (clean.isEmpty) return 'Voltix User';

  final lower = clean.toLowerCase();
  for (final prefix in const ['lumistream_', 'jellyfin_', 'voltix_']) {
    if (lower.startsWith(prefix)) {
      final suffix = clean.substring(prefix.length).trim();
      // Keep the suffix so two pending participants stay visibly distinct.
      return suffix.isEmpty ? 'Voltix User' : 'Voltix User ($suffix)';
    }
  }
  if (lower == 'lumistream' || lower == 'jellyfin') return 'Voltix User';

  return clean;
}
