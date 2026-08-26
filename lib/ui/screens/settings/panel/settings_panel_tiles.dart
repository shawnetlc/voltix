part of '../settings_side_panel.dart';

class _EditableStringPreferenceTile extends StatefulWidget {
  final Preference<String> preference;
  final String title;
  final IconData icon;
  final String hintText;
  final Future<String?> Function()? pickPath;

  const _EditableStringPreferenceTile({
    required this.preference,
    required this.title,
    required this.icon,
    required this.hintText,
    this.pickPath,
  });

  @override
  State<_EditableStringPreferenceTile> createState() =>
      _EditableStringPreferenceTileState();
}

class _EditableStringPreferenceTileState
    extends State<_EditableStringPreferenceTile> {
  late final PreferenceBinding<String> _binding;

  @override
  void initState() {
    super.initState();
    _binding = PreferenceBinding(
      GetIt.instance<PreferenceStore>(),
      widget.preference,
    );
  }

  @override
  void dispose() {
    _binding.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: _binding,
      builder: (_, value, _) => _TvSettingsListTile(
        leading: Icon(widget.icon),
        title: Text(widget.title),
        subtitle: Text(_displaySubtitle(context, value)),
        onTap: () => _showEditor(context, value),
      ),
    );
  }

  String _displaySubtitle(BuildContext context, String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return AppLocalizations.of(context).notSet;
    return trimmed;
  }

  Future<void> _showEditor(BuildContext context, String current) async {
    final l10n = AppLocalizations.of(context);
    final controller = TextEditingController(text: current);
    final next = await showFocusRestoringDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(widget.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(hintText: widget.hintText),
            ),
            if (widget.pickPath != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () async {
                    final picked = await widget.pickPath!();
                    if (picked != null) controller.text = picked;
                  },
                  icon: const Icon(Icons.folder_open),
                  label: Text(l10n.browse),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(l10n.save),
          ),
        ],
      ),
    );

    controller.dispose();
    if (next == null) return;
    _binding.value = next;
  }
}

class _DoubleSliderTile extends StatefulWidget {
  final String title;
  final IconData icon;
  final PreferenceBinding<double> binding;
  final double min;
  final double max;

  const _DoubleSliderTile({
    required this.title,
    required this.icon,
    required this.binding,
    required this.min,
    required this.max,
  });

  @override
  State<_DoubleSliderTile> createState() => _DoubleSliderTileState();
}

class _DoubleSliderTileState extends State<_DoubleSliderTile> {
  late final FocusNode _outerFocusNode;
  late final FocusNode _sliderInternalNode;
  bool _outerFocused = false;

  double get _step {
    final s = (widget.max - widget.min) / 40;
    return s <= 0 ? 1 : s;
  }

  @override
  void initState() {
    super.initState();
    _outerFocusNode = FocusNode(
      debugLabel: 'DoubleSliderOuter_${widget.title}',
    );
    _sliderInternalNode = FocusNode(
      debugLabel: 'DoubleSliderInner_${widget.title}',
      canRequestFocus: false,
      skipTraversal: true,
    );
  }

