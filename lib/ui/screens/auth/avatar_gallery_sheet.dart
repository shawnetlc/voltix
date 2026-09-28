import 'package:flutter/material.dart';
import 'package:voltix_design/voltix_design.dart';

import '../../widgets/focus/request_initial_focus.dart';
import '../../widgets/overlay_sheet.dart';
import '../../widgets/profile_avatar_view.dart';

/// Interactive modal gallery displaying the Voltix Avatar collection.
/// Organized by category with rich neon lighting, character titles, and TV D-pad focus.
class AvatarGallerySheet extends StatefulWidget {
  final String? currentSelectedUrl;
  final List<dynamic> serverAvatars;
  final ValueChanged<String?> onSelected;

  const AvatarGallerySheet({
    super.key,
    required this.currentSelectedUrl,
    this.serverAvatars = const [],
    required this.onSelected,
  });

  static Future<void> show({
    required BuildContext context,
    required String? currentSelectedUrl,
    List<dynamic> serverAvatars = const [],
    required ValueChanged<String?> onSelected,
  }) {
    return showFocusRestoringDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: AvatarGallerySheet(
            currentSelectedUrl: currentSelectedUrl,
            serverAvatars: serverAvatars,
            onSelected: (url) {
              onSelected(url);
              Navigator.of(dialogContext).pop();
            },
          ),
        );
      },
    );
  }

  @override
  State<AvatarGallerySheet> createState() => _AvatarGallerySheetState();
}

class _AvatarGallerySheetState extends State<AvatarGallerySheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    final tabCount = widget.serverAvatars.isNotEmpty ? 4 : 3;
    _tabController = TabController(length: tabCount, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RequestInitialFocus(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 820, maxHeight: 680),
      decoration: BoxDecoration(
        color: const Color(0xFF0F1420),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: AppColorScheme.accent.withValues(alpha: 0.35),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColorScheme.accent.withValues(alpha: 0.2),
            blurRadius: 32,
            spreadRadius: 2,
          ),
          const BoxShadow(
            color: Colors.black87,
            blurRadius: 40,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(23),
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(24, 20, 16, 12),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppColorScheme.accent.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.auto_awesome,
                      color: AppColorScheme.accent,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Choose Your Avatar',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Select an official Voltix Ambassador or funny character',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.white.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // Tab bar
            Container(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: TabBar(
                controller: _tabController,
                isScrollable: true,
                indicatorColor: AppColorScheme.accent,
                indicatorWeight: 3,
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white54,
                labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                tabs: [
                  const Tab(text: 'Voltix Ambassador'),
                  const Tab(text: 'Funny & Mascots'),
                  const Tab(text: 'Kids & Fantasy'),
                  if (widget.serverAvatars.isNotEmpty)
                    const Tab(text: 'Cloud / Server'),
                ],
              ),
            ),

            // Tab Content
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildGrid(
                    kBuiltInAvatars
                        .where((a) => a.category == 'Voltix Ambassador')
                        .toList(),
                  ),
                  _buildGrid(
                    kBuiltInAvatars
                        .where((a) => a.category == 'Funny & Mascots')
                        .toList(),
                  ),
                  _buildGrid(
                    kBuiltInAvatars
                        .where((a) => a.category == 'Kids & Fantasy')
                        .toList(),
                  ),
                  if (widget.serverAvatars.isNotEmpty)
                    _buildServerGrid(),
                ],
              ),
            ),

            // Footer / Default reset
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              decoration: BoxDecoration(
                color: const Color(0xFF090D15),
                border: Border(
                  top: BorderSide(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
              ),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: () => widget.onSelected(null),
                    icon: const Icon(Icons.restart_alt, size: 18),
                    label: const Text('Reset to Default Initial / Emoji'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white60,
                    ),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColorScheme.accent,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildGrid(List<BuiltInAvatar> avatars) {
    return GridView.builder(
      padding: const EdgeInsets.all(20),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisExtent: 230,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: avatars.length,
      itemBuilder: (context, index) {
        final avatar = avatars[index];
        final isSelected = widget.currentSelectedUrl == avatar.assetPath;
        return _AvatarCard(
          name: avatar.name,
          imagePath: avatar.assetPath,
          isSelected: isSelected,
          onTap: () => widget.onSelected(avatar.assetPath),
        );
      },
    );
  }

  Widget _buildServerGrid() {
    return GridView.builder(
      padding: const EdgeInsets.all(20),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisExtent: 230,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: widget.serverAvatars.length,
      itemBuilder: (context, index) {
        final dynamic a = widget.serverAvatars[index];
        final url = a is String ? a : a.url.toString();
        final name = a is String ? 'Avatar ${index + 1}' : a.name.toString();
        final isSelected = widget.currentSelectedUrl == url;
        return _AvatarCard(
          name: name,
          imagePath: url,
          isSelected: isSelected,
          onTap: () => widget.onSelected(url),
        );
      },
    );
  }
}

class _AvatarCard extends StatefulWidget {
  final String name;
  final String imagePath;
  final bool isSelected;
  final VoidCallback onTap;

  const _AvatarCard({
    required this.name,
    required this.imagePath,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_AvatarCard> createState() => _AvatarCardState();
}

class _AvatarCardState extends State<_AvatarCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.isSelected || _focused;
    final borderColor = widget.isSelected
        ? AppColorScheme.accent
        : (_focused ? Colors.white : Colors.white.withValues(alpha: 0.12));

    return FocusableActionDetector(
      onFocusChange: (f) => setState(() => _focused = f),
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (intent) => widget.onTap(),
        ),
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: const Color(0xFF161C2C),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: borderColor,
              width: active ? 2.5 : 1,
            ),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: AppColorScheme.accent.withValues(alpha: 0.45),
                      blurRadius: 16,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                  child: widget.imagePath.startsWith('assets/')
                      ? Image.asset(
                          widget.imagePath,
                          fit: BoxFit.cover,
                        )
                      : ProfileAvatarView(
                          avatarUrl: widget.imagePath,
                          borderRadius: 0,
                        ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: widget.isSelected
                      ? AppColorScheme.accent.withValues(alpha: 0.18)
                      : Colors.black26,
                  borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: widget.isSelected ? FontWeight.bold : FontWeight.w500,
                          color: widget.isSelected ? AppColorScheme.accent : Colors.white,
                        ),
                      ),
                    ),
                    if (widget.isSelected)
                      Icon(
                        Icons.check_circle,
                        color: AppColorScheme.accent,
                        size: 16,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
