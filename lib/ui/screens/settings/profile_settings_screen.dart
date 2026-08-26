import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:jellyfin_preference/jellyfin_preference.dart';
import 'package:server_core/server_core.dart';
import 'package:voltix_design/voltix_design.dart';

import '../../../auth/models/user.dart';
import '../../../auth/repositories/user_repository.dart';
import '../../../auth/store/authentication_store.dart';
import '../../../auth/store/voltix_session_store.dart';
import '../../../data/services/voltix_api_service.dart';
import '../../../preference/user_preferences.dart';
import '../../../util/focus/dpad_keys.dart';
import '../../widgets/focus/request_initial_focus.dart';
import '../../widgets/settings/clean_settings_typography.dart';
import '../../widgets/settings/preference_tiles.dart';
import 'settings_app_bar.dart';

/// Lets the signed-in user manage the profile picture that shows up on the
/// "Switch user" screen, and review the details of their Voltix account.
///
/// The profile picture is stored on the media server (Jellyfin/Emby) as the
/// user's primary image. The Voltix account fields are read-only here because
/// the Voltix backend exposes no profile mutation; they are changed from the
/// Voltix website.
class ProfileSettingsScreen extends StatefulWidget {
  const ProfileSettingsScreen({super.key});

  @override
  State<ProfileSettingsScreen> createState() => _ProfileSettingsScreenState();
}

class _ProfileSettingsScreenState extends State<ProfileSettingsScreen> {
  final _userRepo = GetIt.instance<UserRepository>();
  final _authStore = GetIt.instance<AuthenticationStore>();
  final _voltixStore = GetIt.instance<VoltixSessionStore>();

  String? _userId;
  String? _serverId;
  String _userName = '';
  String? _imageTag;
  bool _busy = false;

  VoltixUser? _voltixUser;
  bool _voltixLoading = false;

  @override
  void initState() {
    super.initState();
    _loadServerUser();
    _loadVoltixAccount();
  }

  void _loadServerUser() {
    final user = _userRepo.currentUser;
    if (user == null) return;
    // Prefer the stored copy: that is the record the "Switch user" screen
    // reads its avatars from.
    final stored = _authStore.getUser(user.serverId, user.id);
    setState(() {
      _userId = user.id;
      _serverId = user.serverId;
      _userName = stored?.name ?? user.name;
      _imageTag = stored?.imageTag ?? user.imageTag;
    });
  }

  Future<void> _loadVoltixAccount() async {
    final token = _voltixStore.sessionToken;
    if (token == null || token.isEmpty) return;
    setState(() => _voltixLoading = true);
    try {
      final result = await GetIt.instance<VoltixApiService>()
          .validateSession(token);
      if (!mounted) return;
      setState(() {
        _voltixUser = result.user;
        _voltixLoading = false;
      });
    } catch (_) {
      // Offline or expired session: fall back to the locally cached fields.
      if (!mounted) return;
      setState(() => _voltixLoading = false);
    }
  }

  MediaServerClient? get _client {
    if (!GetIt.instance.isRegistered<MediaServerClient>()) return null;
    try {
      return GetIt.instance<MediaServerClient>();
    } catch (_) {
      return null;
    }
  }

  /// The profile picture lives on the media server, so it can only be changed
  /// while a real Jellyfin/Emby session is attached to this Voltix account.
  bool get _canEditPicture {
    if (_userId == null || _client == null) return false;
    return GetIt.instance<PreferenceStore>()
        .get(UserPreferences.voltixJellyfinEnabled);
  }

