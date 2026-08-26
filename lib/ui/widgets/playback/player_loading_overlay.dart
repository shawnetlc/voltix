import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Canonical size for the Voltix bolt in playback loading overlays.
///
/// Every overlay shown during a single playback bring-up **must** use the same
/// values, otherwise the spinner visibly resizes and shifts as the player moves
/// between phases (bring-up → buffering → seeking).
const double kPlayerLoadingLogoSize = 180;
const double kPlayerLoadingLabelSpacing = 60;

class PlayerLoadingOverlay extends StatefulWidget {
  const PlayerLoadingOverlay({
    super.key,
    this.label,
    this.logoSize = kPlayerLoadingLogoSize,
    this.labelSpacing = kPlayerLoadingLabelSpacing,
  });

  final String? label;
  final double logoSize;
  final double labelSpacing;

  @override
  State<PlayerLoadingOverlay> createState() => _PlayerLoadingOverlayState();
}

class _PlayerLoadingOverlayState extends State<PlayerLoadingOverlay>
    with TickerProviderStateMixin {
  /// One full flip of the bolt.
  static const Duration _spinPeriod = Duration(seconds: 8);

  /// Never let the bolt squash below this fraction of its width. A raw
  /// `cos(angle)` reaches 0 at 90°/270°, which made the logo vanish and then
  /// snap back — read as the spinner "changing size".
  static const double _minScaleX = 0.18;

  /// Shared clock so the spin phase is continuous across widget instances.
  ///
  /// The player swaps between two different overlay subtrees (bring-up and
  /// buffering). Each swap builds a fresh [State] with a fresh controller, and
  /// a per-instance controller restarts from 0 — the bolt jumped back to
  /// face-on every time. Deriving the phase from a process-wide stopwatch keeps
  /// the rotation exactly where the previous overlay left it.
  static final Stopwatch _sharedClock = Stopwatch()..start();

  late final AnimationController _ticker;
  late final AnimationController _labelController;
  late final Animation<double> _labelOpacity;
  late final Animation<double> _labelScale;

  // Voltix brand gradient (teal → cyan-blue), replacing the old Moonfin pink.
  static const _labelGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFF2BE0C6), Color(0xFF1E90FF)],
  );

  @override
  void initState() {
    super.initState();
    // Drives repaints only; the angle itself comes from [_sharedClock].
    _ticker = AnimationController(
      duration: _spinPeriod,
      vsync: this,
    )..repeat();
    _labelController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat(reverse: true);

    final pulseCurve = CurvedAnimation(
      parent: _labelController,
      curve: Curves.easeInOut,
    );
    _labelOpacity = Tween<double>(begin: 0.4, end: 1.0).animate(pulseCurve);
    _labelScale = Tween<double>(begin: 0.98, end: 1.0).animate(pulseCurve);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _labelController.dispose();
    super.dispose();
  }

  double get _spinPhase {
    final periodMs = _spinPeriod.inMilliseconds;
    return (_sharedClock.elapsedMilliseconds % periodMs) / periodMs;
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.label?.trim();
    final hasLabel = label != null && label.isNotEmpty;
    final uppercaseLabel = hasLabel ? label.toUpperCase() : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Fixed-size box: the transform below scales its child, and without a
        // reserved slot the surrounding Column re-measured on every frame,
        // which nudged the whole stack up and down.
        SizedBox(
          width: widget.logoSize,
          height: widget.logoSize,
          child: AnimatedBuilder(
            animation: _ticker,
            builder: (context, child) {
              final angle = _spinPhase * 2 * math.pi;
              // Horizontal foreshortening of a flat logo rotating about Y.
              // abs() keeps the bolt facing the viewer instead of rendering
              // mirrored through the back half of the turn; the floor stops it
              // from collapsing to nothing at the quarter turns.
              final scaleX =
                  math.max(math.cos(angle).abs(), _minScaleX);
              return Transform(
                alignment: Alignment.center,
                // No perspective entry: perspective shifted the logo sideways
                // as it turned, which looked like the spinner hopping.
                transform: Matrix4.identity()
                  ..scaleByDouble(scaleX, 1.0, 1.0, 1.0),
                child: child,
              );
            },
            child: Image.asset(
              'assets/images/voltix_bolt.png',
              width: widget.logoSize,
              height: widget.logoSize,
              fit: BoxFit.contain,
            ),
          ),
        ),
        if (hasLabel) ...[
          SizedBox(height: widget.labelSpacing),
          FadeTransition(
            opacity: _labelOpacity,
            child: ScaleTransition(
              scale: _labelScale,
              child: ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (bounds) {
                  return _labelGradient.createShader(bounds);
                },
                child: Text(
                  uppercaseLabel!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 6,
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
