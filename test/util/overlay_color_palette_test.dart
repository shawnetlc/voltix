import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voltix/util/overlay_color_palette.dart';

void main() {
  group('OverlayColorPalette Voltix Cyan rebrand', () {
    test('contains voltixCyan in keys', () {
      expect(OverlayColorPalette.keys.contains('voltixCyan'), isTrue);
      expect(OverlayColorPalette.keys.contains('moonfinCyan'), isFalse);
    });

    test('maps old moonfinCyan aliases and voltix variants to voltixCyan', () {
      expect(OverlayColorPalette.normalizeKey('moonfinCyan'), 'voltixCyan');
      expect(OverlayColorPalette.normalizeKey('moonfin_cyan'), 'voltixCyan');
      expect(OverlayColorPalette.normalizeKey('moonfincyan'), 'voltixCyan');
      expect(OverlayColorPalette.normalizeKey('voltixCyan'), 'voltixCyan');
      expect(OverlayColorPalette.normalizeKey('voltix_cyan'), 'voltixCyan');
      expect(OverlayColorPalette.normalizeKey('voltixcyan'), 'voltixCyan');
    });

    test('resolves voltixCyan to Color(0xFF00A4DC)', () {
      expect(OverlayColorPalette.resolveColor('voltixCyan'), const Color(0xFF00A4DC));
      expect(OverlayColorPalette.resolveColor('moonfinCyan'), const Color(0xFF00A4DC));
    });

    test('pickerSwatches has voltixCyan with 0xFF00A4DC', () {
      expect(OverlayColorPalette.pickerSwatches['voltixCyan'], 0xFF00A4DC);
      expect(OverlayColorPalette.pickerSwatches.containsKey('moonfinCyan'), isFalse);
    });
  });
}
