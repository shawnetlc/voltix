import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:voltix_design/voltix_design.dart';
import 'package:server_core/server_core.dart';

import '../../../auth/repositories/session_repository.dart';
import '../../../data/services/storage_path_service.dart';
import '../../../data/services/theme_store_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../preference/user_preferences.dart';
import '../../theme/app_theme_controller.dart';
import '../../widgets/settings/clean_settings_typography.dart';
import 'settings_app_bar.dart';
import '../../../util/platform_detection.dart';
import '../../widgets/focus/request_initial_focus.dart';
import '../../widgets/settings/preference_tiles.dart';
import '../../widgets/overlay_sheet.dart';

class SavedThemesScreen extends StatefulWidget {
  const SavedThemesScreen({super.key});

  @override
  State<SavedThemesScreen> createState() => _SavedThemesScreenState();
}

class _SavedThemesScreenState extends State<SavedThemesScreen> {
  final _prefs = GetIt.instance<UserPreferences>();
  final _storagePaths = GetIt.instance<StoragePathService>();
  late final _themeStore = ThemeStoreService(_storagePaths);
  final _sessionRepo = GetIt.instance<SessionRepository>();
  final _client = GetIt.instance<MediaServerClient>();

  final _refreshFocusNode = FocusNode(debugLabel: 'saved_themes_refresh');
  final _firstItemFocusNode = FocusNode(debugLabel: 'saved_themes_first_item');

  bool _loading = true;
  String? _statusMessage;
  String? _deletingThemeId;
  List<_SavedThemeFile> _savedThemes = [];

  @override
  void initState() {
    super.initState();
    unawaited(_loadSavedThemes());
  }

  @override
  void dispose() {
    _refreshFocusNode.dispose();
    _firstItemFocusNode.dispose();
    super.dispose();
  }

  String _serverSyncKey() {
    final serverId = _sessionRepo.activeServerId;
    if (serverId != null && serverId.trim().isNotEmpty) {
      return serverId.trim();
    }

    final normalized = _client.baseUrl.toLowerCase().trim();
    return normalized.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  }

  Future<Directory?> _resolveCacheDirectory() async {
    try {
      final root = await _storagePaths.getThemeCacheDir();
      final scoped = Directory('${root.path}/${_serverSyncKey()}');
      if (!await scoped.exists()) {
        await scoped.create(recursive: true);
      }
      return scoped;
    } catch (_) {
      return null;
    }
  }

