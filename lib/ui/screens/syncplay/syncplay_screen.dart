import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voltix_design/voltix_design.dart';
import 'package:server_core/server_core.dart';
import 'package:custom_tv_text_field/custom_tv_text_field.dart';
import 'package:get_it/get_it.dart';
import 'package:playback_core/playback_core.dart';

import '../../../di/providers.dart';
import '../../../l10n/app_localizations.dart';
import '../../../syncplay/syncplay_manager.dart';
import '../../../syncplay/syncplay_state.dart';
import '../../../preference/user_preferences.dart';
import '../../../util/platform_detection.dart';
import '../../../util/focus/dpad_keys.dart';
import '../../widgets/overlay_sheet.dart';
import '../../widgets/focus/request_initial_focus.dart';
import '../../widgets/settings/clean_settings_typography.dart';
import '../../widgets/settings/preference_tiles.dart';

class SyncPlayScreen extends ConsumerStatefulWidget {
  const SyncPlayScreen({super.key});

  @override
  ConsumerState<SyncPlayScreen> createState() => _SyncPlayScreenState();
}

class _SyncPlayScreenState extends ConsumerState<SyncPlayScreen> {
  final _groupNameController = TextEditingController();
  final _groupPasswordController = TextEditingController();
  final _groupNameFocus = FocusNode(debugLabel: 'syncplay_group_name');
  final _passwordFocus = FocusNode(debugLabel: 'syncplay_group_password');
  final _createButtonFocus = FocusNode(debugLabel: 'syncplay_create_button');
  final _tvFieldKey = GlobalKey<CustomTVTextFieldState>();
  final _passwordTvFieldKey = GlobalKey<CustomTVTextFieldState>();
  final _refreshFocusNode = FocusNode(debugLabel: 'syncplay_refresh');
  final _ignoreWaitFocus = FocusNode(debugLabel: 'syncplay_ignore_wait');

