import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/models/voltix_profile.dart';

/// Persists the Voltix session state locally so the app can restore
/// the user's authenticated session across cold starts.
///
/// Uses [FlutterSecureStorage] (Android Keystore / iOS Keychain) to encrypt
/// the session token at rest. Non-sensitive fields (username, server info)
/// remain in SharedPreferences for performance.
///
/// On first launch after upgrade, any existing unencrypted token is
/// automatically migrated to secure storage and removed from SharedPreferences.
class VoltixSessionStore {
  // Secure storage key for the session token
  static const _secureKeyToken = 'voltix_session_token_secure';

  // SharedPreferences keys for non-sensitive data
  static const _keyToken = 'voltix_session_token'; // Legacy — migrated to secure
  static const _keyUserId = 'voltix_user_id';
  static const _keyUsername = 'voltix_username';
  static const _keyDisplayName = 'voltix_display_name';
  static const _keyActiveServerId = 'voltix_active_server_id';
  static const _keyActiveServerName = 'voltix_active_server_name';
  static const _keyActiveServerProxyUrl = 'voltix_active_server_proxy_url';
  static const _keyServersJson = 'voltix_servers_json';
  static const _keyIsAdmin = 'voltix_is_admin';
  static const _keyActiveProfileId = 'voltix_active_profile_id';
  static const _keyActiveProfileName = 'voltix_active_profile_name';
  static const _keyIsKidsProfile = 'voltix_is_kids_profile';

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  bool _secureStorageAvailable = true;

  String? _sessionToken;
  int? _userId;
  String? _username;
  String? _displayName;
  int? _activeServerId;
  String? _activeServerName;
  String? _activeServerProxyUrl;
  bool _isAdmin = false;
  int? _activeProfileId;
  String? _activeProfileName;
  bool _isKidsProfile = false;

  String? get sessionToken => _sessionToken;
  int? get userId => _userId;
  String? get username => _username;
  String? get displayName => _displayName;
  int? get activeServerId => _activeServerId;
  String? get activeServerName => _activeServerName;
  String? get activeServerProxyUrl => _activeServerProxyUrl;
  bool get isAdmin => _isAdmin;
  int? get activeProfileId => _activeProfileId;
  String? get activeProfileName => _activeProfileName;
  /// Whether the currently active profile is a Kids profile.
  bool get isKidsProfile => _isKidsProfile;
  bool get hasSession => _sessionToken != null && _sessionToken!.isNotEmpty;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    // Load non-sensitive fields from SharedPreferences
    _userId = prefs.getInt(_keyUserId);
    _username = prefs.getString(_keyUsername);
    _displayName = prefs.getString(_keyDisplayName);
    _activeServerId = prefs.getInt(_keyActiveServerId);
    _activeServerName = prefs.getString(_keyActiveServerName);
    _activeServerProxyUrl = prefs.getString(_keyActiveServerProxyUrl);
    _isAdmin = prefs.getBool(_keyIsAdmin) ?? false;
    _activeProfileId = prefs.getInt(_keyActiveProfileId);
    _activeProfileName = prefs.getString(_keyActiveProfileName);
    _isKidsProfile = prefs.getBool(_keyIsKidsProfile) ?? false;

    // Load token from secure storage
    _sessionToken = await _readSecureToken();