  /// Reads every .json theme in [directory] and appends it to [into], skipping
  /// built-ins, unreadable files and ids already collected.
  Future<void> _collectThemesFrom(
    Directory? directory,
    _SavedThemeSource source,
    List<_SavedThemeFile> into,
    Set<String> seenIds,
  ) async {
    if (directory == null || !await directory.exists()) {
      return;
    }

    final files =
        directory
            .listSync()
            .whereType<File>()
            .where((file) => file.path.toLowerCase().endsWith('.json'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    for (final file in files) {
      try {
        final raw = await file.readAsString();
        final decoded = jsonDecode(raw);
        if (decoded is! Map) {
          continue;
        }

        final spec = ThemeSpec.fromJson(Map<String, dynamic>.from(decoded));
        if (ThemeRegistry.builtInIds.contains(spec.id)) {
          continue;
        }
        if (!seenIds.add(spec.id)) {
          continue;
        }

        into.add(_SavedThemeFile(spec: spec, file: file, source: source));
      } catch (_) {}
    }
  }

  Future<void> _loadSavedThemes() async {
    setState(() {
      _loading = true;
      _statusMessage = null;
    });

    final themes = <_SavedThemeFile>[];
    final seenIds = <String>{};

    // Two directories feed this screen and only the first was ever read, which
    // is why themes saved from the Theme Store never appeared here:
    //   <themeCache>/<serverKey>/  - pushed by server/plugin theme sync
    //   <themeCache>/_store/       - saved by the Theme Store
    // Server themes are collected first because they take precedence over
    // store themes on an id clash, matching ThemeRegistry.availableThemes.
    await _collectThemesFrom(
      await _resolveCacheDirectory(),
      _SavedThemeSource.server,
      themes,
      seenIds,
    );

    Directory? storeDirectory;
    try {
      storeDirectory = await _themeStore.storeDirectory();
    } catch (_) {
      storeDirectory = null;
    }
    await _collectThemesFrom(
      storeDirectory,
      _SavedThemeSource.store,
      themes,
      seenIds,
    );

    themes.sort((left, right) {
      return left.spec.displayName.toLowerCase().compareTo(
        right.spec.displayName.toLowerCase(),
      );
    });

    if (!mounted) {
      return;
    }

    setState(() {
      _loading = false;
      _savedThemes = themes;
    });
  }

  Future<void> _confirmDelete(_SavedThemeFile theme) async {
    final l10n = AppLocalizations.of(context);
    final shouldDelete = await showFocusRestoringDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(l10n.savedThemesDeleteDialogTitle),
          content: Text(
            l10n.savedThemesDeleteDialogMessage(theme.spec.displayName),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.delete),
            ),
          ],
        );
      },
    );

    if (shouldDelete == true) {
      await _deleteTheme(theme);
    }
  }

  Future<void> _deleteTheme(_SavedThemeFile theme) async {
    if (_deletingThemeId != null) {
      return;
    }
    final l10n = AppLocalizations.of(context);

    setState(() {
      _deletingThemeId = theme.spec.id;
      _statusMessage = null;
    });

    try {
      await theme.file.delete();
      // Store themes live in ThemeRegistry's store bucket, not the custom one.
      // Calling removeCustom for them left the theme registered after its file
      // was gone, so it kept appearing as applyable until the next launch.
      switch (theme.source) {
        case _SavedThemeSource.server:
          ThemeRegistry.removeCustom(theme.spec.id);
        case _SavedThemeSource.store:
          ThemeRegistry.removeStoreTheme(theme.spec.id);
      }

      if (!mounted) {
        return;
      }

      final controller = AppThemeScope.of(context);
      final selectedCustomId = _prefs.get(UserPreferences.customThemeId);
      if (selectedCustomId == theme.spec.id) {
        await controller.applyCustomTheme(_prefs, '');
      } else {
        controller.refreshFromPreferences(_prefs);
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _savedThemes.removeWhere((entry) => entry.spec.id == theme.spec.id);
        _statusMessage = l10n.savedThemesDeletedMessage(theme.spec.displayName);
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _statusMessage = l10n.savedThemesDeleteFailedMessage(
          theme.spec.displayName,
        );
      });
    } finally {
      if (!mounted) {
        _deletingThemeId = null;
      } else {
        setState(() {
          _deletingThemeId = null;
        });
      }
    }
  }

  Future<void> _showThemeActionsDialog(_SavedThemeFile themeSpecFile) async {
    final l10n = AppLocalizations.of(context);
    final controller = AppThemeScope.of(context);
    final selectedCustomId = _prefs.get(UserPreferences.customThemeId);
    final isCurrent = selectedCustomId == themeSpecFile.spec.id;

    await showFocusRestoringDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: AppColorScheme.surface.withValues(alpha: 0.9),
          title: Text(themeSpecFile.spec.displayName),
          actions: [
            if (!isCurrent)
              TextButton(
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  unawaited(controller.applyThemeById(_prefs, themeSpecFile.spec.id));
                },
                child: Text(l10n.apply),
              ),
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                unawaited(_confirmDelete(themeSpecFile));
              },
              child: Text(
                l10n.delete,
                style: TextStyle(color: AppColorScheme.statusRequested),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l10n.cancel),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final themeController = AppThemeScope.of(context);
    final selectedCustomId = themeController.activeCustomId;

    return withCleanSettingsTypography(
      context,
      RequestInitialFocus(
        targetNode: PlatformDetection.isTV
            ? (_savedThemes.isNotEmpty ? _firstItemFocusNode : _refreshFocusNode)
            : null,
        child: Scaffold(
          appBar: buildSettingsAppBar(
            context,
            Text(l10n.savedThemesTitle),
            actions: [
              IconButton(
                focusNode: _refreshFocusNode,
                style: IconButton.styleFrom(
                  focusColor: AppColorScheme.accent.withValues(alpha: 0.18),
                ),
                onPressed: _loading ? null : () => unawaited(_loadSavedThemes()),
                icon: const Icon(Icons.refresh),
                tooltip: l10n.refresh,
              ),
            ],
          ),
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Text(
                      l10n.savedThemesDescription,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.74,
                        ),
                      ),
                    ),
                    if (_statusMessage != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _statusMessage!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.78,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    if (_savedThemes.isEmpty)
                      Text(
                        l10n.savedThemesEmpty,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.74,
                          ),
                        ),
                      ),
                    for (final (i, entry) in _savedThemes.indexed) ...[
                      if (PlatformDetection.isTV) ...[
                        TvFocusHighlight(
                          builder: (context, focused) => ListTile(
                            focusNode: i == 0 ? _firstItemFocusNode : null,
                            leading: const Icon(Icons.download_done_outlined),
                            title: Text(entry.spec.displayName),
                            subtitle: Text(
                              selectedCustomId == entry.spec.id
                                  ? l10n.savedThemesCurrentThemeId(entry.spec.id)
                                  : entry.spec.id,
                            ),
                            onTap: () => unawaited(_showThemeActionsDialog(entry)),
                            trailing: _deletingThemeId == entry.spec.id
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Icon(
                                    Icons.delete_outline,
                                    color: focused
                                        ? AppColors.black.withValues(alpha: 0.54)
                                        : null,
                                  ),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ] else ...[
                        Card(
                          child: ListTile(
                            leading: const Icon(Icons.download_done_outlined),
                            title: Text(entry.spec.displayName),
                            subtitle: Text(
                              selectedCustomId == entry.spec.id
                                  ? l10n.savedThemesCurrentThemeId(entry.spec.id)
                                  : entry.spec.id,
                            ),
                            onTap: () async {
                              final controller = AppThemeScope.of(context);
                              await controller.applyThemeById(_prefs, entry.spec.id);
                            },
                            trailing: _deletingThemeId == entry.spec.id
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : IconButton(
                                    onPressed: () =>
                                        unawaited(_confirmDelete(entry)),
                                    icon: const Icon(Icons.delete_outline),
                                    tooltip: l10n.savedThemesDeleteTooltip,
                                  ),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

/// Which directory a saved theme came from. Determines which ThemeRegistry
/// bucket it must be removed from on delete.
enum _SavedThemeSource { server, store }

class _SavedThemeFile {
  final ThemeSpec spec;
  final File file;
  final _SavedThemeSource source;

  const _SavedThemeFile({
    required this.spec,
    required this.file,
    required this.source,
  });
}
