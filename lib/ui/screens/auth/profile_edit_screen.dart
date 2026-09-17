import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:get_it/get_it.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../data/models/voltix_profile.dart';
import '../../../data/repositories/voltix_profile_repository.dart';
import '../../../data/services/voltix_api_service.dart';

class ProfileEditScreen extends StatefulWidget {
  final VoltixProfile? profile;

  const ProfileEditScreen({super.key, this.profile});

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

  /// Available server-hosted avatars fetched from the API.
  List<_AvatarEntry> _serverAvatars = [];
  bool _avatarsLoading = true;

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
    _nameController = TextEditingController(text: widget.profile?.name ?? '');
    _selectedColor = widget.profile?.avatarColor ?? _colors.first;
    _selectedEmoji = widget.profile?.avatarEmoji;
    _selectedAvatarUrl = widget.profile?.avatarUrl;
    _isKids = widget.profile?.isKids ?? false;
    _loadServerAvatars();
  }

  Future<void> _loadServerAvatars() async {
    try {
      final api = GetIt.instance<VoltixApiService>();
      final dio = Dio();
      final response = await dio.get('${api.baseUrl}/api/voltix/profile-avatars');
      final data = response.data;
      if (data is Map && data['avatars'] is List) {
        final avatars = (data['avatars'] as List).map((a) {
          return _AvatarEntry(
            name: a['name']?.toString() ?? '',
            url: a['url']?.toString() ?? '',
          );
        }).where((a) => a.url.isNotEmpty).toList();
        if (mounted) setState(() => _serverAvatars = avatars);
      }
    } catch (_) {
      // Server avatars not available — fall back to emoji/color only
    }
    if (mounted) setState(() => _avatarsLoading = false);
  }

  @override
  void dispose() {
    _nameController.dispose();
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
        await _profileRepo.createProfile(
          name: name,
          avatarColor: _selectedColor,
          avatarEmoji: _selectedAvatarUrl != null ? null : _selectedEmoji,
          avatarUrl: _selectedAvatarUrl,
          isKids: _isKids,
        );
      } else {
        await _profileRepo.updateProfile(
          widget.profile!.id,
          name: name,
          avatarColor: _selectedColor,
          avatarEmoji: _selectedAvatarUrl != null ? null : _selectedEmoji,
          avatarUrl: _selectedAvatarUrl,
          isKids: _isKids,
        );
      }
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to save profile: $e')));
      }
      setState(() => _isLoading = false);
    }
  }

  Future<void> _delete() async {
    if (widget.profile == null || widget.profile!.isOwner) return;

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
        await _profileRepo.deleteProfile(widget.profile!.id);
        if (mounted) context.pop();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to delete: $e')));
        }
        setState(() => _isLoading = false);
      }
    }
  }

  Widget _buildAvatarPreview(Color parsedColor) {
    if (_selectedAvatarUrl != null && _selectedAvatarUrl!.isNotEmpty) {
      return Container(
        width: 120,
        height: 120,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: parsedColor, width: 3),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(21),
          child: CachedNetworkImage(
            imageUrl: _selectedAvatarUrl!,
            fit: BoxFit.cover,
            placeholder: (_, _) => Container(
              color: parsedColor,
              child: const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54)),
            ),
            errorWidget: (_, _, _) => Container(
              color: parsedColor,
              child: const Icon(Icons.broken_image, color: Colors.white54, size: 40),
            ),
          ),
        ),
      );
    }

    return Container(
      width: 120,
      height: 120,
      decoration: BoxDecoration(
        color: parsedColor,
        borderRadius: BorderRadius.circular(24),
      ),
      alignment: Alignment.center,
      child: Text(
        _selectedEmoji ?? (_nameController.text.isNotEmpty ? _nameController.text.substring(0, 1).toUpperCase() : '?'),
        style: TextStyle(
          fontSize: _selectedEmoji != null ? 60 : 50,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
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

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E17),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(isEditing ? 'Edit Profile' : 'Add Profile'),
        actions: [
          if (isEditing && !widget.profile!.isOwner)
            IconButton(
              icon: const Icon(Icons.delete, color: Colors.red),
              onPressed: _isLoading ? null : _delete,
            ),
        ],
      ),
      body: _isLoading 
        ? const Center(child: CircularProgressIndicator())
        : SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                // ── Avatar preview ──
                _buildAvatarPreview(parsedColor),
                const SizedBox(height: 32),

                // ── Name field ──
                TextField(
                  controller: _nameController,
                  maxLength: 64,
                  style: const TextStyle(color: Colors.white),
                  onChanged: (v) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    labelStyle: TextStyle(color: Colors.white54),
                    enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                    focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.blue)),
                  ),
                ),

                // ── Server-hosted Avatars ──
                if (_serverAvatars.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Choose Avatar', style: TextStyle(color: Colors.white70, fontSize: 16)),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 80,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _serverAvatars.length + 1,
                      separatorBuilder: (_, _) => const SizedBox(width: 12),
                      itemBuilder: (context, index) {
                        // First item: "No avatar" option
                        if (index == 0) {
                          final isSelected = _selectedAvatarUrl == null;
                          return GestureDetector(
                            onTap: () => setState(() => _selectedAvatarUrl = null),
                            child: Container(
                              width: 72,
                              height: 72,
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E293B),
                                borderRadius: BorderRadius.circular(16),
                                border: isSelected ? Border.all(color: Colors.white, width: 3) : Border.all(color: Colors.white12),
                              ),
                              alignment: Alignment.center,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.text_fields, color: isSelected ? Colors.white : Colors.white38, size: 28),
                                  const SizedBox(height: 2),
                                  Text('Default', style: TextStyle(color: isSelected ? Colors.white : Colors.white38, fontSize: 10)),
                                ],
                              ),
                            ),
                          );
                        }

                        final avatar = _serverAvatars[index - 1];
                        final isSelected = avatar.url == _selectedAvatarUrl;
                        return GestureDetector(
                          onTap: () => setState(() => _selectedAvatarUrl = avatar.url),
                          child: Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              border: isSelected ? Border.all(color: Colors.white, width: 3) : Border.all(color: Colors.white12),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(isSelected ? 13 : 15),
                              child: CachedNetworkImage(
                                imageUrl: avatar.url,
                                fit: BoxFit.cover,
                                placeholder: (_, _) => Container(
                                  color: const Color(0xFF1E293B),
                                  child: const Center(child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white24)),
                                ),
                                errorWidget: (_, _, _) => Container(
                                  color: const Color(0xFF1E293B),
                                  child: const Icon(Icons.broken_image, color: Colors.white24),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ] else if (_avatarsLoading) ...[
                  const SizedBox(height: 24),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Loading avatars...', style: TextStyle(color: Colors.white38, fontSize: 14)),
                  ),
                ],

                // ── Color picker ──
                const SizedBox(height: 24),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Color', style: TextStyle(color: Colors.white70, fontSize: 16)),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: _colors.map((c) {
                    final isSelected = c == _selectedColor;
                    return GestureDetector(
                      onTap: () => setState(() => _selectedColor = c),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Color(int.parse(c.replaceAll('#', 'FF'), radix: 16)),
                          shape: BoxShape.circle,
                          border: isSelected ? Border.all(color: Colors.white, width: 3) : null,
                        ),
                      ),
                    );
                  }).toList(),
                ),

                // ── Emoji picker (hidden when server avatar is selected) ──
                if (_selectedAvatarUrl == null) ...[
                  const SizedBox(height: 24),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Icon (Optional)', style: TextStyle(color: Colors.white70, fontSize: 16)),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      GestureDetector(
                        onTap: () => setState(() => _selectedEmoji = null),
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: Colors.white12,
                            shape: BoxShape.circle,
                            border: _selectedEmoji == null ? Border.all(color: Colors.white, width: 2) : null,
                          ),
                          alignment: Alignment.center,
                          child: const Text('A', style: TextStyle(color: Colors.white, fontSize: 20)),
                        ),
                      ),
                      ..._emojis.map((e) {
                        final isSelected = e == _selectedEmoji;
                        return GestureDetector(
                          onTap: () => setState(() => _selectedEmoji = e),
                          child: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: Colors.white12,
                              shape: BoxShape.circle,
                              border: isSelected ? Border.all(color: Colors.white, width: 2) : null,
                            ),
                            alignment: Alignment.center,
                            child: Text(e, style: const TextStyle(fontSize: 24)),
                          ),
                        );
                      }),
                    ],
                  ),
                ],
                const SizedBox(height: 32),
                if (widget.profile?.isOwner != true)
                  SwitchListTile(
                    title: const Text('Kids Profile', style: TextStyle(color: Colors.white)),
                    subtitle: const Text('Show only family-friendly content', style: TextStyle(color: Colors.white54)),
                    value: _isKids,
                    onChanged: (v) => setState(() => _isKids = v),
                    activeThumbColor: Colors.blue,
                  ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Save Profile', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
    );
  }
}

class _AvatarEntry {
  final String name;
  final String url;
  const _AvatarEntry({required this.name, required this.url});
}
