import 'package:flutter/material.dart';
import 'package:voltix_design/voltix_design.dart';
import 'voltix_loading_indicator.dart';

class VoltixStreamLoading extends StatefulWidget {
  final String message;

  const VoltixStreamLoading({
    super.key,
    this.message = 'Loading your stream...',
  });

  @override
  State<VoltixStreamLoading> createState() => _VoltixStreamLoadingState();
}

class _VoltixStreamLoadingState extends State<VoltixStreamLoading>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(
        parent: _pulseController,
        curve: Curves.easeInOut,
      ),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.8),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const VoltixLoadingIndicator(size: 80),
            const SizedBox(height: 24),
            AnimatedBuilder(
              animation: _pulseAnimation,
              builder: (context, child) {
                return Opacity(
                  opacity: _pulseAnimation.value,
                  child: Text(
                    widget.message,
                    style: TextStyle(
                      color: AppColorScheme.accent,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.2,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
