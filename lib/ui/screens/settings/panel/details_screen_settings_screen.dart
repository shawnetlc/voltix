part of '../settings_side_panel.dart';

/// Details screen settings, gathered onto their own screen the way upstream
/// 2.4.0 has them. These used to sit in General Style.
class _DetailsScreenSettingsScreen extends StatefulWidget {
  const _DetailsScreenSettingsScreen();

  @override
  State<_DetailsScreenSettingsScreen> createState() =>
      _DetailsScreenSettingsScreenState();
}

class _DetailsScreenSettingsScreenState
    extends State<_DetailsScreenSettingsScreen> {
  final _detailsScreenScope = FocusScopeNode(
    debugLabel: 'DetailsScreenSettingsScope',
    traversalEdgeBehavior: TraversalEdgeBehavior.stop,
  );

  @override
  void dispose() {
    _detailsScreenScope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final prefs = GetIt.instance<UserPreferences>();
    return withCleanSettingsTypography(
      context,
      Scaffold(
        appBar: buildSettingsAppBar(context, const Text('Details Screen')),
        body: FocusScope(
          node: _detailsScreenScope,
          child: ListenableBuilder(
            listenable: prefs,
            builder: (context, _) => ListView(
              children: [
                _SectionHeader(l10n.display),
                adaptiveListSection(
                  children: [
                    EnumPreferenceTile<DetailScreenStyle>(
                      autofocus: true,
                      preference: UserPreferences.detailScreenStyle,
                      title: l10n.detailScreenStyle,
                      description: l10n.detailScreenStyleSubtitle,
                      icon: Icons.movie_outlined,
                      labelOf: (v) => switch (v) {
                        DetailScreenStyle.classic =>
                          l10n.detailScreenStyleMoonfin,
                        DetailScreenStyle.modern =>
                          l10n.detailScreenStyleModern,
                      },
                    ),
                    EnumPreferenceTile<PersonalRatingStyle>(
                      preference: UserPreferences.personalRatingStyle,
                      // Not yet in app_en.arb -- ported from upstream 2.5.0
                      // as a literal to avoid hand-editing every locale's
                      // .arb file without flutter gen-l10n available here.
                      title: 'Personal rating style',
                      icon: Icons.rate_review,
                      values:
                          GetIt.instance<MediaServerClient>()
                              .userLibraryApi
                              .supportsNumericUserRatings
                          ? PersonalRatingStyle.values
                          : const [PersonalRatingStyle.thumbs],
                      labelOf: (style) => switch (style) {
                        PersonalRatingStyle.thumbs => 'Thumbs up / down',
                        PersonalRatingStyle.stars => 'Star rating',
                        PersonalRatingStyle.numeric => 'Numeric (0-10)',
                      },
                    ),
                    if (prefs.get(UserPreferences.detailScreenStyle) !=
                        DetailScreenStyle.modern)
                      SliderPreferenceTile(
                        preference: UserPreferences.detailsBackgroundBlurAmount,
                        title: l10n.detailsBackgroundBlur,
                        icon: Icons.blur_on,
                        min: 0,
                        max: 25,
                        divisions: 25,
                        labelOf: (v) => '$v',
                        onChangeEnd: _pushPersonalizationSync,
                      )
                    else
                      SliderPreferenceTile(
                        preference: UserPreferences.detailsBackgroundBlurAmount,
                        title: l10n.detailsBackgroundOpacity,
                        icon: Icons.opacity,
                        min: 0,
                        max: 25,
                        divisions: 25,
                        labelOf: (v) => '$v',
                        onChangeEnd: _pushPersonalizationSync,
                      ),
                    _TvSettingsListTile(
                      leading: const Icon(Icons.smart_button_outlined),
                      title: const Text('Detail Buttons'),
                      subtitle: const Text(
                        'Reorder or hide the action buttons on the details screen',
                      ),
                      onTap: () => context.pushSettingsScreen(
                        const _DetailButtonsScreen(),
                      ),
                    ),
                  ],
                ),
                // Not yet in app_en.arb -- see note above.
                _SectionHeader('Media details & spoilers'),
                adaptiveListSection(
                  children: [
                    if (prefs.get(UserPreferences.detailScreenStyle) ==
                        DetailScreenStyle.modern)
                      SwitchPreferenceTile(
                        preference: UserPreferences.detailExpandedTabs,
                        title: l10n.expandedTabs,
                        subtitle: l10n.expandedTabsSubtitle,
                        icon: Icons.tab,
                        onChanged: _pushPersonalizationSync,
                      ),
                    SwitchPreferenceTile(
                      preference: UserPreferences.detailShowTechnicalDetails,
                      title: l10n.showTechnicalDetails,
                      subtitle: l10n.showTechnicalDetailsSubtitle,
                      icon: Icons.info_outline,
                      onChanged: _pushPersonalizationSync,
                    ),
                    SwitchPreferenceTile(
                      preference: UserPreferences.detailTrailersExternal,
                      // Not yet in app_en.arb -- see note above.
                      title: 'Open trailers externally',
                      subtitle:
                          'Play trailers in YouTube or your browser instead of in-app',
                      icon: Icons.open_in_new,
                      onChanged: _pushPersonalizationSync,
                    ),
                  ],
                ),
                _SectionHeader(l10n.recommendations),
                adaptiveListSection(
                  children: [
                    EnumPreferenceTile<RecommendationSystemSource>(
                      preference: UserPreferences.recommendationSystemSource,
                      title: 'Recommendation system',
                      icon: Icons.recommend,
                      labelOf: (v) => switch (v) {
                        RecommendationSystemSource.local =>
                          'Voltix Recommends',
                        RecommendationSystemSource.online => 'TMDB similarity',
                      },
                      onChanged: _pushPersonalizationSync,
                    ),
                    SwitchPreferenceTile(
                      preference:
                          UserPreferences.recommendationsApplyParentalRatingCap,
                      title: l10n.recommendationsApplyParentalRatingCap,
                      subtitle:
                          l10n.recommendationsApplyParentalRatingCapSubtitle,
                      icon: Icons.family_restroom,
                      onChanged: _pushPersonalizationSync,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
