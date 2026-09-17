import 'dart:async';

import 'package:flutter/material.dart';
import 'package:voltix_design/voltix_design.dart';

import '../../util/platform_detection.dart';

class FloatingNotification {
  FloatingNotification._();

  /// How long the card stays up when the caller does not say.
  static const defaultDuration = Duration(seconds: 7);

  static void show(
    BuildContext context,
    String title,
    String body,
    VoidCallback? onTap, {
    /// How long before it dismisses itself. On TV this comes from the admin
    /// portal, carried in the push payload — a banner on a television is read
    /// from across a room, and seven seconds is not always enough.
    Duration? duration,

    /// Artwork from the notification, when the push carries one. A failure to
    /// load is swallowed: a banner with no picture is still the message.
    String? imageUrl,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (entryContext) => _FloatingNotificationCard(
        title: title,
        body: body,
        onTap: onTap,
        duration: duration ?? defaultDuration,
        imageUrl: imageUrl,
        onDismissed: () {
          if (entry.mounted) entry.remove();
        },
      ),
    );
    overlay.insert(entry);
  }
}

class _FloatingNotificationCard extends StatefulWidget {
  final String title;
  final String body;
  final VoidCallback? onTap;
  final VoidCallback onDismissed;
  final Duration duration;
  final String? imageUrl;

  const _FloatingNotificationCard({
    required this.title,
    required this.body,
    required this.onTap,
    required this.onDismissed,
    required this.duration,
    this.imageUrl,
  });

  @override
  State<_FloatingNotificationCard> createState() =>
      _FloatingNotificationCardState();
}

class _FloatingNotificationCardState extends State<_FloatingNotificationCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;
  Timer? _autoDismissTimer;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    // Enters from the direction it sits in: down from the top edge on a TV,
    // in from the right on a phone. A centred banner sliding in sideways reads
    // as something being dragged across the screen rather than arriving.
    _slide = Tween<Offset>(
      begin: PlatformDetection.useLeanbackUi
          ? const Offset(0, -0.3)
          : const Offset(0.2, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _controller.forward();
    _autoDismissTimer = Timer(widget.duration, _dismiss);
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _dismiss() {
    if (_dismissing) return;
    _dismissing = true;
    _autoDismissTimer?.cancel();
    _controller.reverse().whenComplete(widget.onDismissed);
  }

  void _handleTap() {
    widget.onTap?.call();
    _dismiss();
  }

  @override
  Widget build(BuildContext context) {
    final isTv = PlatformDetection.useLeanbackUi;
    final tappable = !isTv && widget.onTap != null;

    // A phone banner is read at arm's length; a TV banner is read from a sofa.
    // Same card, more of it.
    final scale = isTv ? 1.35 : 1.0;
    final image = widget.imageUrl?.trim();

    // With artwork, the picture IS the notification: a poster or a still says
    // "new film" faster than any wording, and at TV distance a 56px thumbnail
    // says nothing at all. So the image fills the card and the text sits over
    // it, rather than the image being a stamp beside the text.
    //
    // Everything below the gradient has to stay legible over artwork nobody has
    // vetted — it may be bright, busy, or mostly white. Hence a scrim that goes
    // fully opaque behind the text rather than a uniform wash: the top of the
    // image stays clean, and the words sit on something solid.
    // Guarded on `image` itself rather than a separate `hasImage` bool, so the
    // local promotes to non-null for the Image.network call below.
    if (image != null && image.isNotEmpty) {
      final cardWidth = isTv ? 560.0 : 340.0;
      final imageHeight = cardWidth * 9 / 16;

      final imageCard = Container(
        width: cardWidth,
        decoration: BoxDecoration(
          color: AppColorScheme.surface.withValues(alpha: 0.96),
          borderRadius: AppRadius.circular(14),
          border: Border.all(
            color: AppColorScheme.accent.withValues(alpha: 0.4),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: AppColorScheme.scrim.withValues(alpha: 0.45),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          // 13, not 14: the border sits outside this, and matching the outer
          // radius exactly leaves a hairline of image bleeding past it.
          borderRadius: AppRadius.circular(13),
          child: SizedBox(
            height: imageHeight,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Image.network(
                  image,
                  fit: BoxFit.cover,
                  // A broken or slow image must never cost the message. The
                  // card keeps its shape and the text reads on the surface
                  // colour underneath, so a failed load degrades to a plain
                  // banner instead of a gap.
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  loadingBuilder: (context, child, progress) =>
                      progress == null ? child : const SizedBox.shrink(),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        AppColorScheme.scrim.withValues(alpha: 0.0),
                        AppColorScheme.scrim.withValues(alpha: 0.55),
                        AppColorScheme.scrim.withValues(alpha: 0.92),
                      ],
                      stops: const [0.35, 0.65, 1.0],
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      16 * scale,
                      12 * scale,
                      16 * scale,
                      14 * scale,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.title.isNotEmpty)
                          Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16 * scale,
                              fontWeight: FontWeight.w700,
                              shadows: const [
                                Shadow(blurRadius: 6, color: Colors.black54),
                              ],
                            ),
                          ),
                        if (widget.body.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            widget.body,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.92),
                              fontSize: 12.5 * scale,
                              shadows: const [
                                Shadow(blurRadius: 6, color: Colors.black54),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      return _position(isTv, tappable, imageCard);
    }

    final card = Container(
      constraints: BoxConstraints(maxWidth: isTv ? 520 : 380),
      padding: EdgeInsets.symmetric(
        horizontal: 16 * scale,
        vertical: 12 * scale,
      ),
      decoration: BoxDecoration(
        color: AppColorScheme.surface.withValues(alpha: 0.96),
        borderRadius: AppRadius.circular(14),
        border: Border.all(
          color: AppColorScheme.accent.withValues(alpha: 0.4),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColorScheme.scrim.withValues(alpha: 0.35),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // No artwork on this notification — the image path returns above.
          Icon(
            Icons.notifications_active_outlined,
            color: AppColorScheme.accent,
            size: 20 * scale,
          ),
          SizedBox(width: 12 * scale),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.title.isNotEmpty)
                  Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColorScheme.onSurface,
                      fontSize: 14 * scale,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (widget.body.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    widget.body,
                    maxLines: isTv ? 3 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColorScheme.onSurface.withValues(alpha: 0.8),
                      fontSize: 12 * scale,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );

    return _position(isTv, tappable, card);
  }

  /// Places a finished card on screen, animated in.
  ///
  /// Shared by the artwork and text-only layouts so the two cannot drift apart
  /// in where they appear or how they arrive.
  ///
  /// Top centre on a television, top right everywhere else. A phone is held
  /// square-on and a corner banner stays clear of what you are reading. A TV is
  /// watched from across a room and often off to one side, so the top corner is
  /// the easiest part of the screen to miss — on a wide set it can be most of a
  /// metre from where someone is actually looking. Centred puts it where the
  /// eye already is.
  Widget _position(bool isTv, bool tappable, Widget card) {
    final animated = FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: tappable
            ? Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: AppRadius.circular(14),
                  onTap: _handleTap,
                  child: card,
                ),
              )
            : card,
      ),
    );

    // `left: 0` as well as `right: 0` is what gives the Positioned a width to
    // centre within; with only `right: 0` it shrink-wraps to the card and Align
    // has nothing to work with.
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Align(
            alignment: isTv ? Alignment.topCenter : Alignment.topRight,
            child: animated,
          ),
        ),
      ),
    );
  }
}