    // Migrate legacy unencrypted token if present
    if (_sessionToken == null || _sessionToken!.isEmpty) {
      final legacyToken = prefs.getString(_keyToken);
      if (legacyToken != null && legacyToken.isNotEmpty) {
        debugPrint('[VoltixSession] Migrating token to secure storage');
        _sessionToken = legacyToken;
        await _writeSecureToken(legacyToken);
        await prefs.remove(_keyToken);
      }
    }
  }

  Future<void> save({
    required String sessionToken,
    required int userId,
    required String username,
    String? displayName,
    required int activeServerId,
    required String activeServerName,
    required String activeServerProxyUrl,
    bool isAdmin = false,
  }) async {
    _sessionToken = sessionToken;
    _userId = userId;
    _username = username;
    _displayName = displayName;
    _activeServerId = activeServerId;
    _activeServerName = activeServerName;
    _activeServerProxyUrl = activeServerProxyUrl;
    _isAdmin = isAdmin;

    // Save token to secure storage
    await _writeSecureToken(sessionToken);

    // Save non-sensitive fields to SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyUserId, userId);
    await prefs.setString(_keyUsername, username);
    if (displayName != null) {
      await prefs.setString(_keyDisplayName, displayName);
    }
    await prefs.setInt(_keyActiveServerId, activeServerId);
    await prefs.setString(_keyActiveServerName, activeServerName);
    await prefs.setString(_keyActiveServerProxyUrl, activeServerProxyUrl);
    await prefs.setBool(_keyIsAdmin, isAdmin);

    // Ensure legacy key is removed (migration complete)
    await prefs.remove(_keyToken);
  }

  Future<void> setActiveProfile(VoltixProfile profile) async {
    _activeProfileId = profile.id;
    _activeProfileName = profile.name;
    _isKidsProfile = profile.isKids;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyActiveProfileId, profile.id);
    await prefs.setString(_keyActiveProfileName, profile.name);
    await prefs.setBool(_keyIsKidsProfile, profile.isKids);
  }

  Future<void> clearActiveProfile() async {
    _activeProfileId = null;
    _activeProfileName = null;
    _isKidsProfile = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyActiveProfileId);
    await prefs.remove(_keyActiveProfileName);
    await prefs.remove(_keyIsKidsProfile);
  }

  Future<void> clear() async {
    _sessionToken = null;
    _userId = null;
    _username = null;
    _displayName = null;
    _activeServerId = null;
    _activeServerName = null;
    _activeServerProxyUrl = null;
    _isAdmin = false;
    _activeProfileId = null;
    _activeProfileName = null;
    _isKidsProfile = false;

    // Clear secure token
    await _deleteSecureToken();

    // Clear SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyToken); // Legacy key
    await prefs.remove(_keyUserId);
    await prefs.remove(_keyUsername);
    await prefs.remove(_keyDisplayName);
    await prefs.remove(_keyActiveServerId);
    await prefs.remove(_keyActiveServerName);
    await prefs.remove(_keyActiveServerProxyUrl);
    await prefs.remove(_keyServersJson);
    await prefs.remove(_keyIsAdmin);
    await prefs.remove(_keyActiveProfileId);
    await prefs.remove(_keyActiveProfileName);
    await prefs.remove(_keyIsKidsProfile);
  }

  // ─── Secure storage helpers ──────────────────────────────────────────────────

  Future<String?> _readSecureToken() async {
    if (!_secureStorageAvailable) return null;
    try {
      return await _secureStorage.read(key: _secureKeyToken);
    } on PlatformException catch (e) {
      debugPrint('[VoltixSession] Secure storage read failed: $e');
      _secureStorageAvailable = false;
      // Fall back to SharedPreferences token
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_keyToken);
    }
  }

  Future<void> _writeSecureToken(String token) async {
    if (!_secureStorageAvailable) {
      // Fallback: write to SharedPreferences if secure storage is broken
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyToken, token);
      return;
    }
    try {
      await _secureStorage.write(key: _secureKeyToken, value: token);
    } on PlatformException catch (e) {
      debugPrint('[VoltixSession] Secure storage write failed: $e');
      _secureStorageAvailable = false;
      // Fallback to SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyToken, token);
    }
  }

  Future<void> _deleteSecureToken() async {
    try {
      await _secureStorage.delete(key: _secureKeyToken);
    } on PlatformException catch (e) {
      debugPrint('[VoltixSession] Secure storage delete failed: $e');
    }
  }
}
