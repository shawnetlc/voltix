import 'dart:math' as math;
import 'package:flutter/material.dart';

class VoltixLoadingIndicator extends StatefulWidget {
  final double size;
  final bool animate;

  const VoltixLoadingIndicator({
    super.key,
    this.size = 48.0,
    this.animate = true,
  });

  const VoltixLoadingIndicator.small({
    super.key,
    this.size = 24.0,
    this.animate = true,
  });

  @override
  State<VoltixLoadingIndicator> createState() => _VoltixLoadingIndicatorState();
}

class _VoltixLoadingIndicatorState extends State<VoltixLoadingIndicator>
    with SingleTickerProviderStateMixin {
  static const Duration _spinPeriod = Duration(milliseconds: 1500);

  /// Floor on the horizontal foreshortening so the bolt never collapses to
  /// nothing at the quarter turns (which read as the spinner resizing).
  static const double _minScaleX = 0.18;

  /// Shared clock so the spin phase survives remounts — a per-instance
  /// controller restarted from 0 every time the indicator was rebuilt, making
  /// the bolt snap back to face-on.
  static final Stopwatch _sharedClock = Stopwatch()..start();

  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _spinPeriod,
    );
    if (widget.animate) {
      _controller.repeat();
    }
  }

  double get _spinPhase {
    if (!widget.animate) return 0;
    final periodMs = _spinPeriod.inMilliseconds;
    return (_sharedClock.elapsedMilliseconds % periodMs) / periodMs;
  }

  @override
  void didUpdateWidget(VoltixLoadingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate && !oldWidget.animate) {
      _controller.repeat();
    } else if (!widget.animate && oldWidget.animate) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          // Horizontal foreshortening only. The previous version combined a
          // perspective rotateY (which drifted the bolt sideways) with a
          // uniform 0.8–1.0 "compression" pump (which changed its overall
          // size every half turn). Both read as a spinner that hops and
          // resizes, so only the flip itself is kept.
          final angle = _spinPhase * 2 * math.pi;
          final scaleX = math.max(math.cos(angle).abs(), _minScaleX);
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..scaleByDouble(scaleX, 1.0, 1.0, 1.0),
            child: child,
          );
        },
        // Render the bolt in its native Voltix colour scheme (no flat tint,
        // which previously overrode the blue gradient with a single colour).
        child: Image.asset(
          'assets/images/voltix_bolt.png',
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}
