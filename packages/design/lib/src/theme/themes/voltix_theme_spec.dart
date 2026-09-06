import 'package:flutter/material.dart';

import '../app_colors.dart';
import '../theme_spec.dart';

const voltixThemeSpec = ThemeSpec(
  id: 'voltix',
  displayName: 'Voltix',
  colors: ThemeColorTokens(
    background: Color(0xFF090D16),
    onBackground: AppColors.white,
    surface: Color(0xFF111726),
    onSurface: AppColors.white,
    surfaceVariant: Color(0xFF1A2238),
    scrim: Color(0xCC090D16),
    accent: Color(0xFF3872FF),
    onAccent: AppColors.white,
    buttonNormal: Color(0xFF182032),
    buttonFocused: Color(0xFF3872FF),
    buttonDisabled: Color(0xFF101624),
    buttonActive: Color(0xFF222D46),
    onButtonNormal: AppColors.white,
    onButtonFocused: AppColors.white,
    onButtonDisabled: Color(0xFF55607A),
    inputBackground: Color(0xFF141B2D),
    inputFocused: Color(0xFF1E2840),
    inputBorder: Color(0xFF2E3D60),
    inputBorderFocused: Color(0xFF3872FF),
    rangeTrack: Color(0xFF24304D),
    rangeProgress: Color(0xFF3872FF),
    rangeThumb: Color(0xFF3872FF),
    seekbarBuffered: Color(0x803872FF),
    badgeBackground: Color(0xFF3872FF),
    onBadge: AppColors.white,
    badgeUnplayed: Color(0xFF3872FF),
    badgeWatched: AppColors.green500,
    recordingActive: AppColors.red500,
    recordingScheduled: AppColors.orange500,
  ),
  borders: ThemeBorderTokens(
    cardBorder: BorderSide(color: Color(0x1A3872FF), width: 1),
    chipBorder: BorderSide(color: Color(0x403872FF)),
    focusBorder: BorderSide(color: Color(0xFF3872FF), width: 2),
    cardRadius: BorderRadius.all(Radius.circular(10)),
    chipRadius: BorderRadius.all(Radius.circular(999)),
    chipBackground: Color(0x1A3872FF),
    focusGlow: [
      BoxShadow(
        color: Color(0x663872FF),
        blurRadius: 12,
        spreadRadius: 2,
      ),
    ],
  ),
);
