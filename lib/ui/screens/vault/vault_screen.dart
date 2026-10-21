import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:server_core/server_core.dart';
import 'package:voltix_design/voltix_design.dart';

import '../../../data/models/aggregated_item.dart';
import '../../../data/services/vault_service.dart';
import '../../../preference/user_preferences.dart';
import '../../../util/platform_detection.dart';
import '../../../util/voltix_library_branding.dart' show kAppAssetImagePrefix;
import '../../navigation/destinations.dart';
import '../../widgets/focus/focusable_toolbar_button.dart';
import '../../widgets/focus/request_initial_focus.dart';
import '../../widgets/media_card.dart';

const _kHPad = 60.0;
const _kCompactBreakpoint = 600.0;

bool _isCompact(BuildContext context) =>
    PlatformDetection.useMobileUi ||
    MediaQuery.sizeOf(context).width < _kCompactBreakpoint;

double _scale() {
  try {
    return GetIt.instance<UserPreferences>()
        .get(UserPreferences.desktopUiScale)
        .scaleFactor;
  } catch (_) {
    return 1.0;
  }
}

/// Shared page frame: home button + title, then [body].
class _VaultFrame extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget body;

  const _VaultFrame({required this.title, required this.body, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final compact = _isCompact(context);
    final s = _scale();
    return Scaffold(
      backgroundColor: AppColorScheme.background,
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 16 : _kHPad,
              compact ? MediaQuery.of(context).padding.top + 8 : 20,
              compact ? 16 : _kHPad,
              8,
            ),
            child: Row(
              children: [
                FocusableToolbarButton(
                  icon: Icons.arrow_back,
                  size: 42 * s,
                  iconSize: 24 * s,
                  tooltip: 'Back',
                  onTap: () => context.canPop()
                      ? context.pop()
                      : context.go(Destinations.home),
                ),
                SizedBox(width: 4 * s),
                FocusableToolbarButton(
                  icon: Icons.home,
                  size: 42 * s,
                  iconSize: 24 * s,
                  tooltip: 'Home',
                  onTap: () => context.go(Destinations.home),
                ),
                SizedBox(width: 12 * s),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 26 * s,
                          fontWeight: FontWeight.w300,
                          color: AppColorScheme.onSurface,
                        ),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: TextStyle(
                            fontSize: 13 * s,
                            color: AppColorScheme.onSurface
                                .withValues(alpha: 0.6),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// Lays out [count] cards of [cardWidth] in a responsive grid.
Widget _grid({
  required BuildContext context,
  required int count,
  required double cardWidth,
  required double aspectRatio,
  required Widget Function(BuildContext, int, double) builder,
}) {
  return LayoutBuilder(builder: (context, constraints) {
    final compact = _isCompact(context);
    final s = _scale();
    final hPad = compact ? 16.0 : _kHPad * s;
    final spacing = 16.0 * s;
    final w = cardWidth * s;
    final cols = ((constraints.maxWidth - hPad * 2 + spacing) / (w + spacing))
        .floor()
        .clamp(compact ? 2 : 3, 10);
    final cellW = (constraints.maxWidth - hPad * 2 - spacing * (cols - 1)) / cols;
    // Card = image + two text lines below it.
    final cellH = cellW / aspectRatio + 44 * s;
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(hPad, 16, hPad, 32),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        mainAxisSpacing: spacing,
        crossAxisSpacing: spacing,
        childAspectRatio: cellW / cellH,
      ),
      itemCount: count,
      itemBuilder: (context, i) => builder(context, i, cellW),
    );
  });
}

/// The Vault: one poster per list.
class VaultScreen extends StatefulWidget {
  const VaultScreen({super.key});

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  final _vault = VaultService.instance;

  @override
  void initState() {
    super.initState();
    _vault.addListener(_changed);
    _vault.ensure();
  }

  @override
  void dispose() {
    _vault.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  String _subtitleFor(VaultListDef def) {
    final n = _vault.countFor(def.key);
    if (_vault.buildingListKey == def.key) return 'Updating…';
    if (n > 0) return '$n titles';
    return _vault.isBuilding ? 'Coming up…' : 'No titles yet';
  }

  @override
  Widget build(BuildContext context) {
    const lists = VaultService.lists;
    return RequestInitialFocus(
      child: _VaultFrame(
        title: 'Streamverse',
        subtitle: _vault.isBuilding
            ? 'Refreshing this week\'s lists - titles appear as they are found'
            : 'Only titles available to stream on your server · refreshed weekly',
        body: _grid(
          context: context,
          count: lists.length,
          cardWidth: 170,
          aspectRatio: 2 / 3,
          builder: (context, i, w) {
            final def = lists[i];
            return MediaCard(
              key: ValueKey('vault_${def.key}'),
              title: def.title,
              subtitle: _subtitleFor(def),
              imageUrl: '$kAppAssetImagePrefix${def.asset}',
              width: w,
              aspectRatio: 2 / 3,
              autofocus: i == 0,
              onTap: () => context.push(Destinations.vaultList(def.key)),
            );
          },
        ),
      ),
    );
  }
}

/// One Vault list: up to 30 titles that are on the server.
class VaultListScreen extends StatefulWidget {
  final String listKey;

  const VaultListScreen({super.key, required this.listKey});

  @override
  State<VaultListScreen> createState() => _VaultListScreenState();
}

class _VaultListScreenState extends State<VaultListScreen> {
  final _vault = VaultService.instance;

  @override
  void initState() {
    super.initState();
    _vault.addListener(_changed);
    _vault.ensure();
  }

  @override
  void dispose() {
    _vault.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  String? _imageUrl(AggregatedItem item, double width) {
    final tags = item.rawData['ImageTags'];
    final tag = tags is Map ? tags['Primary']?.toString() : null;
    if (tag == null) return null;
    try {
      return GetIt.instance<MediaServerClient>().imageApi.getPrimaryImageUrl(
            item.id,
            maxWidth: (width * 2).round().clamp(200, 600),
            tag: tag,
          );
    } catch (_) {
      return null;
    }
  }

  String? _subtitle(AggregatedItem item) {
    final y = item.rawData['ProductionYear'];
    return y == null ? null : '$y';
  }

  @override
  Widget build(BuildContext context) {
    final def = VaultService.defFor(widget.listKey);
    final items = _vault.itemsFor(widget.listKey);
    final title = def?.title ?? 'Streamverse';

    Widget body;
    if (items.isEmpty) {
      final building = _vault.isBuilding;
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (building)
              CircularProgressIndicator(color: AppColorScheme.accent),
            if (building) const SizedBox(height: 16),
            Text(
              building
                  ? 'Finding titles on your server…'
                  : 'None of this week\'s titles are on your server yet.',
              style: TextStyle(
                color: AppColorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    } else {
      body = _grid(
        context: context,
        count: items.length,
        cardWidth: 150,
        aspectRatio: 2 / 3,
        builder: (context, i, w) {
          final item = items[i];
          final userData = item.rawData['UserData'];
          final played = userData is Map && userData['Played'] == true;
          final pct = userData is Map
              ? (userData['PlayedPercentage'] as num?)?.toDouble()
              : null;
          return MediaCard(
            key: ValueKey('vault_item_${item.id}'),
            title: item.rawData['Name']?.toString(),
            subtitle: _subtitle(item),
            imageUrl: _imageUrl(item, w),
            width: w,
            aspectRatio: 2 / 3,
            autofocus: i == 0,
            isPlayed: played,
            playedPercentage: pct,
            itemType: item.rawData['Type']?.toString(),
            onTap: () => context.push(
              Destinations.itemOrPhoto(
                item.id,
                serverId: item.serverId,
                type: item.rawData['Type']?.toString(),
              ),
            ),
          );
        },
      );
    }

    return RequestInitialFocus(
      child: _VaultFrame(
        title: title,
        subtitle: items.isEmpty ? null : '${items.length} titles on your server',
        body: body,
      ),
    );
  }
}
