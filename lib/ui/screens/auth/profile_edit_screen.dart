import 'package:custom_tv_text_field/custom_tv_text_field.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:get_it/get_it.dart';
import '../../../data/models/voltix_profile.dart';
import '../../../data/repositories/voltix_profile_repository.dart';
import '../../../data/services/voltix_api_service.dart';
import '../../navigation/destinations.dart';
import '../../widgets/login_scaffold.dart';
import 'package:voltix_design/voltix_design.dart';
import '../../widgets/profile_avatar_view.dart';
import '../../widgets/focus/request_initial_focus.dart';
import 'avatar_gallery_sheet.dart';
import '../../../util/focus/dpad_keys.dart';
import '../../../auth/store/voltix_session_store.dart';
import '../taste_profile/taste_onboarding_wizard.dart';
import '../../../util/platform_detection.dart';

class ProfileEditScreen extends StatefulWidget {
  final VoltixProfile? profile;
  final bool isFirstProfile;
  const ProfileEditScreen({super.key, this.profile, this.isFirstProfile = false});
  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  final _profileRepo = GetIt.instance<VoltixProfileRepository>();
  late TextEditingController _nameController;
  late String _selectedColor;
  String? _selectedEmoji;
  String? _selectedAvatarUrl;
  late bool _isKids;
  bool _isLoading = false;
  bool _canDelete = false;
  List<_AvatarEntry> _serverAvatars = [];
  late final FocusNode _nameFocusNode;
  final _tvFieldKey = GlobalKey<CustomTVTextFieldState>();

  final List<String> _colors = [
    '#E53935', '#D81B60', '#8E24AA', '#5E35B1',
    '#3949AB', '#1E88E5', '#039BE5', '#00ACC1',
    '#00897B', '#43A047', '#7CB342', '#FDD835'
  ];

  final List<String> _emojis = [
    '😀', '😎', '🤓', '🤩', '😈', '👻', '👾', '🤖',
    '🐱', '🐶', '🦁', '🦊', '🐻', '🐼', '🦉', '🐉',
    '🌟', '🚀', '🎮', '🎨'
  ];

  @override
  void initState() {
    super.initState();
    _canDelete = !widget.isFirstProfile;
    _nameController = TextEditingController(text: widget.profile?.name ?? '');
    _selectedColor = widget.profile?.avatarColor ?? _colors.first;
    _selectedEmoji = widget.profile?.avatarEmoji;
    _selectedAvatarUrl = widget.profile?.avatarUrl;
    _isKids = widget.profile?.isKids ?? false;

    // Create a FocusNode for the name TextField that intercepts D-pad
    // up/down so focus can escape the text field on Android TV.
    _nameFocusNode = FocusNode(debugLabel: 'ProfileNameField');
    _nameFocusNode.onKeyEvent = (node, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.arrowDown) {
        node.nextFocus();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        node.previousFocus();
        return KeyEventResult.handled;
      }
      // Enter / select / OK on remote → open keyboard so user can edit the name
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.numpadEnter) {
        if (PlatformDetection.isTV) {
          _tvFieldKey.currentState?.openKeyboard();
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    };

    _loadServerAvatars();
    if (widget.profile != null) {
      _checkCanDelete();
    }
  }

