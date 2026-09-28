import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:get_it/get_it.dart';
import '../../../auth/store/voltix_session_store.dart';
import '../../../data/models/voltix_profile.dart';
import '../../../data/repositories/voltix_profile_repository.dart';
import 'package:voltix_design/voltix_design.dart';
import '../../navigation/destinations.dart';
import '../../widgets/login_scaffold.dart';
import '../../widgets/profile_avatar_view.dart';
import '../../widgets/focus/request_initial_focus.dart';
import '../../../util/focus/dpad_keys.dart';

class ProfileSelectScreen extends StatefulWidget {
  final bool forceSelect;
  final bool initialEditMode;

  const ProfileSelectScreen({
    super.key,
    this.forceSelect = false,
    this.initialEditMode = false,
  });

  @override
  State<ProfileSelectScreen> createState() => _ProfileSelectScreenState();
}

class _ProfileSelectScreenState extends State<ProfileSelectScreen> {
  final _profileRepo = GetIt.instance<VoltixProfileRepository>();
  final _sessionStore = GetIt.instance<VoltixSessionStore>();
  
  bool _isLoading = true;
  late bool _isEditMode;
  List<VoltixProfile> _profiles = [];
  String? _error;
  VoltixProfile? _selectedProfileTransition;
  bool _showWelcome = false;

  @override
  void initState() {
    super.initState();
    _isEditMode = widget.initialEditMode;
    _loadProfiles();
  }

