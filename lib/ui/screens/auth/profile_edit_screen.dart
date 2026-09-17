import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:get_it/get_it.dart';
import '../../../data/models/voltix_profile.dart';
import '../../../data/repositories/voltix_profile_repository.dart';

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
  late bool _isKids;
  bool _isLoading = false;

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
    _isKids = widget.profile?.isKids ?? false;
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
          avatarEmoji: _selectedEmoji,
          isKids: _isKids,
        );
      } else {
        await _profileRepo.updateProfile(
          widget.profile!.id,
          name: name,
          avatarColor: _selectedColor,
          avatarEmoji: _selectedEmoji,
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
                Container(
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
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: _nameController,
                  maxLength: 64,
                  style: const TextStyle(color: Colors.white),
                  onChanged: (v) => setState(() {}), // Update preview
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    labelStyle: TextStyle(color: Colors.white54),
                    enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                    focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.blue)),
                  ),
                ),
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
