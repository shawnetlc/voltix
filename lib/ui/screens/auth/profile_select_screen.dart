import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:get_it/get_it.dart';
import '../../../auth/store/voltix_session_store.dart';
import '../../../data/models/voltix_profile.dart';
import '../../../data/repositories/voltix_profile_repository.dart';
import '../../navigation/destinations.dart';

class ProfileSelectScreen extends StatefulWidget {
  const ProfileSelectScreen({super.key});

  @override
  State<ProfileSelectScreen> createState() => _ProfileSelectScreenState();
}

class _ProfileSelectScreenState extends State<ProfileSelectScreen> {
  final _profileRepo = GetIt.instance<VoltixProfileRepository>();
  final _sessionStore = GetIt.instance<VoltixSessionStore>();

  bool _isLoading = true;
  bool _isEditMode = false;
  List<VoltixProfile> _profiles = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadProfiles();
  }

  Future<void> _loadProfiles() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final profiles = await _profileRepo.listProfiles();
      
      // Auto-skip if exactly 1 profile
      if (profiles.length == 1 && mounted) {
        await _selectProfile(profiles.first);
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
    await _sessionStore.setActiveProfile(profile);
    if (mounted) {
      context.go(Destinations.home);
    }
  }

  Future<void> _deleteProfile(int id) async {
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
        await _profileRepo.deleteProfile(id);
        await _loadProfiles();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to delete: $e')));
        }
        setState(() => _isLoading = false);
      }
    }
  }

  Widget _buildProfileCard(VoltixProfile profile) {
    Color bgColor = const Color(0xFF3B82F6);
    if (profile.avatarColor != null && profile.avatarColor!.isNotEmpty) {
      final hex = profile.avatarColor!.replaceAll('#', 'FF');
      bgColor = Color(int.parse(hex, radix: 16));
    }

    final hasEmoji = profile.avatarEmoji != null && profile.avatarEmoji!.isNotEmpty;

    return GestureDetector(
      onTap: () {
        if (_isEditMode) {
          context.push(Destinations.profileEdit, extra: profile).then((_) => _loadProfiles());
        } else {
          _selectProfile(profile);
        }
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: bgColor,
                  borderRadius: BorderRadius.circular(16),
                  border: _isEditMode ? Border.all(color: Colors.white, width: 2) : null,
                ),
                alignment: Alignment.center,
                child: Text(
                  hasEmoji ? profile.avatarEmoji! : profile.name.substring(0, 1).toUpperCase(),
                  style: TextStyle(
                    fontSize: hasEmoji ? 50 : 40,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
              if (_isEditMode)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Container(
                    decoration: const BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.edit, color: Colors.white, size: 24),
                  ),
                ),
              if (_isEditMode && !profile.isOwner)
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: GestureDetector(
                    onTap: () => _deleteProfile(profile.id),
                    child: Container(
                      decoration: const BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.delete, color: Colors.white, size: 24),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            profile.name,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (profile.isKids)
            const Text(
              'Kids',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
        ],
      ),
    );
  }

  Widget _buildAddProfileCard() {
    return GestureDetector(
      onTap: () {
        context.push(Destinations.profileEdit).then((_) => _loadProfiles());
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white54, width: 2),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.add, color: Colors.white, size: 40),
          ),
          const SizedBox(height: 12),
          const Text(
            'Add Profile',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Color(0xFF0A0E17),
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: const Color(0xFF0A0E17),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadProfiles,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E17),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _isEditMode ? 'Manage Profiles' : 'Who\'s watching?',
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
                    ..._profiles.map(_buildProfileCard),
                    if (_profiles.length < 3 && !_isEditMode) _buildAddProfileCard(),
                  ],
                ),
                const SizedBox(height: 48),
                TextButton(
                  onPressed: () => setState(() => _isEditMode = !_isEditMode),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    side: const BorderSide(color: Colors.white54),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  child: Text(
                    _isEditMode ? 'Done' : 'Manage Profiles',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 16,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