  @override
  void initState() {
    super.initState();
    _groupNameFocus.onKeyEvent = _onGroupNameKey;
    _passwordFocus.onKeyEvent = _onPasswordKey;
    _refreshFocusNode.onKeyEvent = (node, event) {
      if ((event is KeyDownEvent || event is KeyRepeatEvent) &&
          event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _ignoreWaitFocus.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    _ignoreWaitFocus.onKeyEvent = (node, event) {
      if ((event is KeyDownEvent || event is KeyRepeatEvent) &&
          event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _refreshFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(syncPlayManagerProvider).fetchGroups();
    });
  }

  @override
  void dispose() {
    _groupNameController.dispose();
    _groupPasswordController.dispose();
    _groupNameFocus.dispose();
    _passwordFocus.dispose();
    _createButtonFocus.dispose();
    _refreshFocusNode.dispose();
    _ignoreWaitFocus.dispose();
    super.dispose();
  }

  bool _handleTvFieldOpen(
    KeyEvent event,
    FocusNode focusNode,
    GlobalKey<CustomTVTextFieldState> fieldKey,
  ) {
    if (!PlatformDetection.isTV) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;

    if (event.logicalKey.isBackKey) {
      if (event is KeyDownEvent &&
          (fieldKey.currentState?.isKeyboardVisible ?? false)) {
        fieldKey.currentState?.closeKeyboard();
        focusNode.requestFocus();
        return true;
      }
      return false;
    }

    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.select) {
      if (!focusNode.hasFocus) focusNode.requestFocus();
      fieldKey.currentState?.openKeyboard();
      return true;
    }

    return false;
  }

  KeyEventResult _onGroupNameKey(FocusNode node, KeyEvent event) {
    if (_handleTvFieldOpen(event, node, _tvFieldKey)) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _onPasswordKey(FocusNode node, KeyEvent event) {
    if (_handleTvFieldOpen(event, node, _passwordTvFieldKey)) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _handleTvKeyboardVisibility(bool visible) {
    if (!visible) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final fieldContext = _tvFieldKey.currentContext;
      if (fieldContext == null || !mounted) return;
      Scrollable.ensureVisible(
        fieldContext,
        alignment: 0.12,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final manager = ref.watch(syncPlayManagerProvider);
    final isTV = PlatformDetection.isTV;
    final showCreateGroup = !manager.state.enabled;
    return RequestInitialFocus(
      targetNode: isTV
          ? (showCreateGroup ? _createButtonFocus : _ignoreWaitFocus)
          : null,
      child: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final manager = ref.watch(syncPlayManagerProvider);
    return withCleanSettingsTypography(
      context,
      Scaffold(
        appBar: AppBar(
          title: Text(l10n.syncPlay),
          actions: [
            if (manager.state.enabled)
              IconButton(
                focusNode: _refreshFocusNode,
                icon: const Icon(Icons.refresh),
                tooltip: l10n.refresh,
                onPressed: () => manager.fetchGroups(),
              ),
          ],
        ),
        // Delegates to _buildBody so the "SyncPlay is off" and "no server
        // supports SyncPlay" states are actually reachable. This body used to be
        // duplicated inline without those checks, which left _buildBody dead and
        // meant the screen offered create/join controls even when nothing could
        // service them.
        body: _buildBody(context, manager, l10n),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    SyncPlayManager manager,
    AppLocalizations l10n,
  ) {
    if (!manager.syncPlayConfigured) {
      return _Message(
        icon: Icons.toggle_off,
        title: l10n.syncPlayDisabledTitle,
        message: l10n.syncPlayDisabledMessage,
      );
    }
    // Availability is judged across every logged-in server, not just the active
    // one: groups hosted elsewhere are joinable, we switch servers to reach them.
    //
    // Suppressed while loading: the cross-server answer is only known once
    // fetchGroups has enumerated the sessions, and showing "unsupported" for
    // that moment would flash a wrong message on every open.
    if (!manager.isLoading && !manager.syncPlayAvailableAnywhere) {
      return _Message(
        icon: Icons.cloud_off,
        title: l10n.syncPlayServerUnsupportedTitle,
        message: l10n.syncPlayServerUnsupportedMessage,
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (manager.errorMessage != null)
          _ErrorBanner(message: manager.errorMessage!),
        if (manager.state.enabled)
          _ActiveGroupSection(
            manager: manager,
            ignoreWaitFocus: _ignoreWaitFocus,
          ),
        if (!manager.state.enabled)
          _CreateGroupSection(
            controller: _groupNameController,
            passwordController: _groupPasswordController,
            manager: manager,
            focusNode: _groupNameFocus,
            passwordFocus: _passwordFocus,
            createButtonFocus: _createButtonFocus,
            tvFieldKey: _tvFieldKey,
            passwordTvFieldKey: _passwordTvFieldKey,
            onKeyboardVisibilityChanged: _handleTvKeyboardVisibility,
          ),
        const SizedBox(height: 16),
        _AvailableGroupsSection(manager: manager),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  const _Message({
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: Theme.of(context).disabledColor),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.error_outline),
            const SizedBox(width: 12),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }
}

class _ActiveGroupSection extends StatefulWidget {
  final SyncPlayManager manager;
  final FocusNode ignoreWaitFocus;

  const _ActiveGroupSection({
    required this.manager,
    required this.ignoreWaitFocus,
  });

  @override
  State<_ActiveGroupSection> createState() => _ActiveGroupSectionState();
}

class _ActiveGroupSectionState extends State<_ActiveGroupSection> {
  bool _pickerOpen = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final s = widget.manager.state;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.groups),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    s.groupName ?? l10n.syncPlayGroupFallbackName,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                _GroupStateChip(state: s.groupState),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              l10n.syncPlayParticipantCount(s.participants.length),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (s.participants.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: s.participants.map((p) {
                  final masked = widget.manager.displayNameFor(p);
                  return Chip(
                    avatar: const CircleAvatar(
                      radius: 12,
                      child: Icon(Icons.person, size: 14),
                    ),
                    label: Text(
                      masked,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  );
                }).toList(),
              ),
            const Divider(height: 24),
            _buildTileWithFocused(
              context,
              builder: (context, focused) => SwitchListTile(
                focusNode: widget.ignoreWaitFocus,
                contentPadding: PlatformDetection.isTV
                    ? const EdgeInsets.symmetric(horizontal: 16)
                    : EdgeInsets.zero,
                title: Text(l10n.syncPlayIgnoreWait),
                subtitle: Text(l10n.syncPlayIgnoreWaitSubtitle),
                value: widget.manager.ignoreWaitEnabled,
                onChanged: (v) => widget.manager.requestSetIgnoreWait(v),
              ),
            ),
            _buildTileWithFocused(
              context,
              builder: (context, focused) => ListTile(
                contentPadding: PlatformDetection.isTV
                    ? const EdgeInsets.symmetric(horizontal: 16)
                    : EdgeInsets.zero,
                leading: const Icon(Icons.repeat),
                title: Text(l10n.syncPlayRepeat),
                trailing: buildSettingsSelectionBubble(context, _repeatLabel(s.repeatMode, l10n), focused),
                onTap: () => _showRepeatPicker(context, s, l10n),
              ),
            ),
            _buildTileWithFocused(
              context,
              builder: (context, focused) => ListTile(
                contentPadding: PlatformDetection.isTV
                    ? const EdgeInsets.symmetric(horizontal: 16)
                    : EdgeInsets.zero,
                leading: Icon(
                  s.shuffleMode == SyncPlayShuffleMode.shuffle
                      ? Icons.shuffle_on_outlined
                      : Icons.shuffle,
                ),
                title: Text(l10n.shuffle),
                trailing: buildSettingsSelectionBubble(context, _shuffleLabel(s.shuffleMode, l10n), focused),
                onTap: () => _showShufflePicker(context, s, l10n),
              ),
            ),
            _buildTile(
              context,
              tile: ListTile(
                contentPadding: PlatformDetection.isTV
                    ? const EdgeInsets.symmetric(horizontal: 16)
                    : EdgeInsets.zero,
                leading: const Icon(Icons.queue_play_next),
                title: Text(l10n.syncPlaySyncCurrentQueue),
                subtitle: Text(l10n.syncPlaySyncCurrentQueueSubtitle),
                onTap: () => widget.manager.syncCurrentPlaybackQueueToGroup(),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: () => widget.manager.leaveGroup(),
                style: FilledButton.styleFrom().copyWith(
                  side: WidgetStateProperty.resolveWith<BorderSide?>((states) {
                    if (states.contains(WidgetState.focused)) {
                      return BorderSide(
                        color: Theme.of(context).colorScheme.primary,
                        width: 2,
                      );
                    }
                    return null;
                  }),
                ),
                icon: const Icon(Icons.logout),
                label: Text(l10n.syncPlayLeaveGroup),
              ),
            ),
            if (s.queue.isNotEmpty) ...[
              const Divider(height: 24),
              Text(
                l10n.syncPlayGroupQueue,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              ...List.generate(s.queue.length, (i) {
                final item = s.queue[i];
                final isCurrent = i == s.currentItemIndex;
                final title =
                    widget.manager.itemTitleFor(item.itemId) ??
                    l10n.syncPlayQueueItemFallback(i + 1);
                final tile = ListTile(
                  contentPadding: PlatformDetection.isTV
                      ? const EdgeInsets.symmetric(horizontal: 16)
                      : EdgeInsets.zero,
                  dense: true,
                  leading: Icon(
                    isCurrent ? Icons.play_circle : Icons.circle_outlined,
                    color: isCurrent ? Theme.of(context).colorScheme.primary : null,
                  ),
                  title: Text(title,
                      style: TextStyle(
                          fontWeight: isCurrent ? FontWeight.bold : null)),
                  subtitle: Text(item.itemId,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => widget.manager.requestSetCurrentItem(item.playlistItemId),
                  trailing: PopupMenuButton<String>(
                    onSelected: (value) {
                      switch (value) {
                        case 'play':
                          widget.manager.requestSetCurrentItem(item.playlistItemId);
                          break;
                        case 'remove':
                          widget.manager.requestRemoveFromQueue(item.playlistItemId);
                          break;
                        case 'up':
                          widget.manager.requestMoveQueueItem(
                              item.playlistItemId, i - 1);
                          break;
                        case 'down':
                          widget.manager.requestMoveQueueItem(
                              item.playlistItemId, i + 1);
                          break;
                      }
                    },
                    itemBuilder: (_) => [
                      if (!isCurrent)
                        PopupMenuItem(
                          value: 'play',
                          child: Text(l10n.syncPlayPlayNow),
                        ),
                      if (i > 0)
                        PopupMenuItem(
                          value: 'up',
                          child: Text(l10n.trackActionMoveUp),
                        ),
                      if (i < s.queue.length - 1)
                        PopupMenuItem(
                          value: 'down',
                          child: Text(l10n.trackActionMoveDown),
                        ),
                      PopupMenuItem(
                        value: 'remove',
                        child: Text(l10n.remove),
                      ),
                    ],
                  ),
                );
                return _buildTile(context, tile: tile);
              }),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTile(
    BuildContext context, {
    required Widget tile,
  }) {
    if (PlatformDetection.isTV) {
      return TvFocusHighlight(
        builder: (context, focused) => tile,
      );
    }
    return tile;
  }

  Widget _buildTileWithFocused(
    BuildContext context, {
    required Widget Function(BuildContext context, bool focused) builder,
  }) {
    if (PlatformDetection.isTV) {
      return TvFocusHighlight(
        builder: builder,
      );
    }
    return builder(context, false);
  }

  void _showRepeatPicker(BuildContext context, SyncPlayState s, AppLocalizations l10n) async {
    if (_pickerOpen) return;
    _pickerOpen = true;
    var picked = false;
    try {
      final result = await showFocusRestoringDialog<SyncPlayRepeatMode>(
        context: context,
        useRootNavigator: false,
        builder: (ctx) => withBackClose(
          ctx,
          SimpleDialog(
            title: Text(l10n.syncPlayRepeat, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            children: SyncPlayRepeatMode.values.map((v) {
              final selected = v == s.repeatMode;
              return TvFocusHighlight(
                builder: (_, focused) => ListTile(
                  autofocus: v == s.repeatMode,
                  title: Text(
                    _repeatLabel(v, l10n),
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  trailing: selected ? const Icon(Icons.check) : null,
                  onTap: () {
                    if (picked) return;
                    picked = true;
                    Navigator.pop(ctx, v);
                  },
                ),
              );
            }).toList(),
          ),
        ),
      );
      if (result != null && result != s.repeatMode) {
        widget.manager.requestSetRepeatMode(result);
      }
    } finally {
      _pickerOpen = false;
    }
  }

  void _showShufflePicker(BuildContext context, SyncPlayState s, AppLocalizations l10n) async {
    if (_pickerOpen) return;
    _pickerOpen = true;
    var picked = false;
    try {
      final result = await showFocusRestoringDialog<SyncPlayShuffleMode>(
        context: context,
        useRootNavigator: false,
        builder: (ctx) => withBackClose(
          ctx,
          SimpleDialog(
            title: Text(l10n.shuffle, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            children: SyncPlayShuffleMode.values.map((v) {
              final selected = v == s.shuffleMode;
              return TvFocusHighlight(
                builder: (_, focused) => ListTile(
                  autofocus: v == s.shuffleMode,
                  title: Text(
                    _shuffleLabel(v, l10n),
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  trailing: selected ? const Icon(Icons.check) : null,
                  onTap: () {
                    if (picked) return;
                    picked = true;
                    Navigator.pop(ctx, v);
                  },
                ),
              );
            }).toList(),
          ),
        ),
      );
      if (result != null && result != s.shuffleMode) {
        widget.manager.requestSetShuffleMode(result);
      }
    } finally {
      _pickerOpen = false;
    }
  }

  String _repeatLabel(SyncPlayRepeatMode mode, AppLocalizations l10n) =>
      switch (mode) {
        SyncPlayRepeatMode.repeatNone => l10n.off,
        SyncPlayRepeatMode.repeatOne => l10n.syncPlayRepeatOne,
        SyncPlayRepeatMode.repeatAll => l10n.all,
      };

  String _shuffleLabel(SyncPlayShuffleMode mode, AppLocalizations l10n) =>
      switch (mode) {
        SyncPlayShuffleMode.shuffle => l10n.syncPlayShuffleModeShuffled,
        SyncPlayShuffleMode.sorted => l10n.syncPlayShuffleModeSorted,
      };
}

class _GroupStateChip extends StatelessWidget {
  final SyncPlayGroupState state;
  const _GroupStateChip({required this.state});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final (label, color) = switch (state) {
      SyncPlayGroupState.idle => (l10n.syncPlayStateIdle, Colors.grey),
      SyncPlayGroupState.waiting => (l10n.syncPlayStateWaiting, Colors.orange),
      SyncPlayGroupState.paused => (l10n.syncPlayStatePaused, Colors.blueGrey),
      SyncPlayGroupState.playing => (l10n.syncPlayStatePlaying, Colors.green),
    };
    return Chip(
      label: Text(label),
      backgroundColor: color.withValues(alpha: 0.15),
      side: ThemeRegistry.active.borders.chipBorder.copyWith(color: color),
    );
  }
}

class _CreateGroupSection extends StatelessWidget {
  final TextEditingController controller;
  final TextEditingController passwordController;
  final SyncPlayManager manager;
  final FocusNode focusNode;
  final FocusNode passwordFocus;
  final FocusNode createButtonFocus;
  final GlobalKey<CustomTVTextFieldState> tvFieldKey;
  final GlobalKey<CustomTVTextFieldState> passwordTvFieldKey;
  final ValueChanged<bool> onKeyboardVisibilityChanged;

  const _CreateGroupSection({
    required this.controller,
    required this.passwordController,
    required this.manager,
    required this.focusNode,
    required this.passwordFocus,
    required this.createButtonFocus,
    required this.tvFieldKey,
    required this.passwordTvFieldKey,
    required this.onKeyboardVisibilityChanged,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final userPreferences = GetIt.instance<UserPreferences>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.syncPlayCreateNewGroup,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            _buildGroupNameField(context, l10n, userPreferences),
            const SizedBox(height: 12),
            _buildPasswordField(context, l10n, userPreferences),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: _buildCreateButton(context, l10n),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupNameField(
    BuildContext context,
    AppLocalizations l10n,
    UserPreferences prefs,
  ) {
    Future<void> triggerCreate() async {
      final name = controller.text.trim().isEmpty
          ? l10n.syncPlayDefaultGroupName
          : controller.text.trim();
      final password = passwordController.text.trim().isNotEmpty
          ? passwordController.text.trim()
          : null;
      await _confirmIfNeeded(
        context,
        manager,
        () => manager.createGroup(name, password: password),
      );
    }

    if (PlatformDetection.isTV) {
      final colorScheme = Theme.of(context).colorScheme;
      return Focus(
        focusNode: focusNode,
        child: ListenableBuilder(
          listenable: focusNode,
          builder: (_, _) {
            final focused = focusNode.hasFocus;
            return CustomTVTextField(
              key: tvFieldKey,
              controller: controller,
              isFocused: focused,
              inputPurpose: InputPurpose.text,
              preferSystemIme: prefs.get(UserPreferences.preferSystemImeKeyboard),
              hint: l10n.syncPlayGroupName,
              textFieldType: TextFieldType.other,
              keyboardType: KeyboardType.alphabetic,
              filled: true,
              fillColor: focused
                  ? colorScheme.primaryContainer
                  : colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
              borderColor: colorScheme.outline,
              focusedBorderColor: colorScheme.primary,
              hintStyle: TextStyle(
                fontFamily: kCleanSettingsFontFamily,
                color: colorScheme.onSurface.withValues(alpha: 0.65),
              ),
              textStyle: TextStyle(
                fontFamily: kCleanSettingsFontFamily,
                color: colorScheme.onSurface,
              ),
              popParentOnKeyboardClose: false,
              onFieldSubmitted: (_) => triggerCreate(),
              onVisibilityChanged: onKeyboardVisibilityChanged,
            );
          },
        ),
      );
    }

    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: l10n.syncPlayGroupName,
        border: const OutlineInputBorder(),
      ),
      onSubmitted: (_) => triggerCreate(),
    );
  }

  Widget _buildPasswordField(
    BuildContext context,
    AppLocalizations l10n,
    UserPreferences prefs,
  ) {
    Future<void> triggerCreate() async {
      final name = controller.text.trim().isEmpty
          ? l10n.syncPlayDefaultGroupName
          : controller.text.trim();
      final password = passwordController.text.trim().isNotEmpty
          ? passwordController.text.trim()
          : null;
      await _confirmIfNeeded(
        context,
        manager,
        () => manager.createGroup(name, password: password),
      );
    }

    if (PlatformDetection.isTV) {
      final colorScheme = Theme.of(context).colorScheme;
      return Focus(
        focusNode: passwordFocus,
        child: ListenableBuilder(
          listenable: passwordFocus,
          builder: (_, _) {
            final focused = passwordFocus.hasFocus;
            return CustomTVTextField(
              key: passwordTvFieldKey,
              controller: passwordController,
              isFocused: focused,
              inputPurpose: InputPurpose.text,
              preferSystemIme: prefs.get(UserPreferences.preferSystemImeKeyboard),
              hint: 'Group Password (Optional)',
              textFieldType: TextFieldType.password,
              keyboardType: KeyboardType.alphabetic,
              filled: true,
              fillColor: focused
                  ? colorScheme.primaryContainer
                  : colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
              borderColor: colorScheme.outline,
              focusedBorderColor: colorScheme.primary,
              hintStyle: TextStyle(
                fontFamily: kCleanSettingsFontFamily,
                color: colorScheme.onSurface.withValues(alpha: 0.65),
              ),
              textStyle: TextStyle(
                fontFamily: kCleanSettingsFontFamily,
                color: colorScheme.onSurface,
              ),
              popParentOnKeyboardClose: false,
              onFieldSubmitted: (_) => triggerCreate(),
              onVisibilityChanged: onKeyboardVisibilityChanged,
            );
          },
        ),
      );
    }

    return TextField(
      controller: passwordController,
      obscureText: true,
      decoration: const InputDecoration(
        labelText: 'Group Password (Optional)',
        hintText: 'Leave empty for a public group',
        border: OutlineInputBorder(),
        prefixIcon: Icon(Icons.lock_outline),
      ),
      onSubmitted: (_) => triggerCreate(),
    );
  }

  Widget _buildCreateButton(BuildContext context, AppLocalizations l10n) {
    return FilledButton.icon(
      focusNode: createButtonFocus,
      onPressed: manager.isLoading
          ? null
          : () async {
              final name = controller.text.trim().isEmpty
                  ? l10n.syncPlayDefaultGroupName
                  : controller.text.trim();
              final password = passwordController.text.trim().isNotEmpty
                  ? passwordController.text.trim()
                  : null;
              await _confirmIfNeeded(
                context,
                manager,
                () => manager.createGroup(name, password: password),
              );
            },
      icon: const Icon(Icons.add),
      label: Text(l10n.syncPlayCreateGroup),
    );
  }
}

class _AvailableGroupsSection extends StatelessWidget {
  final SyncPlayManager manager;
  const _AvailableGroupsSection({required this.manager});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final groups = manager.availableGroups;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.syncPlayAvailableGroups,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (manager.isLoading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (groups.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(l10n.syncPlayNoGroupsAvailable),
              )
            else
              ...groups.map(
                (g) {
                  final tile = ListTile(
                    contentPadding: PlatformDetection.isTV
                        ? const EdgeInsets.symmetric(horizontal: 16)
                        : EdgeInsets.zero,
                    leading: const Icon(Icons.group),
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(g.groupName ?? g.groupId),
                        ),
                        if (g.hasPassword)
                          const Padding(
                            padding: EdgeInsets.only(left: 6),
                            child: Tooltip(
                              message: 'Password Protected',
                              child: Icon(
                                Icons.lock_rounded,
                                size: 16,
                                color: Color(0xFFF59E0B),
                              ),
                            ),
                          ),
                      ],
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${l10n.syncPlayParticipantCount(g.participants.length)} • '
                          '${_syncPlayServerStateLabel(g.state?.serverValue, l10n)}'
                          '${g.serverName != null && g.serverName!.isNotEmpty ? " • ${g.serverName}" : ""}',
                        ),
                        if (g.participants.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Participants: ${g.participants.map(manager.displayNameFor).join(", ")}',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.primary,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ],
                    ),
                    trailing: const Icon(Icons.login),
                    enabled: !manager.isLoading,
                    onTap: () => _handleGroupJoin(context, g),
                  );
                  if (PlatformDetection.isTV) {
                    return TvFocusHighlight(
                      builder: (context, focused) => tile,
                    );
                  }
                  return tile;
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleGroupJoin(BuildContext context, SyncPlayGroupInfo g) async {
    String? password;
    if (g.hasPassword) {
      password = await _promptPassword(context, g);
      if (password == null) return; // User cancelled
    }
    if (!context.mounted) return;
    await _confirmIfNeeded(
      context,
      manager,
      () => manager.joinGroup(
        g.groupId,
        password: password,
        targetServerId: g.serverId,
      ),
    );
  }

  Future<String?> _promptPassword(
    BuildContext context,
    SyncPlayGroupInfo g,
  ) async {
    final controller = TextEditingController();
    return await showFocusRestoringDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F141C),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF1E293B)),
        ),
        title: Row(
          children: [
            const Icon(Icons.lock_rounded, color: Color(0xFFF59E0B)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Password Required',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${g.groupName ?? g.groupId} is password protected. Enter the group password to join.',
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Group Password',
                labelStyle: TextStyle(color: Colors.white60),
                prefixIcon: Icon(Icons.key, color: Colors.white60),
                border: OutlineInputBorder(),
              ),
              onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF3B82F6),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Join Group'),
          ),
        ],
      ),
    );
  }
}

String _syncPlayServerStateLabel(String? serverValue, AppLocalizations l10n) {
  final normalized = serverValue?.trim().toLowerCase();
  return switch (normalized) {
    'idle' => l10n.syncPlayStateIdle,
    'waiting' => l10n.syncPlayStateWaiting,
    'paused' => l10n.syncPlayStatePaused,
    'playing' => l10n.syncPlayStatePlaying,
    _ => (serverValue == null || serverValue.trim().isEmpty)
        ? l10n.syncPlayStateIdle
        : serverValue.trim(),
  };
}

Future<void> _confirmIfNeeded(
  BuildContext context,
  SyncPlayManager manager,
  Future<void> Function() action,
) async {
  if (manager.state.enabled) {
    await action();
    return;
  }
  final playbackManager = GetIt.instance<PlaybackManager>();
  if (playbackManager.queueService.items.isEmpty) {
    await action();
    return;
  }
  final l10n = AppLocalizations.of(context);
  final proceed = await showFocusRestoringDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l10n.syncPlayJoinGroupQuestion),
      content: Text(l10n.syncPlayJoinGroupWarning),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.cancel)),
        FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.syncPlayJoin)),
      ],
    ),
  );
  if (proceed == true) {
    await action();
  }
}
