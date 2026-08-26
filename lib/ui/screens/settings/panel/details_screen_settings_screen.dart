part of '../settings_side_panel.dart';

/// Details screen settings, gathered onto their own screen the way upstream
/// 2.4.0 has them. These used to sit in General Style.
///
/// Three upstream controls are deliberately absent, because the code they
/// would drive does not exist in Voltix yet — a switch that does nothing is
/// worse than no switch:
///
///  * `detailScreenStyle` (Classic vs Modern) and `detailExpandedTabs` need
///    upstream's `ui/screens/detail/modern/` subsystem (~200 KB), which Voltix
///    does not have at all.
///  * `detailShowTechnicalDetails` needs the `technicalDetailsFor` helper,
///    which Voltix does not have.
///
/// The preferences themselves are already defined, so adding the tiles here is
/// the last step once those consumers are ported.
class _DetailsScreenSettingsScreen extends StatelessWidget {
  const _DetailsScreenSettingsScreen();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return withCleanSettingsTypography(
      context,
      Scaffold(
        appBar: buildSettingsAppBar(context, const Text('Details Screen')),
        body: ListView(
          children: [
            adaptiveListSection(
              children: [
              SliderPreferenceTile(
                preference: UserPreferences.detailsBackgroundBlurAmount,
                title: l10n.detailsBackgroundBlur,
                icon: Icons.blur_on,
                min: 0,
                max: 25,
                divisions: 25,
                labelOf: (v) => '$v',
                onChangeEnd: _pushPersonalizationSync,
              ),
              EnumPreferenceTile<RecommendationSystemSource>(
                preference: UserPreferences.recommendationSystemSource,
                title: 'Recommendation system',
                icon: Icons.recommend,
                labelOf: (v) => switch (v) {
                  RecommendationSystemSource.local => 'Voltix Recommends',
                  RecommendationSystemSource.online => 'TMDB similarity',
                },
                onChanged: _pushPersonalizationSync,
              ),
              SwitchPreferenceTile(
                preference: UserPreferences.recommendationsApplyParentalRatingCap,
                title: 'Cap recommendations by parental rating',
                subtitle:
                    'Never suggest something rated higher than the item you are looking at',
                icon: Icons.shield_outlined,
                onChanged: _pushPersonalizationSync,
              ),
              _TvSettingsListTile(
                leading: const Icon(Icons.smart_button_outlined),
                title: const Text('Detail Buttons'),
                subtitle: const Text(
                  'Reorder or hide the action buttons on the details screen',
                ),
                onTap: () =>
                    context.pushSettingsScreen(const _DetailButtonsScreen()),
              ),
                        ],
            ),
],
        ),
      ),
    );
  }
}
