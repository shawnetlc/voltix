/// Recovery hook for a media-server token the server no longer accepts.
///
/// A Voltix session holds one media-server token per server, and those can be
/// invalidated underneath a running app: the server restarts, an admin revokes
/// the device, or a second sign-in terminates the session row the token lived
/// in. The app finds out the same way every time -- a 401 on the next request.
///
/// Until now that was terminal outside of login. [SessionRepository] re-mints a
/// token from the stored Voltix JWT when getCurrentUser 401s during
/// switchCurrentSession, but nothing did so afterwards, so a token that died
/// while the app sat on the home screen left every subsequent request failing
/// until the app was restarted. Production logs show precisely that: one server
/// answering 401 to UserViews, Items, Resume, NextUp, Users/Me and the plugin
/// probe alike, while its sibling servers answered 200 throughout, and while
/// the Voltix session those servers share stayed perfectly valid.
///
/// The client packages cannot reach the Voltix session store themselves --
/// server_core knows nothing about Voltix -- so the app installs a handler here
/// at startup and the clients call it when they see a 401.
class ServerAuthRecovery {
  const ServerAuthRecovery._();

  /// Mints a fresh access token for the server at [baseUrl], or returns null
  /// when it cannot -- an invalid Voltix session, no stored credentials, or a
  /// server that is genuinely refusing this account.
  ///
  /// Returning null is not a failure to handle; it means "this 401 is real",
  /// and the caller surfaces it as it always did.
  static Future<String?> Function(String baseUrl)? handler;

  /// Whether a recovery attempt is worth making at all.
  static bool get isConfigured => handler != null;
}
