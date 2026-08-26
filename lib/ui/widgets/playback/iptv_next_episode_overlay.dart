import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../data/services/iptv_progress_reporter.dart';

/// Bottom-right "Next episode" card shown near the end of an IPTV series
/// episode. Displays the upcoming episode with a live countdown; plays it at
/// zero (driven by the reporter) or on "Play now", and can be dismissed.
///
/// Deliberately lightweight and TV-friendly: no timers of its own (the seconds
/// come from [IptvNextEpisodePrompt.secondsRemaining], updated by the reporter),
/// D-pad focusable buttons, no heavy effects.
class IptvNextEpisodeOverlay extends StatelessWidget {
  final IptvNextEpisodePrompt prompt;
  final VoidCallback onPlayNow;
  final VoidCallback onCancel;

  const IptvNextEpisodeOverlay({
    super.key,
    required this.prompt,
    required this.onPlayNow,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final poster = prompt.poster;
    return Positioned(
      right: 32,
      bottom: 32,
      child: Container(
        width: 420,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xF20F141C),
          borderRadius: const BorderRadius.all(Radius.circular(14)),
          border: Border.all(color: const Color(0x331E90FF)),
          boxShadow: const [
            BoxShadow(color: Color(0x99000000), blurRadius: 18),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              prompt.secondsRemaining > 0
                  ? 'Next episode in ${prompt.secondsRemaining}s'
                  : 'Playing next episode…',
              style: const TextStyle(
                color: Color(0xFF7FBFFF),
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (poster != null && poster.isNotEmpty) ...[
                  ClipRRect(
                    borderRadius: const BorderRadius.all(Radius.circular(6)),
                    child: CachedNetworkImage(
                      imageUrl: poster,
                      width: 92,
                      height: 52,
                      fit: BoxFit.cover,
                      memCacheWidth: 200,
                      errorWidget: (_, _, _) =>
                          const SizedBox(width: 92, height: 52),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        prompt.seriesTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        prompt.episodeLabel,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: onCancel,
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white70,
                  ),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  autofocus: true,
                  onPressed: onPlayNow,
                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                  label: const Text('Play now'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1E90FF),
                    foregroundColor: Colors.white,
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(8)),
                    ),
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