  Future<void> _checkCanDelete() async {
    try {
      final allProfiles = await _profileRepo.listProfiles();
      final nonOwner = allProfiles.where((p) => !p.isOwner).toList();
      if (mounted) {
        setState(() {
          _canDelete = nonOwner.length > 1;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadServerAvatars() async {
    try {
      final api = GetIt.instance<VoltixApiService>();
      final dio = Dio();
      final response = await dio.get('${api.baseUrl}/api/voltix/profile-avatars');
      final data = response.data;
      if (data is Map && data['avatars'] is List) {
        final avatars = (data['avatars'] as List).map((a) {
          return _AvatarEntry(name: a['name']?.toString() ?? '', url: a['url']?.toString() ?? '');
        }).where((a) => a.url.isNotEmpty).toList();
        if (mounted) setState(() => _serverAvatars = avatars);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nameFocusNode.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Name is required')));
      return;
    }
    setState(() => _isLoading = true);
    try {
      if (widget.profile == null) {
        final newProfile = await _profileRepo.createProfile(
          name: name, avatarColor: _selectedColor,
          avatarEmoji: _selectedAvatarUrl != null ? null : _selectedEmoji,
          avatarUrl: _selectedAvatarUrl, isKids: _isKids,
        );
        await _profileRepo.selectProfile(newProfile.id);
        GetIt.instance<VoltixSessionStore>().setActiveProfile(newProfile);
        if (mounted) {
          if (!_isKids) {
            await TasteOnboardingWizard.showAsDialog(context);
          }
          if (mounted) context.go(Destinations.home);
        }
      } else {
        await _profileRepo.updateProfile(widget.profile!.id,
          name: name, avatarColor: _selectedColor,
          avatarEmoji: _selectedAvatarUrl != null ? null : _selectedEmoji,
          avatarUrl: _selectedAvatarUrl, isKids: _isKids,
        );
        if (mounted) {
          if (widget.isFirstProfile) {
            context.go('${Destinations.profileSelect}?force=1');
          } else {
            context.pop();
          }
        }
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to save profile: $e')));
      setState(() => _isLoading = false);
    }
  }

  Future<void> _delete() async {
    if (widget.profile == null) return;

    try {
      final allProfiles = await _profileRepo.listProfiles();
      final nonOwner = allProfiles.where((p) => !p.isOwner).toList();
      if (nonOwner.length <= 1) {
        if (mounted) {
          setState(() => _canDelete = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cannot delete the only profile. At least one profile must exist.')),
          );
        }
        return;
      }
    } catch (_) {
      if (!_canDelete) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cannot delete the only profile. At least one profile must exist.')),
          );
        }
        return;
      }
    }

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0F141C),
        title: const Text('Delete Profile', style: TextStyle(color: Colors.white)),
        content: const Text('Are you sure you want to delete this profile?', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), style: TextButton.styleFrom(foregroundColor: Colors.red), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed == true) {
      setState(() => _isLoading = true);
      try {
        final sessionStore = GetIt.instance<VoltixSessionStore>();
        final isDeletedActive = sessionStore.activeProfileId == widget.profile!.id;
        await _profileRepo.deleteProfile(widget.profile!.id);
        if (isDeletedActive) {
          await sessionStore.clearActiveProfile();
        }
        if (mounted) {
          if (isDeletedActive || !context.canPop()) {
            context.go('${Destinations.profileSelect}?force=1');
          } else {
            context.pop();
          }
        }
      } catch (e) {
        final errorMsg = e.toString().replaceAll('VoltixApiException:', '').replaceAll('Exception:', '').trim();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorMsg.isNotEmpty ? errorMsg : 'Failed to delete profile')));
        setState(() => _isLoading = false);
      }
    }
  }

  void _openGallery() {
    AvatarGallerySheet.show(
      context: context,
      currentSelectedUrl: _selectedAvatarUrl,
      serverAvatars: _serverAvatars,
      onSelected: (url) { setState(() => _selectedAvatarUrl = url); },
    );
  }

  Widget _buildTvButton({
    required String label,
    required VoidCallback onActivate,
    IconData? icon,
    Color textColor = Colors.white,
    Color borderColor = Colors.white54,
    Color focusBorderColor = Colors.white,
    Color focusBgColor = const Color(0x1AFFFFFF),
    double height = 50,
  }) {
    return Focus(
      onKeyEvent: (node, event) {
        if (isActivateKey(event)) {
          if (!_isLoading) onActivate();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (ctx) {
          final isFocused = Focus.of(ctx).hasFocus;
          return GestureDetector(
            onTap: _isLoading ? null : onActivate,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: double.infinity,
              height: height,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isFocused ? focusBgColor : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isFocused ? focusBorderColor : borderColor,
                  width: isFocused ? 2.5 : 1.5,
                ),
                boxShadow: isFocused
                    ? [BoxShadow(color: focusBorderColor.withValues(alpha: 0.3), blurRadius: 10, spreadRadius: 1)]
                    : null,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[Icon(icon, color: isFocused ? focusBorderColor : textColor, size: 20), const SizedBox(width: 8)],
                  Text(label, style: TextStyle(color: isFocused ? focusBorderColor : textColor, fontSize: 16, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.profile != null;
    Color parsedColor = const Color(0xFF3B82F6);
    try {
      final hex = _selectedColor.replaceAll('#', 'FF');
      parsedColor = Color(int.parse(hex, radix: 16));
    } catch (_) {}

    final scaffold = Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(isEditing ? 'Edit Profile' : 'Add Profile'),
        actions: [
          if (isEditing && _canDelete)
            IconButton(icon: const Icon(Icons.delete, color: Colors.red), onPressed: _isLoading ? null : _delete),
        ],
      ),
      body: WelcomeBackdrop(
        child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  // Avatar preview
                  ProfileAvatarView(
                    avatarUrl: _selectedAvatarUrl,
                    emoji: _selectedAvatarUrl != null ? null : _selectedEmoji,
                    fallbackText: _nameController.text.isNotEmpty ? _nameController.text : '?',
                    backgroundColor: parsedColor,
                    size: 120, borderRadius: 24,
                    showNeonBorder: true, borderColor: parsedColor,
                  ),
                  const SizedBox(height: 32),

                  // Name field — On TV, use CustomTVTextField so navigation down to items
                  // under the profile name is not blocked by auto-displaying keyboard.
                  // The keyboard only displays when explicitly activated via Select / Enter / OK.
                  PlatformDetection.isTV
                      ? Focus(
                          focusNode: _nameFocusNode,
                          child: ListenableBuilder(
                            listenable: _nameFocusNode,
                            builder: (_, _) {
                              final focused = _nameFocusNode.hasFocus;
                              return CustomTVTextField(
                                key: _tvFieldKey,
                                controller: _nameController,
                                isFocused: focused,
                                hint: 'Name',
                                filled: true,
                                fillColor: focused
                                    ? Colors.white.withValues(alpha: 0.12)
                                    : Colors.white.withValues(alpha: 0.05),
                                borderRadius: 8,
                                borderColor: Colors.white24,
                                focusedBorderColor: Colors.blue,
                                textStyle: const TextStyle(color: Colors.white, fontSize: 16),
                                hintStyle: const TextStyle(color: Colors.white54, fontSize: 16),
                                popParentOnKeyboardClose: false,
                                onFieldSubmitted: (_) => _nameFocusNode.nextFocus(),
                              );
                            },
                          ),
                        )
                      : TextField(
                          controller: _nameController,
                          focusNode: _nameFocusNode,
                          autofocus: false,
                          maxLength: 64,
                          textInputAction: TextInputAction.done,
                          style: const TextStyle(color: Colors.white),
                          onChanged: (v) => setState(() {}),
                          onSubmitted: (_) => _nameFocusNode.nextFocus(),
                          decoration: const InputDecoration(
                            labelText: 'Name',
                            labelStyle: TextStyle(color: Colors.white54),
                            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.blue)),
                          ),
                        ),

                    // Avatars section header
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Choose Avatar', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                        // "View All Gallery" button - TV-safe
                        _buildGalleryButton(),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Avatar horizontal list
                    _buildAvatarList(),

                    // Color picker
                    const SizedBox(height: 24),
                    const Align(alignment: Alignment.centerLeft, child: Text('Color', style: TextStyle(color: Colors.white70, fontSize: 16))),
                    const SizedBox(height: 12),
                    _buildColorPicker(),

                    // Emoji picker (hidden when avatar image is selected)
                    if (_selectedAvatarUrl == null) ..._buildEmojiPicker(),

                    // Kids toggle — TV-safe with clearly visible active state
                    Focus(
                      onKeyEvent: (node, event) {
                        if (isActivateKey(event)) {
                          setState(() => _isKids = !_isKids);
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: Builder(
                        builder: (ctx) {
                          final isFocused = Focus.of(ctx).hasFocus;
                          return GestureDetector(
                            onTap: () => setState(() => _isKids = !_isKids),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                              decoration: BoxDecoration(
                                color: isFocused ? Colors.white.withValues(alpha: 0.08) : Colors.transparent,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isFocused ? Colors.white : Colors.white12,
                                  width: isFocused ? 2 : 1,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Text('Kids Profile', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                                        const SizedBox(height: 4),
                                        const Text('Show only family-friendly content', style: TextStyle(color: Colors.white54, fontSize: 13)),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Switch(
                                    value: _isKids,
                                    onChanged: (v) => setState(() => _isKids = v),
                                    activeThumbColor: Colors.greenAccent,
                                    activeTrackColor: Colors.green.withValues(alpha: 0.5),
                                    inactiveThumbColor: Colors.grey,
                                    inactiveTrackColor: Colors.grey.withValues(alpha: 0.3),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),

                    // Save button
                    const SizedBox(height: 32),
                    _buildTvButton(
                      label: 'Save Profile',
                      onActivate: _save,
                      textColor: Colors.white,
                      borderColor: Colors.white,
                      focusBorderColor: Colors.white,
                      focusBgColor: Colors.white.withValues(alpha: 0.15),
                    ),

                    // Delete button (edit mode only)
                    if (isEditing && _canDelete) ...[
                      const SizedBox(height: 16),
                      _buildTvButton(
                        label: 'Delete Profile',
                        icon: Icons.delete_outline,
                        onActivate: _delete,
                        textColor: Colors.redAccent,
                        borderColor: Colors.redAccent.withValues(alpha: 0.6),
                        focusBorderColor: Colors.redAccent,
                        focusBgColor: Colors.redAccent.withValues(alpha: 0.15),
                      ),
                    ],
                  ],
                ),
              ),
        ),
      );

    if (PlatformDetection.isTV) {
      return RequestInitialFocus(child: scaffold);
    }
    return scaffold;
  }

  Widget _buildGalleryButton() {
    return Focus(
      onKeyEvent: (node, event) {
        if (isActivateKey(event)) { _openGallery(); return KeyEventResult.handled; }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (ctx) {
          final isFocused = Focus.of(ctx).hasFocus;
          return GestureDetector(
            onTap: _openGallery,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isFocused ? Colors.white.withValues(alpha: 0.1) : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: isFocused ? Border.all(color: Colors.white, width: 2) : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.grid_view, size: 16, color: isFocused ? Colors.white : backdropAccentText()),
                  const SizedBox(width: 6),
                  Text('View All Gallery', style: TextStyle(color: isFocused ? Colors.white : backdropAccentText(), fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildAvatarList() {
    return SizedBox(
      // Tall enough for the 96px thumbnails plus the 1.15x focus scale.
      height: 140,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        scrollDirection: Axis.horizontal,
        itemCount: kBuiltInAvatars.length + 1 + _serverAvatars.length,
        separatorBuilder: (_, _) => const SizedBox(width: 18),
        itemBuilder: (context, index) {
          if (index == 0) return _buildDefaultAvatarItem();
          if (index - 1 < kBuiltInAvatars.length) {
            final avatar = kBuiltInAvatars[index - 1];
            return _buildAvatarItem(
              url: avatar.assetPath,
              name: avatar.name,
              isSelected: avatar.assetPath == _selectedAvatarUrl,
              onSelect: () => setState(() => _selectedAvatarUrl = avatar.assetPath),
            );
          }
          final serverIndex = index - 1 - kBuiltInAvatars.length;
          final avatar = _serverAvatars[serverIndex];
          return _buildAvatarItem(
            url: avatar.url,
            name: avatar.name,
            isSelected: avatar.url == _selectedAvatarUrl,
            onSelect: () => setState(() => _selectedAvatarUrl = avatar.url),
          );
        },
      ),
    );
  }

  Widget _buildDefaultAvatarItem() {
    final isSelected = _selectedAvatarUrl == null;
    return Focus(
      onKeyEvent: (node, event) {
        if (isActivateKey(event)) { setState(() => _selectedAvatarUrl = null); return KeyEventResult.handled; }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (ctx) {
          final isFocused = Focus.of(ctx).hasFocus;
          return GestureDetector(
            onTap: () => setState(() => _selectedAvatarUrl = null),
            child: AnimatedScale(
              scale: isFocused ? 1.15 : 1.0,
              duration: const Duration(milliseconds: 150),
              child: Container(
                width: 96, height: 96,
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(16),
                  border: (isFocused || isSelected)
                      ? Border.all(color: isFocused ? Colors.white : AppColorScheme.accent, width: isFocused ? 3 : 2.5)
                      : Border.all(color: Colors.white12),
                  boxShadow: (isFocused || isSelected)
                      ? [BoxShadow(color: (isFocused ? Colors.white : AppColorScheme.accent).withValues(alpha: 0.3), blurRadius: 8, spreadRadius: 1)]
                      : null,
                ),
                alignment: Alignment.center,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.text_fields, color: (isFocused || isSelected) ? Colors.white : Colors.white38, size: 34),
                    const SizedBox(height: 2),
                    Text('Default', style: TextStyle(color: (isFocused || isSelected) ? Colors.white : Colors.white38, fontSize: 12)),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildAvatarItem({required String url, required String name, required bool isSelected, required VoidCallback onSelect}) {
    return Focus(
      onKeyEvent: (node, event) {
        if (isActivateKey(event)) { onSelect(); return KeyEventResult.handled; }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (ctx) {
          final isFocused = Focus.of(ctx).hasFocus;
          return GestureDetector(
            onTap: onSelect,
            child: AnimatedScale(
              scale: isFocused ? 1.15 : 1.0,
              duration: const Duration(milliseconds: 150),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ProfileAvatarView(
                    avatarUrl: url, size: 96, borderRadius: 18,
                    showNeonBorder: isFocused || isSelected,
                    borderColor: isFocused ? Colors.white : (isSelected ? AppColorScheme.accent : Colors.white12),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    name.length > 10 ? '${name.substring(0, 9)}…' : name,
                    style: TextStyle(
                      color: isFocused ? Colors.white : (isSelected ? backdropAccentText() : Colors.white60),
                      fontSize: 12,
                      fontWeight: (isFocused || isSelected) ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildColorPicker() {
    return Wrap(
      spacing: 12, runSpacing: 12,
      children: _colors.map((c) {
        final isSelected = c == _selectedColor;
        final circleColor = Color(int.parse(c.replaceAll('#', 'FF'), radix: 16));
        return Focus(
          onKeyEvent: (node, event) {
            if (isActivateKey(event)) { setState(() => _selectedColor = c); return KeyEventResult.handled; }
            return KeyEventResult.ignored;
          },
          child: Builder(
            builder: (ctx) {
              final isFocused = Focus.of(ctx).hasFocus;
              return GestureDetector(
                onTap: () => setState(() => _selectedColor = c),
                child: AnimatedScale(
                  scale: isFocused ? 1.25 : 1.0,
                  duration: const Duration(milliseconds: 150),
                  child: Container(
                    width: 40, height: 40,
                    decoration: BoxDecoration(
                      color: circleColor, shape: BoxShape.circle,
                      border: isFocused ? Border.all(color: Colors.white, width: 3)
                             : (isSelected ? Border.all(color: Colors.white, width: 3) : null),
                      boxShadow: isFocused
                          ? [BoxShadow(color: Colors.white.withValues(alpha: 0.4), blurRadius: 10, spreadRadius: 1)]
                          : null,
                    ),
                  ),
                ),
              );
            },
          ),
        );
      }).toList(),
    );
  }

  List<Widget> _buildEmojiPicker() {
    return [
      const SizedBox(height: 24),
      const Align(alignment: Alignment.centerLeft, child: Text('Icon (Optional)', style: TextStyle(color: Colors.white70, fontSize: 16))),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8, runSpacing: 8,
        children: [
          // "None" / default letter option
          _buildEmojiItem(null, 'A'),
          ..._emojis.map((e) => _buildEmojiItem(e, e)),
        ],
      ),
    ];
  }

  Widget _buildEmojiItem(String? emoji, String display) {
    final isSelected = emoji == _selectedEmoji;
    return Focus(
      onKeyEvent: (node, event) {
        if (isActivateKey(event)) { setState(() => _selectedEmoji = emoji); return KeyEventResult.handled; }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (ctx) {
          final isFocused = Focus.of(ctx).hasFocus;
          return GestureDetector(
            onTap: () => setState(() => _selectedEmoji = emoji),
            child: AnimatedScale(
              scale: isFocused ? 1.2 : 1.0,
              duration: const Duration(milliseconds: 150),
              child: Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  color: isFocused ? Colors.white.withValues(alpha: 0.15) : Colors.white12,
                  shape: BoxShape.circle,
                  border: isFocused
                      ? Border.all(color: Colors.white, width: 2.5)
                      : (isSelected ? Border.all(color: Colors.white, width: 2) : null),
                ),
                alignment: Alignment.center,
                child: Text(display, style: TextStyle(fontSize: emoji == null ? 20 : 24, color: Colors.white)),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _AvatarEntry {
  final String name;
  final String url;
  const _AvatarEntry({required this.name, required this.url});
}
