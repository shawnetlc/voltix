import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:voltix_design/voltix_design.dart';
import 'package:server_core/server_core.dart';

import '../widgets/admin_form_styles.dart';

/// Server-wide preferred metadata language/country and chapter image settings.
/// Mirrors jellyfin-web's Libraries > Metadata and Images page.
class AdminLibraryMetadataScreen extends StatefulWidget {
  const AdminLibraryMetadataScreen({super.key});

  @override
  State<AdminLibraryMetadataScreen> createState() =>
      _AdminLibraryMetadataScreenState();
}

class _AdminLibraryMetadataScreenState
    extends State<AdminLibraryMetadataScreen> {
  late final AdminSystemApi _api;
  Map<String, dynamic>? _config;
  List<Map<String, dynamic>> _cultures = const [];
  List<Map<String, dynamic>> _countries = const [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  static const _resolutions = [
    ('MatchSource', 'Match source'),
    ('P144', '144p'),
    ('P240', '240p'),
    ('P360', '360p'),
    ('P480', '480p'),
    ('P720', '720p'),
    ('P1080', '1080p'),
    ('P1440', '1440p'),
    ('P2160', '2160p'),
  ];

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
      final cultures =
          <Map<String, dynamic>>[];
      final countries =
          <Map<String, dynamic>>[];
      if (!mounted) return;
      setState(() {
        _config = config;
        _cultures = cultures;
        _countries = countries;
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
    final currentRes = _config!['ChapterImageResolution']?.toString() ?? 'MatchSource';
    return ListView(
      padding: EdgeInsets.fromLTRB(16, 20, 16, bottomSafe + 40),
      children: [
        adminScreenHeader(
          context,
          title: 'Metadata and Images',
          icon: Icons.description_outlined,
        ),
        adminSectionLabel(context, 'Preferred metadata language',
            icon: Icons.language),
        adminCodeDropdown(
          label: 'Preferred metadata language',
          defaultLabel: 'Default',
          current: _config!['PreferredMetadataLanguage']?.toString() ?? '',
          rawItems: _cultures.map((c) => (
                (c['TwoLetterISOLanguageName'] ?? c['ThreeLetterISOLanguageName'])
                    ?.toString(),
                (c['DisplayName'] ?? c['Name'])?.toString(),
              )),
          onChanged: (v) =>
              setState(() => _config!['PreferredMetadataLanguage'] = v),
        ),
        const SizedBox(height: 12),
        adminCodeDropdown(
          label: 'Preferred metadata country',
          defaultLabel: 'Default',
          current: _config!['MetadataCountryCode']?.toString() ?? '',
          rawItems: _countries.map((c) => (
                (c['TwoLetterISORegionName'] ?? c['Name'])?.toString(),
                (c['DisplayName'] ?? c['Name'])?.toString(),
              )),
          onChanged: (v) => setState(() => _config!['MetadataCountryCode'] = v),
        ),
        adminSectionLabel(context, 'Chapters',
            icon: Icons.bookmark_outline),
        TextFormField(
          initialValue:
              (_config!['DummyChapterDuration'] as num?)?.toString() ?? '0',
          decoration: adminInputDecoration(
            label: 'Dummy chapter duration (seconds)',
            helper: 'Length of chapters generated for media that has none. Set to 0 to disable.',
          ),
          keyboardType: TextInputType.number,
          onChanged: (v) => _config!['DummyChapterDuration'] = int.tryParse(v) ?? 0,
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue:
              _resolutions.any((r) => r.$1 == currentRes) ? currentRes : 'MatchSource',
          decoration:
              adminInputDecoration(label: 'Chapter image resolution'),
          items: _resolutions
              .map((r) => DropdownMenuItem(
                    value: r.$1,
                    child: Text(r.$1 == 'MatchSource'
                        ? 'Match source'
                        : r.$2),
                  ))
              .toList(),
          onChanged: (v) => setState(() => _config!['ChapterImageResolution'] = v),
        ),
        const SizedBox(height: AppSpacing.spaceXl),
        adminSaveButton(label: 'Save', saving: _saving, onPressed: _save),
      ],
    );
  }
}
