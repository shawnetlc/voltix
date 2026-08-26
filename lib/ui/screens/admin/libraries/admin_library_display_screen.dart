import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:voltix_design/voltix_design.dart';
import 'package:server_core/server_core.dart';

import '../widgets/admin_form_styles.dart';

/// Server-wide library display settings (folder view, collection grouping,
/// external suggestions) plus the date-added behavior from the named `metadata`
/// configuration. Mirrors jellyfin-web's Libraries > Display page.
class AdminLibraryDisplayScreen extends StatefulWidget {
  const AdminLibraryDisplayScreen({super.key});

  @override
  State<AdminLibraryDisplayScreen> createState() =>
      _AdminLibraryDisplayScreenState();
}

class _AdminLibraryDisplayScreenState extends State<AdminLibraryDisplayScreen> {
  late final AdminSystemApi _api;
  Map<String, dynamic>? _config;
  Map<String, dynamic> _metadata = const {};
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _api = GetIt.instance<MediaServerClient>().adminSystemApi;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final config = await _api.getServerConfiguration();
      final metadata = await _api
          .getNamedConfiguration('metadata')
          .catchError((_) => <String, dynamic>{});
      if (!mounted) return;
      setState(() {
        _config = config;
        _metadata = metadata;
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
      await _api.updateServerConfiguration(_config!);
      await _api.updateNamedConfiguration('metadata', _metadata);
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
    final useFileTime = _metadata['UseFileCreationTimeForDateAdded'] as bool? ?? false;
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 20, 16, bottomSafe + 40),
      children: [
        adminScreenHeader(
          context,
          title: 'Display',
          icon: Icons.grid_view,
        ),
        adminSection(
          context,
          title: 'Library display',
          icon: Icons.tune,
          children: [
            _switchTile('EnableFolderView', 'Display a folder view to show plain media folders'),
            _switchTile(
                'DisplaySpecialsWithinSeasons', 'Display specials within seasons they aired in'),
            _switchTile(
                'EnableGroupingMoviesIntoCollections', 'Group movies into collections'),
            _switchTile(
                'EnableGroupingShowsIntoCollections', 'Group shows into collections'),
            _switchTile('EnableExternalContentInSuggestions',
                'Show external content in suggestions'),
          ],
        ),
        adminSectionLabel(context, 'Date added behavior',
            icon: Icons.event_outlined),
        DropdownButtonFormField<bool>(
          initialValue: useFileTime,
          decoration: adminInputDecoration(label: 'Use date added from'),
          items: [
            DropdownMenuItem(value: false, child: Text('Date scanned into the library')),
            DropdownMenuItem(value: true, child: Text('Date the file was created')),
          ],
          onChanged: (v) => setState(
              () => _metadata['UseFileCreationTimeForDateAdded'] = v ?? false),
        ),
        const SizedBox(height: AppSpacing.spaceXl),
        adminSaveButton(label: 'Save', saving: _saving, onPressed: _save),
      ],
    );
  }
}
