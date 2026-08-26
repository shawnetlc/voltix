import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Client-side group passwords for SyncPlay.
///
/// Jellyfin has no notion of a SyncPlay password. `NewGroupRequestDto` carries
/// only `GroupName` and `JoinGroupRequestDto` only `GroupId`, so the `Password`
/// this app used to post was accepted by the HTTP layer and dropped by the model
/// binder. Groups created "with a password" were open to everyone, the list
/// never showed a lock because the server never returns `HasPassword`, and the
/// join dialog therefore never appeared. The feature looked implemented and did
/// nothing.
///
/// The password is carried instead in the one field the server does persist and
/// echo to every client: the group name. A protected group is stored as
///
///     Movie Night ::vpw:9f2c1ab34de5
///
/// where the suffix is a truncated SHA-256 of the normalised name and the
/// password. Every Voltix client can see that a group is protected and can check
/// a typed password locally before calling Join. The marker is stripped before
/// the name is shown anywhere.
///
/// This is enforcement, not security. The plaintext never leaves the device and
/// the digest is salted with the group name, so a password cannot be read back
/// out of the group list - but a modified client, or the Jellyfin web UI, can
/// still POST /SyncPlay/Join directly and get in. Anything stronger has to be
/// enforced by the server, and Jellyfin has nowhere to put it.
class SyncPlayGroupPassword {
  const SyncPlayGroupPassword._();

  static const String _marker = ' ::vpw:';
  static const int _digestLength = 12;
  static final RegExp _hex = RegExp(r'^[0-9a-f]+$');

  /// The name to send to the server. Unprotected names are returned untouched.
  static String encodeName(String name, String? password) {
    final trimmedName = name.trim();
    final trimmedPassword = password?.trim() ?? '';
    if (trimmedPassword.isEmpty) return trimmedName;
    return '$trimmedName$_marker${_digest(trimmedName, trimmedPassword)}';
  }

  /// Whether [rawName] carries a password marker.
  static bool isProtected(String? rawName) => _markerOf(rawName) != null;

  /// The name to show a user, with any marker removed.
  static String displayName(String? rawName) {
    if (rawName == null) return '';
    if (_markerOf(rawName) == null) return rawName;
    return rawName.substring(0, rawName.lastIndexOf(_marker));
  }

  /// Whether [password] opens [rawName]. Unprotected groups always open, so this
  /// can be called unconditionally on the join path.
  static bool matches(String? rawName, String? password) {
    final marker = _markerOf(rawName);
    if (marker == null) return true;
    final candidate = password?.trim() ?? '';
    if (candidate.isEmpty) return false;
    return _digest(displayName(rawName), candidate) == marker;
  }

  static String _digest(String name, String password) {
    final salted = 'voltix-syncplay:v1:${name.trim().toLowerCase()}:$password';
    return sha256.convert(utf8.encode(salted)).toString().substring(
          0,
          _digestLength,
        );
  }

  /// The digest embedded in [rawName], or null when there is not a well-formed
  /// one. Deliberately strict: a group genuinely named "Movie ::vpw:tonight"
  /// must not be treated as protected, because nobody could ever open it.
  static String? _markerOf(String? rawName) {
    if (rawName == null) return null;
    final index = rawName.lastIndexOf(_marker);
    if (index < 0) return null;
    final digest = rawName.substring(index + _marker.length);
    if (digest.length != _digestLength) return null;
    return _hex.hasMatch(digest) ? digest : null;
  }
}