  String? get _avatarUrl {
    final userId = _userId;
    final tag = _imageTag;
    final client = _client;
    if (userId == null || tag == null || client == null) return null;
    return client.imageApi.getUserImageUrl(userId, tag: tag);
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _mimeTypeFor(String? extension) {
    return switch (extension?.toLowerCase()) {
      'png' => 'image/png',
      'webp' => 'image/webp',
      _ => 'image/jpeg',
    };
  }

  Future<void> _changePicture() async {
    final client = _client;
    final userId = _userId;
    if (client == null || userId == null) return;

    try {
      final result = await FilePicker.pickFiles(
        type: FileType.image,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null) {
        _showSnack('Could not read the selected image');
        return;
      }

      if (!mounted) return;
      setState(() => _busy = true);
      await client.usersApi.uploadUserImage(
        userId,
        bytes: bytes,
        contentType: _mimeTypeFor(file.extension),
      );
      await _refreshImageTag();
      _showSnack('Profile picture updated');
    } catch (e) {
      _showSnack('Could not update profile picture: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removePicture() async {
    final client = _client;
    final userId = _userId;
    if (client == null || userId == null) return;

    setState(() => _busy = true);
    try {
      await client.usersApi.deleteUserImage(userId);
      await _refreshImageTag();
      _showSnack('Profile picture removed');
    } catch (e) {
      _showSnack('Could not remove profile picture: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Re-reads the primary image tag from the server and writes it back to the
  /// authentication store (and the in-memory current user) so the "Switch user"
  /// screen — which builds its avatar URLs from the stored tag — picks up the
  /// new picture and busts its image cache.
  Future<void> _refreshImageTag() async {
    final client = _client;
    final userId = _userId;
    final serverId = _serverId;
    if (client == null || userId == null || serverId == null) return;

    String? tag;
    try {
      final serverUser = await client.usersApi.getCurrentUser();
      tag = serverUser.primaryImageTag;
    } catch (_) {
      // Keep going: even without a fresh tag the store must not go stale.
    }

    final stored = _authStore.getUser(serverId, userId);
    if (stored != null) {
      final updated = PrivateUser(
        id: stored.id,
        name: stored.name,
        serverId: stored.serverId,
        accessToken: stored.accessToken,
        lastUsed: stored.lastUsed,
        imageTag: tag,
        isAdministrator: stored.isAdministrator,
        canDownload: stored.canDownload,
        canManageSubtitles: stored.canManageSubtitles,
        canManageCollections: stored.canManageCollections,
      );
      await _authStore.putUser(updated);
      _userRepo.setCurrentUser(updated);
    }

    if (!mounted) return;
    setState(() => _imageTag = tag);
  }

  @override
  Widget build(BuildContext context) {
    return RequestInitialFocus(
      child: withCleanSettingsTypography(
        context,
        Scaffold(
          appBar: buildSettingsAppBar(context, const Text('Profile settings')),
          body: _buildBody(context),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_userId == null && !_voltixStore.hasSession) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Sign in to manage your profile.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView(
      children: [
        _buildHeader(context),
        const _Section(title: 'Profile picture'),
        _ActionTile(
          icon: Icons.photo_camera,
          title: 'Change profile picture',
          subtitle: _canEditPicture
              ? 'Pick an image from this device. It shows on the Switch user '
                  'screen.'
              : 'Not available without an active media server session.',
          enabled: _canEditPicture && !_busy,
          trailing: _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
          onTap: _changePicture,
        ),
        _ActionTile(
          icon: Icons.no_photography,
          title: 'Remove profile picture',
          subtitle: _imageTag == null
              ? 'No profile picture is set.'
              : 'Go back to the default initial avatar.',
          enabled: _canEditPicture && _imageTag != null && !_busy,
          destructive: true,
          onTap: _removePicture,
        ),
        const _Section(title: 'Voltix account'),
        if (_voltixLoading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        _InfoTile(
          icon: Icons.badge,
          label: 'Username',
          value: _voltixUser?.username ?? _voltixStore.username,
        ),
        _InfoTile(
          icon: Icons.person,
          label: 'Display name',
          value: _voltixUser?.displayName ?? _voltixStore.displayName,
        ),
        _InfoTile(
          icon: Icons.email,
          label: 'Email',
          value: _voltixUser?.email,
        ),
        _InfoTile(
          icon: Icons.devices,
          label: 'Simultaneous streams',
          value: _voltixUser?.maxConcurrentDevices.toString(),
        ),
        _InfoTile(
          icon: Icons.dns,
          label: 'Active server',
          value: _voltixStore.activeServerName,
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 32),
          child: Text(
            'Your Voltix username, display name and email are managed by your '
            'Voltix subscription and can only be changed from the Voltix '
            'website.',
            style: TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    final url = _avatarUrl;
    final displayName = _voltixUser?.displayName ?? _voltixStore.displayName;
    final initial = _userName.isNotEmpty
        ? _userName.characters.first.toUpperCase()
        : '?';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Row(
        children: [
          CircleAvatar(
            radius: 40,
            backgroundColor: AppColorScheme.accent.withValues(alpha: 0.2),
            backgroundImage: url == null ? null : NetworkImage(url),
            child: url == null
                ? Text(
                    initial,
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w600,
                      color: AppColorScheme.accent,
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _userName.isEmpty ? (displayName ?? 'Profile') : _userName,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (displayName != null && displayName != _userName)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      displayName,
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColorScheme.onSurface
                            .withValues(alpha: 0.7),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: AppColorScheme.accent,
        ),
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final hasValue = value != null && value!.isNotEmpty;
    return ListTile(
      leading: Icon(icon, color: AppColorScheme.accent),
      title: Text(
        label,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        hasValue ? value! : 'Not set',
        style: TextStyle(
          fontSize: 12,
          color: AppColorScheme.onSurface
              .withValues(alpha: hasValue ? 0.7 : 0.38),
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
    this.enabled = true,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? trailing;
  final bool enabled;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final accent =
        destructive ? AppColorScheme.statusRequested : AppColorScheme.accent;

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) {
        if (!event.logicalKey.isSelectKey) return KeyEventResult.ignored;
        if (event is KeyDownEvent && enabled) onTap();
        return KeyEventResult.handled;
      },
      child: TvFocusHighlight(
        builder: (context, focused) {
          final foreground = !enabled
              ? AppColorScheme.onSurface.withValues(alpha: 0.38)
              : focused
                  ? AppColors.black.withValues(alpha: 0.87)
                  : (destructive ? accent : AppColorScheme.onSurface);
          final iconColor = !enabled
              ? AppColorScheme.onSurface.withValues(alpha: 0.38)
              : focused
                  ? AppColors.black.withValues(alpha: 0.7)
                  : accent;

          return ListTile(
            enabled: enabled,
            focusColor: Colors.transparent,
            hoverColor: Colors.transparent,
            leading: Icon(icon, color: iconColor),
            title: Text(
              title,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: foreground,
              ),
            ),
            subtitle: Text(
              subtitle,
              style: TextStyle(
                fontSize: 12,
                color: foreground.withValues(alpha: 0.7),
              ),
            ),
            trailing: trailing,
            onTap: enabled ? onTap : null,
          );
        },
      ),
    );
  }
}
