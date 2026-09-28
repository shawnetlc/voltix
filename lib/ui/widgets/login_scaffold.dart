import 'package:flutter/material.dart';
import 'package:voltix_design/voltix_design.dart';

import '../../util/hardware_capability.dart';
import 'package:get_it/get_it.dart';

import '../../preference/user_preferences.dart';
import '../../preference/preference_constants.dart';

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

class _LoginScaffoldState extends State<LoginScaffold> {
  @override
  Widget build(BuildContext context) {
    final isVoltix = ThemeRegistry.active.id == ThemeRegistry.voltixId;
    final cardColor = isVoltix
        ? _kVoltixCardColor
        : AppColorScheme.surface.withAlpha(0xCC);

    final cardBorder = isVoltix
        ? Border.all(color: const Color(0x33FFFFFF))
        : Border.fromBorderSide(ThemeRegistry.active.borders.cardBorder);

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
                    Container(
                      decoration: BoxDecoration(
                        color: cardColor,
                        borderRadius: BorderRadius.circular(_kCardRadius),
                        border: cardBorder,
                      ),
                      padding: const EdgeInsets.all(32),
                      child: widget.child,
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

/// The gradient backdrop used behind Welcome/Login and setup wizards.
/// Optimized for low-end GPU devices: renders static gradients and backdrop
/// images without continuous canvas repaints.
class WelcomeBackdrop extends StatefulWidget {
  final Widget child;

  const WelcomeBackdrop({super.key, required this.child});

  @override
  State<WelcomeBackdrop> createState() => _WelcomeBackdropState();
}

class _WelcomeBackdropState extends State<WelcomeBackdrop> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        HardwareCapability.checkAndApplyOptimization(context);
      }
    });
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

    final loginBackgroundAsset = GetIt.instance<UserPreferences>()
        .get(UserPreferences.appBackgroundStyle)
        .loginBackgroundAsset;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradientColors,
        ),
        // Always show the background image — not just for the Voltix theme.
        image: DecorationImage(
          image: AssetImage(loginBackgroundAsset),
          fit: BoxFit.cover,
        ),
      ),
      child: widget.child,
    );
  }
}
