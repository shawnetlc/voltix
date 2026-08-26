/// Shared (multi-tenant) streaming server detection.
///
/// Voltix Extra and 4K are shared Lumistream accounts: every Voltix user
/// streams through the same Jellyfin user, so that server's own watch state
/// (Continue Watching, Next Up, played flags) belongs to *everybody*. Anything
/// user-specific for those servers must come from the per-user
/// `VoltixWatchRegistryService` instead of the server.
///
/// Kept in one place so the rule cannot drift between the repository, the
/// player service and the taste quiz.
library;

/// True when the server name or address identifies a shared Extra / 4K server.
bool isSharedServerIdentity(String? nameOrUrl) {
  if (nameOrUrl == null || nameOrUrl.isEmpty) return false;
  final lower = nameOrUrl.toLowerCase();
  return lower.contains('extra') ||
      lower.contains('4k') ||
      lower.contains('4 k') ||
      lower.contains('extra.lumistream.cc') ||
      lower.contains('4k.lumistream.cc');
}

/// True when either the server name or its address marks it as shared.
bool isSharedServer({String? name, String? address}) =>
    isSharedServerIdentity(name) || isSharedServerIdentity(address);
