import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voltix_design/voltix_design.dart';

import 'package:voltix/ui/theme/app_theme.dart';
import 'package:voltix/ui/widgets/grid_button_card.dart';

void main() {
  test('Neon Pulse typography applies themed display styling', () {
    final theme = AppTheme.buildTheme(
      ThemeRegistry.resolveById(ThemeRegistry.neonPulseId),
    );

    expect(theme.textTheme.displayLarge?.fontFamily, 'NeonPulseDisplay');
    expect(theme.textTheme.displayLarge?.shadows?.isNotEmpty, true);
    expect(theme.textTheme.bodyMedium?.letterSpacing, 0.6);
  });

  testWidgets('Grid button renders under Voltix and Neon Pulse', (
    WidgetTester tester,
  ) async {
    Future<void> pumpForTheme(String themeId) async {
      ThemeRegistry.setActiveById(themeId);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.buildTheme(ThemeRegistry.resolveById(themeId)),
          home: Scaffold(
            body: Center(
              child: GridButtonCard(
                icon: Icons.play_arrow,
                label: 'Play',
                onTap: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(GridButtonCard), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    }

    await pumpForTheme(ThemeRegistry.voltixId);
    await pumpForTheme(ThemeRegistry.neonPulseId);
  });
}