  @override
  void dispose() {
    _outerFocusNode.dispose();
    _sliderInternalNode.dispose();
    super.dispose();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      node.previousFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      node.nextFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      final delta = key == LogicalKeyboardKey.arrowLeft ? -_step : _step;
      final current = widget.binding.value;
      final next = (current + delta).clamp(widget.min, widget.max);
      if (next != current) {
        widget.binding.value = next;
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Focus(
        focusNode: _outerFocusNode,
        onKeyEvent: _onKeyEvent,
        onFocusChange: (focused) {
          if (focused) {
            _ensureSettingsTileVisible(context);
          }
          if (_outerFocused != focused && mounted) {
            setState(() => _outerFocused = focused);
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: _outerFocused
                ? AppColorScheme.onSurface
                : colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
            border: Border.fromBorderSide(
              (_outerFocused
                      ? ThemeRegistry.active.borders.focusBorder
                      : ThemeRegistry.active.borders.cardBorder)
                  .copyWith(width: 1),
            ),
            boxShadow: _outerFocused
                ? ThemeRegistry.active.borders.focusGlow
                : null,
          ),
          child: ListTileTheme.merge(
            textColor: _outerFocused
                ? AppColors.black.withValues(alpha: 0.87)
                : AppColorScheme.onSurface,
            iconColor: _outerFocused
                ? AppColors.black.withValues(alpha: 0.54)
                : AppColorScheme.onSurface.withValues(alpha: 0.7),
            titleTextStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
            subtitleTextStyle: const TextStyle(fontSize: 12),
            child: ValueListenableBuilder<double>(
              valueListenable: widget.binding,
              builder: (context, value, _) {
                final iconColor = _outerFocused
                    ? AppColors.black.withValues(alpha: 0.54)
                    : AppColorScheme.onSurface.withValues(alpha: 0.78);
                return ListTile(
                  focusColor: Colors.transparent,
                  hoverColor: Colors.transparent,
                  leading: buildSettingsLeadingIconShell(
                    context,
                    icon: Icon(widget.icon),
                    focused: _outerFocused,
                    iconColor: iconColor,
                  ),
                  title: Text(widget.title),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppLocalizations.of(
                          context,
                        ).settingsMillisecondsValue(value.round()),
                        style: TextStyle(
                          color: _outerFocused
                              ? AppColors.black.withValues(alpha: 0.54)
                              : AppColorScheme.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                      Slider(
                        focusNode: _sliderInternalNode,
                        value: value.clamp(widget.min, widget.max),
                        min: widget.min,
                        max: widget.max,
                        divisions: 40,
                        onChanged: (v) => widget.binding.value = v,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _NavbarColorPickerTile extends StatefulWidget {
  final VoidCallback? onChanged;

  const _NavbarColorPickerTile({this.onChanged});

  @override
  State<_NavbarColorPickerTile> createState() => _NavbarColorPickerTileState();
}

class _NavbarColorPickerTileState extends State<_NavbarColorPickerTile> {
  static const _keys = OverlayColorPalette.keys;

  late final PreferenceBinding<String> _binding;

  @override
  void initState() {
    super.initState();
    _binding = PreferenceBinding(
      GetIt.instance<PreferenceStore>(),
      UserPreferences.navbarColor,
    );
  }

  @override
  void dispose() {
    _binding.dispose();
    super.dispose();
  }

  Color _swatchColor(String key) =>
      Color(OverlayColorPalette.pickerSwatches[key] ?? 0xFF6B7280);

  Color _swatchBorder(Color color) => color.computeLuminance() > 0.8
      ? AppColors.black.withValues(alpha: 0.38)
      : AppColorScheme.onSurface.withValues(alpha: 0.24);

  String _labelFor(String key, AppLocalizations l10n) =>
      OverlayColorPalette.labelFor(key, l10n);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ValueListenableBuilder<String>(
      valueListenable: _binding,
      builder: (context, value, _) {
        final normalized = OverlayColorPalette.normalizeKey(value);
        if (normalized != value) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || _binding.value == normalized) return;
            _binding.value = normalized;
            widget.onChanged?.call();
          });
        }

        return _TvSettingsListTile(
          leading: const Icon(Icons.palette),
          title: Text(l10n.navbarColor),
          subtitle: Text(_labelFor(normalized, l10n)),
          trailing: Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: _swatchColor(normalized),
              shape: BoxShape.circle,
              border: Border.fromBorderSide(
                ThemeRegistry.active.borders.chipBorder.copyWith(
                  color: _swatchBorder(_swatchColor(normalized)),
                ),
              ),
            ),
          ),
          onTap: () => _showPicker(context, normalized),
        );
      },
    );
  }

  Future<void> _showPicker(BuildContext context, String current) async {
    final l10n = AppLocalizations.of(context);
    final selectedIndex = _keys.indexWhere((e) => e == current);
    final autofocusIndex = selectedIndex >= 0 ? selectedIndex : 0;
    final result = await showFocusRestoringDialog<String>(
      context: context,
      useRootNavigator: false,
      builder: (ctx) {
        final closeOnce = createDialogBackCloseHandler(ctx);
        return Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (_, event) {
            if (!event.logicalKey.isBackKey) return KeyEventResult.ignored;
            if (event is KeyDownEvent || event is KeyUpEvent) {
              closeOnce();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: SimpleDialog(
            title: Text(l10n.navbarColor),
            children: _keys.asMap().entries.map((entry) {
              final i = entry.key;
              final key = entry.value;
              final selected = key == current;
              final swatch = _swatchColor(key);
              return TvFocusHighlight(
                builder: (_, _) => ListTile(
                  autofocus: i == autofocusIndex,
                  leading: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: swatch,
                      shape: BoxShape.circle,
                      border: Border.fromBorderSide(
                        ThemeRegistry.active.borders.chipBorder.copyWith(
                          color: _swatchBorder(swatch),
                        ),
                      ),
                    ),
                  ),
                  title: Text(_labelFor(key, l10n)),
                  trailing: selected ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(ctx, key),
                ),
              );
            }).toList(),
          ),
        );
      },
    );

    if (!mounted || result == null || result == _binding.value) return;
    _binding.value = result;
    widget.onChanged?.call();
  }
}

class _ShuffleContentTypePickerTile extends StatefulWidget {
  final VoidCallback? onChanged;

  const _ShuffleContentTypePickerTile({this.onChanged});

  @override
  State<_ShuffleContentTypePickerTile> createState() =>
      _ShuffleContentTypePickerTileState();
}

class _ShuffleContentTypePickerTileState
    extends State<_ShuffleContentTypePickerTile> {
  static const _labels = <String>{'movies', 'tvshows', 'both'};
  static const _fallbackKey = 'both';

  late final PreferenceBinding<String> _binding;
  late final PreferenceBinding<bool> _showShuffleButtonBinding;
  bool _pickerOpen = false;

  @override
  void initState() {
    super.initState();
    _binding = PreferenceBinding(
      GetIt.instance<PreferenceStore>(),
      UserPreferences.shuffleContentType,
    );
    _showShuffleButtonBinding = PreferenceBinding(
      GetIt.instance<PreferenceStore>(),
      UserPreferences.showShuffleButton,
    );
  }

  @override
  void dispose() {
    _binding.dispose();
    _showShuffleButtonBinding.dispose();
    super.dispose();
  }

  String _normalize(String key) => _labels.contains(key) ? key : _fallbackKey;

  String _label(String key, AppLocalizations l10n) => switch (_normalize(key)) {
    'movies' => l10n.movies,
    'tvshows' => l10n.tvShows,
    'both' => l10n.settingsBoth,
    _ => l10n.settingsBoth,
  };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ValueListenableBuilder<bool>(
      valueListenable: _showShuffleButtonBinding,
      builder: (context, showShuffleButton, _) {
        if (!showShuffleButton) {
          return const SizedBox.shrink();
        }

        return ValueListenableBuilder<String>(
          valueListenable: _binding,
          builder: (context, value, _) {
            final normalized = _normalize(value);
            if (normalized != value) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted || _binding.value == normalized) return;
                _binding.value = normalized;
                widget.onChanged?.call();
              });
            }
            return _TvSettingsListTile(
              leading: const Icon(Icons.shuffle),
              title: Text(l10n.settingsShuffleContentTypeFilter),
              subtitle: Text(_label(normalized, l10n)),
              onTap: () => _showPicker(context, normalized),
            );
          },
        );
      },
    );
  }

  Future<void> _showPicker(BuildContext context, String current) async {
    if (_pickerOpen) return;
    _pickerOpen = true;
    final l10n = AppLocalizations.of(context);
    final entries = _labels.toList();
    final normalizedCurrent = _normalize(current);
    final selectedIndex = entries.indexWhere((e) => e == normalizedCurrent);
    final autofocusIndex = selectedIndex >= 0 ? selectedIndex : 0;
    try {
      final result = await showFocusRestoringDialog<String>(
        context: context,
        useRootNavigator: false,
        builder: (ctx) {
          final closeOnce = createDialogBackCloseHandler(ctx);
          return Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: (_, event) {
              if (!event.logicalKey.isBackKey) return KeyEventResult.ignored;
              if (event is KeyDownEvent || event is KeyUpEvent) {
                closeOnce();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: FocusScope(
              autofocus: true,
              child: SimpleDialog(
                title: Text(l10n.settingsShuffleContentTypeFilter),
                children: entries.asMap().entries.map((entry) {
                  final i = entry.key;
                  final value = entry.value;
                  final selected = value == normalizedCurrent;
                  return TvFocusHighlight(
                    builder: (_, _) => ListTile(
                      autofocus: i == autofocusIndex,
                      title: Text(_label(value, l10n)),
                      trailing: selected ? const Icon(Icons.check) : null,
                      onTap: () => Navigator.pop(ctx, value),
                    ),
                  );
                }).toList(),
              ),
            ),
          );
        },
      );

      if (!mounted || result == null || result == _binding.value) return;
      _binding.value = result;
      widget.onChanged?.call();
    } finally {
      _pickerOpen = false;
    }
  }
}

