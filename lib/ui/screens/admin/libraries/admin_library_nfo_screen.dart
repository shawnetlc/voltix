import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:voltix_design/voltix_design.dart';
import 'package:server_core/server_core.dart';

import '../widgets/admin_form_styles.dart';

/// Kodi/NFO metadata saver settings, backed by the named `xbmcmetadata`
/// configuration. Mirrors jellyfin-web's Libraries > NFO Settings page.
class AdminLibraryNfoScreen extends StatefulWidget {
  const AdminLibraryNfoScreen({super.key});

  @override
  State<AdminLibraryNfoScreen> createState() => _AdminLibraryNfoScreenState();
}

class _AdminLibraryNfoScreenState extends State<AdminLibraryNfoScreen> {
  late final MediaServerClient _client;
  Map<String, dynamic>? _config;
  List<ServerUser> _users = const [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _client = GetIt.instance<MediaServerClient>();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final config =
          await _client.adminSystemApi.getNamedConfiguration('xbmcmetadata');
      final users = await _client.adminUsersApi
          .getUsers()
          .catchError((_) => <ServerUser>[]);
      if (!mounted) return;
      setState(() {
        _config = config;
        _users = users;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    if (_config == null) return;
    setState(() => _saving = true);
    try {
      final format = (_config!['ReleaseDateFormat'] as String?) ?? '';
      _config!['ReleaseDateFormat'] =
          format.isEmpty ? 'yyyy-MM-dd' : format;
      await _client.adminSystemApi
          .updateNamedConfiguration('xbmcmetadata', _config!);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Settings saved')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Failed to save settings: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _switchTile(String key, String title) {
    return adminSwitchRow(
      title: title,
      value: _config![key] as bool? ?? false,
      onChanged: (v) => setState(() => _config![key] = v),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null || _config == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Failed to load settings',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(_error ?? 'An unknown error occurred',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: _load, child: Text('Retry')),
          ],
        ),
      );
    }

    final bottomSafe = MediaQuery.of(context).padding.bottom;
    final currentUser = _config!['UserId']?.toString() ?? '';
    final userIds = _users.map((u) => u.id).toList();
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 20, 16, bottomSafe + 40),
      children: [
        adminScreenHeader(
          context,
          title: 'NFO Settings',
          subtitle: 'NFO metadata is compatible with Kodi and similar clients. Settings apply to all libraries that save NFO metadata.',
          icon: Icons.text_snippet_outlined,
        ),
        adminSectionLabel(context, 'User to store watch data for in NFO files', icon: Icons.person_outline),
        DropdownButtonFormField<String>(
          initialValue: userIds.contains(currentUser) ? currentUser : '',
          decoration: adminInputDecoration(label: 'User to store watch data for in NFO files'),
          items: [
            DropdownMenuItem(value: '', child: Text('None')),
            ..._users.map((u) =>
                DropdownMenuItem(value: u.id, child: Text(u.name ?? u.id))),
          ],
          onChanged: (v) =>
              setState(() => _config!['UserId'] = (v ?? '').isEmpty ? null : v),
        ),
        adminSection(
          context,
          title: 'NFO',
          icon: Icons.tune,
          children: [
            _switchTile('SaveImagePathsInNfo', 'Save image paths within NFO files'),
            _switchTile('EnablePathSubstitution', 'Enable path substitution for NFO image paths'),
            _switchTile(
                'EnableExtraThumbsDuplication', 'Copy extrafanart images into an extrathumbs folder'),
          ],
        ),
        const SizedBox(height: AppSpacing.spaceXl),
        adminSaveButton(label: 'Save', saving: _saving, onPressed: _save),
      ],
    );
  }
}
