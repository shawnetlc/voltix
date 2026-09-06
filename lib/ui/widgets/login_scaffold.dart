import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:voltix_design/voltix_design.dart';

const _kCardRadius = 20.0;
const _kCardMaxWidth = 700.0;
const _kVoltixCardColor = Color(0xCC111528);

class LoginScaffold extends StatefulWidget {
  final double maxWidth;
  final Widget child;
  final Widget? header;
  final Widget? footer;

  const LoginScaffold({
    super.key,
    this.maxWidth = _kCardMaxWidth,
    this.header,
    this.footer,
    required this.child,
  });

  @override
  State<LoginScaffold> createState() => _LoginScaffoldState();
}

class _LoginScaffoldState extends State<LoginScaffold> with TickerProviderStateMixin {
  late AnimationController _borderController;
  late Animation<Color?> _borderColorAnimation;

  @override
  void initState() {
    super.initState();
    _borderController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat(reverse: true);

    _borderColorAnimation = ColorTween(
      begin: const Color(0x26FFFFFF),
      end: const Color(0x59FFFFFF),
    ).animate(CurvedAnimation(
      parent: _borderController,
      curve: Curves.easeInOut,
    ));
  }

  @override
  void dispose() {
    _borderController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isVoltix = ThemeRegistry.active.id == ThemeRegistry.voltixId;
    final cardColor = isVoltix
        ? _kVoltixCardColor
        : AppColorScheme.surface.withAlpha(0xCC);

    return Scaffold(
      body: WelcomeBackdrop(
        child: SafeArea(
              child: Align(
                alignment: const Alignment(0, -0.6),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: widget.maxWidth),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.header != null) widget.header!,
                        AnimatedBuilder(
                          animation: _borderController,
                          builder: (context, child) {
                            final cardBorder = isVoltix
                                ? Border.all(color: _borderColorAnimation.value ?? const Color(0x33FFFFFF))
                                : Border.fromBorderSide(ThemeRegistry.active.borders.cardBorder);
                            return Container(
                              decoration: BoxDecoration(
                                color: cardColor,
                                borderRadius: BorderRadius.circular(_kCardRadius),
                                border: cardBorder,
                              ),
                              padding: const EdgeInsets.all(32),
                              child: widget.child,
                            );
                          },
                        ),
                        if (widget.footer != null) widget.footer!,
                      ],
                    ),
                  ),
                ),
              ),
            ),
      ),
    );
  }
}

/// The animated gradient + particle backdrop used behind Welcome/Login.
///
/// Also reused behind the setup wizard (both on first run and on "Run Setup
/// Again" from Settings) so re-entering setup doesn't feel like landing on a
/// flatter, unrelated screen.
class WelcomeBackdrop extends StatefulWidget {
  final Widget child;

  const WelcomeBackdrop({super.key, required this.child});

  @override
  State<WelcomeBackdrop> createState() => _WelcomeBackdropState();
}

class _WelcomeBackdropState extends State<WelcomeBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _particleController;

  @override
  void initState() {
    super.initState();
    _particleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
  }

  @override
  void dispose() {
    _particleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isVoltix = ThemeRegistry.active.id == ThemeRegistry.voltixId;
    final gradientColors = isVoltix
        ? const [Color(0xFF0a0a0a), Color(0xFF1a1a2e), Color(0xFF16213e)]
        : [
            AppColorScheme.background,
            AppColorScheme.surfaceVariant,
            AppColorScheme.surface,
          ];

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradientColors,
        ),
        image: isVoltix
            ? const DecorationImage(
                image: AssetImage('assets/images/login_bg.png'),
                fit: BoxFit.cover,
              )
            : null,
      ),
      child: Stack(
        children: [
          if (isVoltix)
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _particleController,
                builder: (context, _) {
                  return CustomPaint(
                    painter: _ParticlePainter(
                      progress: _particleController.value,
                    ),
                  );
                },
              ),
            ),
          widget.child,
        ],
      ),
    );
  }
}

class _ParticlePainter extends CustomPainter {
  final double progress;

  _ParticlePainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    // 20s at 30fps = 600 frames
    final double steppedProgress = (progress * 600).round() / 600.0;
    
    final paint = Paint();
    
    for (int i = 0; i < 20; i++) {
      // Deterministic pseudo-randomness based on particle index
      final double seed1 = (i * 137.5) % 1.0;
      final double seed2 = (i * 93.1) % 1.0;
      final double seed3 = (i * 27.8) % 1.0;
      final double seed4 = (i * 45.2) % 1.0;
      
      // Radius between 3 and 6
      final double radius = 3.0 + seed1 * 3.0;
      
      // Opacity between 0.04 and 0.12
      final double opacity = 0.04 + seed2 * 0.08;
      
      // X drift
      final double startX = seed3 * size.width;
      final double xAmplitude = 20.0 + seed4 * 30.0;
      final double xPhase = seed1 * math.pi * 2;
      final double x = startX + math.sin(steppedProgress * math.pi * 2 + xPhase) * xAmplitude;
      
      // Y drift
      final double startY = seed4 * size.height;
      final double yAmplitude = 30.0 + seed2 * 40.0;
      final double yPhase = seed3 * math.pi * 2;
      final double y = startY + math.sin(steppedProgress * math.pi * 4 + yPhase) * yAmplitude;

      paint.color = Color.fromRGBO(255, 255, 255, opacity);
      canvas.drawCircle(Offset(x, y), radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter oldDelegate) {
    return (progress * 600).round() != (oldDelegate.progress * 600).round();
  }
}