class _CloudSettingsSyncTile extends StatefulWidget {
  const _CloudSettingsSyncTile();

  @override
  State<_CloudSettingsSyncTile> createState() => _CloudSettingsSyncTileState();
}

class _CloudSettingsSyncTileState extends State<_CloudSettingsSyncTile> {
  bool _isSyncing = false;

  @override
  Widget build(BuildContext context) {
    final voltixStore = GetIt.instance<VoltixSessionStore>();
    final username = voltixStore.username ?? 'User';
    final syncService = GetIt.instance<UserSettingsSyncService>();
    final lastSynced = syncService.getLastSyncedTime(username);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: const Color(0xFF0F141C),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFF1E293B)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.cloud_sync_rounded, color: Color(0xFF3B82F6), size: 24),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Cloud Settings (@$username)',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (_isSyncing)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Settings are tied to your Voltix account. Save your preferences to the server or restore them onto this device.',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Text(
              'Last Synced: $lastSynced',
              style: const TextStyle(
                color: Color(0xFF94A3B8),
                fontSize: 11,
                fontStyle: FontStyle.italic,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isSyncing
                        ? null
                        : () async {
                            setState(() => _isSyncing = true);
                            final ok = await syncService.backupSettingsToServer();
                            if (mounted && context.mounted) {
                              setState(() => _isSyncing = false);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    ok
                                        ? 'Settings successfully backed up to Voltix Server!'
                                        : 'Failed to backup settings: '
                                            '${syncService.lastBackupError ?? 'unknown error'}',
                                  ),
                                  backgroundColor: ok
                                      ? const Color(0xFF10B981)
                                      : Colors.redAccent,
                                  // The reason can be a couple of sentences;
                                  // the default 4s is not enough to read it.
                                  duration: Duration(seconds: ok ? 3 : 10),
                                ),
                              );
                            }
                          },
                    icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                    label: const Text('Sync to Server'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF3B82F6),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _isSyncing
                        ? null
                        : () async {
                            setState(() => _isSyncing = true);
                            final ok = await syncService.restoreSettingsFromServer();
                            if (mounted && context.mounted) {
                              setState(() => _isSyncing = false);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    ok
                                        ? 'Settings successfully restored from Voltix Server!'
                                        : 'No server settings found or restore failed.',
                                  ),
                                  backgroundColor: ok
                                      ? const Color(0xFF10B981)
                                      : Colors.redAccent,
                                ),
                              );
                            }
                          },
                    icon: const Icon(Icons.cloud_download_outlined, size: 18),
                    label: const Text('Restore Settings'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
