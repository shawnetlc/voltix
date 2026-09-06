import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:voltix_design/voltix_design.dart';

import '../../../../widgets/adaptive/adaptive_glass.dart';

/// Landscape hero band that previews the focused program and its channel. Pure
/// presentation; the host feeds it the focused values (typically via a
/// ValueListenableBuilder) so only this band rebuilds as focus moves. Idiom
/// aware: frosted glass on Apple, a tokenized translucent panel on Material.
class EpgHeroPreview extends StatelessWidget {
  final String? title;
  final String? timeLabel;
  final String? genreLabel;
  final String? synopsis;
  final String? channelLogoUrl;
  final String? channelName;
  final String? channelNumber;
  final bool isLive;
  final bool apple;
  /// Programme artwork. Optional: falls back to a channel-tinted placeholder
  /// so the band keeps its shape while focus moves between items that do and
  /// do not have art.
  final String? imageUrl;
  /// Shown as a Play button when provided. Kept out of the focus order on
  /// purpose -- the list itself is what the remote drives, and OK on a
  /// programme already starts playback; this is for pointer users.
  final VoidCallback? onPlay;
  final String playLabel;

  const EpgHeroPreview({
    super.key,
    required this.title,
    required this.timeLabel,
    required this.genreLabel,
    required this.synopsis,
    required this.channelLogoUrl,
    required this.channelName,
    required this.channelNumber,
    required this.isLive,
    required this.apple,
    this.imageUrl,
    this.onPlay,
    this.playLabel = 'Watch',
  });

  Widget _artwork() {
    const w = 168.0;
    const h = 94.0;
    final placeholder = Container(
      width: w,
      height: h,
      color: AppColorScheme.onSurface.withValues(alpha: 0.06),
      child: Icon(
        Icons.live_tv,
        color: AppColorScheme.onSurface.withValues(alpha: 0.28),
        size: 30,
      ),
    );
    return ClipRRect(
      borderRadius: AppRadius.circular(apple ? 14 : 10),
      child: (imageUrl != null && imageUrl!.isNotEmpty)
          ? CachedNetworkImage(
              imageUrl: imageUrl!,
              width: w,
              height: h,
              fit: BoxFit.cover,
              fadeInDuration: const Duration(milliseconds: 140),
              placeholder: (_, _) => placeholder,
              errorWidget: (_, _, _) => placeholder,
            )
          : placeholder,
    );
  }

  Widget _playButton(TextTheme textTheme) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Material(
          color: AppColorScheme.accent,
          borderRadius: AppRadius.circular(999),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: onPlay,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.play_arrow_rounded,
                      size: 18, color: AppColorScheme.onAccent),
                  const SizedBox(width: 4),
                  Text(
                    playLabel,
                    style: textTheme.labelLarge?.copyWith(
                      color: AppColorScheme.onAccent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final muted = AppColorScheme.onSurface.withValues(alpha: 0.7);
    final meta = [
      if (isLive) 'Live',
      if (timeLabel != null) timeLabel,
      if (genreLabel != null && genreLabel!.isNotEmpty) genreLabel,
    ].whereType<String>().join('  ·  ');

    final inner = Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _artwork(),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleLarge,
                ),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyMedium?.copyWith(color: muted)),
                ],
                if (synopsis != null && synopsis!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(synopsis!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                          color: AppColorScheme.onSurface.withValues(alpha: 0.6))),
                ],
                if (onPlay != null) _playButton(textTheme),
              ],
            ),
          ),
          if (channelName != null) ...[
            const SizedBox(width: 20),
            _channelBlock(textTheme, muted),
          ],
        ],
      ),
    );

    return apple
        ? adaptiveGlass(
            context: context,
            cornerRadius: 18,
            blur: 18,
            fallbackColor: AppColorScheme.surface.withValues(alpha: 0.4),
            tint: Colors.white.withValues(alpha: 0.06),
            child: inner,
          )
        : DecoratedBox(
            decoration: BoxDecoration(
              color: AppColorScheme.surface.withValues(alpha: 0.45),
              borderRadius: AppRadius.circular(16),
            ),
            child: inner,
          );
  }

  Widget _channelBlock(TextTheme textTheme, Color muted) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 46,
            height: 46,
            child: ClipRRect(
              borderRadius: AppRadius.circular(apple ? 12 : 8),
              child: (channelLogoUrl != null && channelLogoUrl!.isNotEmpty)
                  ? CachedNetworkImage(
                      imageUrl: channelLogoUrl!,
                      fit: BoxFit.contain,
                      errorWidget: (context, url, error) => Icon(Icons.tv,
                          color: AppColorScheme.onSurface.withValues(alpha: 0.4)),
                    )
                  : Icon(Icons.tv,
                      color: AppColorScheme.onSurface.withValues(alpha: 0.4)),
            ),
          ),
          const SizedBox(width: 10),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(channelName!, style: textTheme.titleSmall),
              if (channelNumber != null) ...[
                const SizedBox(height: 2),
                Text(channelNumber!,
                    style: textTheme.labelMedium?.copyWith(color: muted)),
              ],
            ],
          ),
        ],
      );
}