  Future<void> _loadProfiles() async {
    if (!_sessionStore.hasSession || _sessionStore.sessionToken == null) {
      if (mounted) context.go(Destinations.home);
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final allProfiles = await _profileRepo.listProfiles();
      final profiles = allProfiles.where((p) => !p.isOwner).toList();
      if (profiles.isEmpty && mounted) {
        setState(() => _isLoading = false);
        context.push(Destinations.profileEdit, extra: {'isFirstProfile': true}).then((_) => _loadProfiles());
        return;
      }
      setState(() {
        _profiles = profiles;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to load profiles: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _selectProfile(VoltixProfile profile) async {
    if (_selectedProfileTransition != null) return;
    setState(() => _selectedProfileTransition = profile);
    final saveFuture = _sessionStore.setActiveProfile(profile);
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    setState(() => _showWelcome = true);
    await Future.delayed(const Duration(milliseconds: 1200));
    await saveFuture;
    if (mounted) context.go(Destinations.home);
  }

  Future<void> _deleteProfile(int id) async {
    if (_profiles.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot delete the only profile. At least one profile must exist.')),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0F141C),
        title: const Text('Delete Profile', style: TextStyle(color: Colors.white)),
        content: const Text('Are you sure you want to delete this profile?', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      setState(() => _isLoading = true);
      try {
        final wasActive = _sessionStore.activeProfileId == id;
        await _profileRepo.deleteProfile(id);
        if (wasActive) {
          await _sessionStore.clearActiveProfile();
        }
        await _loadProfiles();
      } catch (e) {
        final errorMsg = e.toString().replaceAll('VoltixApiException:', '').replaceAll('Exception:', '').trim();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorMsg.isNotEmpty ? errorMsg : 'Failed to delete profile')));
        setState(() => _isLoading = false);
      }
    }
  }

  void _onProfileCardActivated(VoltixProfile profile) {
    if (_isEditMode) {
      context.push(Destinations.profileEdit, extra: {
        'profile': profile,
        'isFirstProfile': _profiles.length <= 1,
      }).then((_) => _loadProfiles());
    } else {
      _selectProfile(profile);
    }
  }

  void _onAddProfileActivated() {
    context.push(Destinations.profileEdit).then((_) => _loadProfiles());
  }

  void _toggleEditMode() {
    setState(() => _isEditMode = !_isEditMode);
  }

  Color _parseColor(String? colorString) {
    if (colorString == null || colorString.isEmpty) return const Color(0xFF3B82F6);
    try {
      if (colorString.startsWith('#')) {
        return Color(int.parse(colorString.substring(1), radix: 16) + 0xFF000000);
      }
      return Color(int.parse(colorString));
    } catch (_) {
      return const Color(0xFF3B82F6);
    }
  }

  Widget _buildProfileCard(VoltixProfile profile) {
    return Focus(
      onKeyEvent: (node, event) {
        if (isActivateKey(event)) {
          _onProfileCardActivated(profile);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (ctx) {
          final isFocused = Focus.of(ctx).hasFocus;
          return GestureDetector(
            onTap: () => _onProfileCardActivated(profile),
            child: AnimatedScale(
              scale: isFocused ? 1.12 : 1.0,
              duration: const Duration(milliseconds: 200),
              child: Container(
                width: 140,
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isFocused ? AppColorScheme.accent : Colors.transparent,
                              width: 3,
                            ),
                            boxShadow: isFocused
                                ? [
                                    BoxShadow(
                                      color: AppColorScheme.accent.withValues(alpha: 0.5),
                                      blurRadius: 16,
                                      spreadRadius: 4,
                                    )
                                  ]
                                : [],
                          ),
                          child: ProfileAvatarView(
                            fallbackText: profile.name,
                            avatarUrl: profile.avatarUrl,
                            backgroundColor: _parseColor(profile.avatarColor),
                            size: 100,
                          ),
                        ),
                        if (_isEditMode)
                          Positioned.fill(
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.5),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.edit, color: Colors.white, size: 32),
                            ),
                          ),
                        if (_isEditMode && _profiles.length > 1)
                          Positioned(
                            bottom: -4,
                            right: -4,
                            child: Focus(
                              onKeyEvent: (node, event) {
                                if (isActivateKey(event)) {
                                  _deleteProfile(profile.id);
                                  return KeyEventResult.handled;
                                }
                                return KeyEventResult.ignored;
                              },
                              child: GestureDetector(
                                onTap: () => _deleteProfile(profile.id),
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: const BoxDecoration(
                                    color: Colors.red,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.delete, color: Colors.white, size: 18),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      profile.name,
                      style: TextStyle(
                        color: isFocused ? backdropAccentText() : Colors.white,
                        fontSize: 18,
                        fontWeight: isFocused ? FontWeight.bold : FontWeight.normal,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (profile.isKids) ...[
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'KIDS',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                    if (_isEditMode) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Select to Edit',
                        style: TextStyle(
                          color: isFocused ? backdropAccentText() : Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ]
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildAddProfileCard() {
    return Focus(
      onKeyEvent: (node, event) {
        if (isActivateKey(event)) {
          _onAddProfileActivated();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (ctx) {
          final isFocused = Focus.of(ctx).hasFocus;
          return GestureDetector(
            onTap: _onAddProfileActivated,
            child: AnimatedScale(
              scale: isFocused ? 1.12 : 1.0,
              duration: const Duration(milliseconds: 200),
              child: Container(
                width: 140,
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 100,
                      height: 100,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isFocused ? Colors.white.withValues(alpha: 0.2) : Colors.white.withValues(alpha: 0.1),
                        border: Border.all(
                          color: isFocused ? AppColorScheme.accent : Colors.transparent,
                          width: 3,
                        ),
                        boxShadow: isFocused
                            ? [
                                BoxShadow(
                                  color: AppColorScheme.accent.withValues(alpha: 0.5),
                                  blurRadius: 16,
                                  spreadRadius: 4,
                                )
                              ]
                            : [],
                      ),
                      child: Icon(
                        Icons.add,
                        size: 48,
                        color: isFocused ? backdropAccentText() : Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Add Profile',
                      style: TextStyle(
                        color: isFocused ? backdropAccentText() : Colors.white70,
                        fontSize: 18,
                        fontWeight: isFocused ? FontWeight.bold : FontWeight.normal,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildManageProfilesButton() {
    return Focus(
      onKeyEvent: (node, event) {
        if (isActivateKey(event)) {
          _toggleEditMode();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (ctx) {
          final isFocused = Focus.of(ctx).hasFocus;
          return GestureDetector(
            onTap: _toggleEditMode,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              decoration: BoxDecoration(
                color: isFocused ? Colors.white.withValues(alpha: 0.1) : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isFocused ? Colors.white : Colors.white24,
                  width: isFocused ? 2 : 1,
                ),
                boxShadow: isFocused
                    ? [BoxShadow(color: Colors.white.withValues(alpha: 0.15), blurRadius: 8, spreadRadius: 1)]
                    : null,
              ),
              child: Text(
                _isEditMode ? 'Done' : 'Manage Profiles',
                style: TextStyle(
                  color: isFocused ? Colors.white : Colors.white54,
                  fontSize: 16,
                  fontWeight: isFocused ? FontWeight.bold : FontWeight.w500,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildWelcomeView(VoltixProfile profile) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ProfileAvatarView(
            fallbackText: profile.name,
            avatarUrl: profile.avatarUrl,
            backgroundColor: _parseColor(profile.avatarColor),
            size: 130,
            showNeonBorder: true,
            borderColor: AppColorScheme.accent,
          ),
          const SizedBox(height: 32),
          RichText(
            text: TextSpan(
              style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white),
              children: [
                const TextSpan(text: 'Welcome, '),
                TextSpan(
                  text: profile.name,
                  style: TextStyle(color: backdropAccentText()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 48),
          CircularProgressIndicator(color: AppColorScheme.accent),
          const SizedBox(height: 16),
          const Text(
            'Starting your session...',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: WelcomeBackdrop(
          child: Center(
            child: CircularProgressIndicator(color: AppColorScheme.accent),
          ),
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: LoginScaffold(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, color: Colors.red, size: 64),
                const SizedBox(height: 16),
                Text(_error!, style: const TextStyle(color: Colors.white, fontSize: 18)),
                const SizedBox(height: 24),
                Focus(
                  onKeyEvent: (node, event) {
                    if (isActivateKey(event)) {
                      _loadProfiles();
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: Builder(
                    builder: (ctx) {
                      final isFocused = Focus.of(ctx).hasFocus;
                      return GestureDetector(
                        onTap: _loadProfiles,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                          decoration: BoxDecoration(
                            color: isFocused ? Colors.white.withValues(alpha: 0.1) : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: isFocused ? Colors.white : Colors.white54),
                          ),
                          child: const Text('Retry', style: TextStyle(color: Colors.white)),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return RequestInitialFocus(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: LoginScaffold(
          child: SafeArea(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 800),
              child: _showWelcome && _selectedProfileTransition != null
                  ? _buildWelcomeView(_selectedProfileTransition!)
                  : AnimatedOpacity(
                      opacity: _selectedProfileTransition != null ? 0.0 : 1.0,
                      duration: const Duration(milliseconds: 400),
                      child: Center(
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _isEditMode ? 'Manage Profiles' : "Who's watching?",
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 32,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 48),
                              Wrap(
                                spacing: 24,
                                runSpacing: 24,
                                alignment: WrapAlignment.center,
                                children: [
                                  for (final profile in _profiles) _buildProfileCard(profile),
                                  if (_profiles.length < 3 && !_isEditMode) _buildAddProfileCard(),
                                ],
                              ),
                              const SizedBox(height: 48),
                              _buildManageProfilesButton(),
                            ],
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
