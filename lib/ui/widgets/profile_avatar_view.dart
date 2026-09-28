import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:voltix_design/voltix_design.dart';

class BuiltInAvatar {
  final String id;
  final String name;
  final String assetPath;
  final String category;

  const BuiltInAvatar({
    required this.id,
    required this.name,
    required this.assetPath,
    required this.category,
  });
}

const List<BuiltInAvatar> kBuiltInAvatars = [
  // ── Voltix Ambassador & Pride ──
  BuiltInAvatar(
    id: 'ambassador_hero',
    name: 'Voltix Hero',
    assetPath: 'assets/avatars/ambassador_hero.jpg',
    category: 'Voltix Ambassador',
  ),
  BuiltInAvatar(
    id: 'ambassador_pride',
    name: 'Voltix Pride',
    assetPath: 'assets/avatars/ambassador_pride.jpg',
    category: 'Voltix Ambassador',
  ),
  BuiltInAvatar(
    id: 'voltix_queen',
    name: 'Cyber Queen',
    assetPath: 'assets/avatars/voltix_queen.jpg',
    category: 'Voltix Ambassador',
  ),
  BuiltInAvatar(
    id: 'ambassador_vip',
    name: 'Voltix VIP',
    assetPath: 'assets/avatars/ambassador_vip.jpg',
    category: 'Voltix Ambassador',
  ),
  BuiltInAvatar(
    id: 'ambassador_gamer',
    name: 'Voltix Streamer',
    assetPath: 'assets/avatars/ambassador_gamer.jpg',
    category: 'Voltix Ambassador',
  ),
  BuiltInAvatar(
    id: 'cyber_valkyrie',
    name: 'Neon Valkyrie',
    assetPath: 'assets/avatars/cyber_valkyrie.jpg',
    category: 'Voltix Ambassador',
  ),
  BuiltInAvatar(
    id: 'cyber_ninja',
    name: 'Shadow Ninja',
    assetPath: 'assets/avatars/cyber_ninja.jpg',
    category: 'Voltix Ambassador',
  ),
  BuiltInAvatar(
    id: 'voltix_prime',
    name: 'Voltix Prime',
    assetPath: 'assets/avatars/voltix_prime.jpg',
    category: 'Voltix Ambassador',
  ),

  BuiltInAvatar(
    id: 'cyber_kunoichi',
    name: 'Neon Kunoichi',
    assetPath: 'assets/avatars/cyber_kunoichi.jpg',
    category: 'Voltix Ambassador',
  ),

  // ── Funny & Mascots ──
  BuiltInAvatar(
    id: 'funny_popcorn',
    name: 'Neon Popcorn',
    assetPath: 'assets/avatars/funny_popcorn.jpg',
    category: 'Funny & Mascots',
  ),
  BuiltInAvatar(
    id: 'neon_cat',
    name: 'Cyber Kitty',
    assetPath: 'assets/avatars/neon_cat.jpg',
    category: 'Funny & Mascots',
  ),
  BuiltInAvatar(
    id: 'space_pug',
    name: 'Astro Pug',
    assetPath: 'assets/avatars/space_pug.jpg',
    category: 'Funny & Mascots',
  ),
  BuiltInAvatar(
    id: 'gamer_bear',
    name: 'Gamer Bear',
    assetPath: 'assets/avatars/gamer_bear.jpg',
    category: 'Funny & Mascots',
  ),
  BuiltInAvatar(
    id: 'cyber_pup',
    name: 'Robo Pup',
    assetPath: 'assets/avatars/cyber_pup.jpg',
    category: 'Funny & Mascots',
  ),
  BuiltInAvatar(
    id: 'funny_bot',
    name: 'Voltix Mini',
    assetPath: 'assets/avatars/funny_bot.jpg',
    category: 'Funny & Mascots',
  ),
  BuiltInAvatar(
    id: 'retro_arcade',
    name: 'Pixel Blaster',
    assetPath: 'assets/avatars/retro_arcade.jpg',
    category: 'Funny & Mascots',
  ),
  BuiltInAvatar(
    id: 'funny_couch',
    name: 'Couch Potato',
    assetPath: 'assets/avatars/funny_couch.jpg',
    category: 'Funny & Mascots',
  ),

  // ── Kids & Fantasy ──
  BuiltInAvatar(
    id: 'blonde_boy',
    name: 'Blonde Scout',
    assetPath: 'assets/avatars/blonde_boy.jpg',
    category: 'Kids & Fantasy',
  ),
  BuiltInAvatar(
    id: 'little_princess',
    name: 'Star Princess',
    assetPath: 'assets/avatars/little_princess.jpg',
    category: 'Kids & Fantasy',
  ),
  BuiltInAvatar(
    id: 'baby_dragon',
    name: 'Baby Dragon',
    assetPath: 'assets/avatars/baby_dragon.jpg',
    category: 'Kids & Fantasy',
  ),
  BuiltInAvatar(
    id: 'super_kid',
    name: 'Super Spark',
    assetPath: 'assets/avatars/super_kid.jpg',
    category: 'Kids & Fantasy',
  ),
  BuiltInAvatar(
    id: 'cosmic_astronaut',
    name: 'Astro Lyra',
    assetPath: 'assets/avatars/cosmic_astronaut.jpg',
    category: 'Kids & Fantasy',
  ),
];

/// A unified avatar display widget supporting bundled local asset avatars,
/// remote cloud URLs, custom fallback initials, and emojis.
class ProfileAvatarView extends StatelessWidget {
  final String? avatarUrl;
  final String? emoji;
  final String? fallbackText;
  final Color backgroundColor;
  final double size;
  final double borderRadius;
  final bool showNeonBorder;
  final Color? borderColor;

  const ProfileAvatarView({
    super.key,
    this.avatarUrl,
    this.emoji,
    this.fallbackText,
    this.backgroundColor = const Color(0xFF3B82F6),
    this.size = 100,
    this.borderRadius = 20,
    this.showNeonBorder = false,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveBorderColor = borderColor ??
        (showNeonBorder ? AppColorScheme.accent : Colors.transparent);

    Widget innerContent;

    if (avatarUrl != null && avatarUrl!.isNotEmpty) {
      if (avatarUrl!.startsWith('assets/')) {
        innerContent = Image.asset(
          avatarUrl!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _buildFallback(),
        );
      } else {
        innerContent = CachedNetworkImage(
          imageUrl: avatarUrl!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          placeholder: (_, _) => Container(
            color: backgroundColor,
            child: const Center(
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white24),
            ),
          ),
          errorWidget: (_, _, _) => _buildFallback(),
        );
      }
    } else {
      innerContent = _buildFallback();
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(
          color: effectiveBorderColor,
          width: showNeonBorder ? 2.5 : 1.5,
        ),
        boxShadow: showNeonBorder
            ? [
                BoxShadow(
                  color: effectiveBorderColor.withValues(alpha: 0.5),
                  blurRadius: 12,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(
          borderRadius > 2 ? borderRadius - 2 : borderRadius,
        ),
        child: innerContent,
      ),
    );
  }

  Widget _buildFallback() {
    final hasEmoji = emoji != null && emoji!.isNotEmpty;
    final initial = (fallbackText != null && fallbackText!.isNotEmpty)
        ? fallbackText!.substring(0, 1).toUpperCase()
        : '?';

    return Container(
      color: backgroundColor,
      alignment: Alignment.center,
      child: Text(
        hasEmoji ? emoji! : initial,
        style: TextStyle(
          fontSize: hasEmoji ? size * 0.5 : size * 0.42,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
    );
  }
}
