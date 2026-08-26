import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:intl/intl.dart';
import 'package:voltix_design/voltix_design.dart';

import '../../../data/models/taste_profile/taste_profile_models.dart';
import '../../../data/repositories/taste_profile_repository.dart';
import '../../../data/services/taste_profile/taste_refresh_service.dart';
import '../../../preference/user_preferences.dart';
import '../../../util/focus/input_mode_tracker.dart';
import '../../widgets/focus/request_initial_focus.dart';
import '../../widgets/settings/clean_settings_typography.dart';
import '../../widgets/settings/preference_tiles.dart';
import '../taste_profile/taste_onboarding_wizard.dart';
import 'diagnostics_settings_screen.dart';
import 'settings_app_bar.dart';

/// First-class Settings screen for configuring the client-side Taste Profile & Recommendations.
class TasteProfileSettingsScreen extends StatefulWidget {
  const TasteProfileSettingsScreen({super.key});

  @override
  State<TasteProfileSettingsScreen> createState() =>
      _TasteProfileSettingsScreenState();
}

class _TasteProfileSettingsScreenState
    extends State<TasteProfileSettingsScreen> {
  final _tasteRepo = GetIt.instance<TasteProfileRepository>();
  bool _isGeneratingGrokInsight = false;

  @override
  void initState() {
    super.initState();
    _tasteRepo.addListener(_onRepoChanged);
  }

  @override
  void dispose() {
    _tasteRepo.removeListener(_onRepoChanged);
    super.dispose();
  }

  void _onRepoChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = _tasteRepo.currentProfile;
    final serverContext = _tasteRepo.serverContext;

    final currentServerId = profile?.serverId ?? serverContext.primaryServerId;
    final primaryServerName =
        serverContext.primaryServerName ?? 'Connected Servers';

    return RequestInitialFocus(
      child: withCleanSettingsTypography(
        context,
        Scaffold(
          appBar: buildSettingsAppBar(
            context,
            const Text('Taste Profile & Recommendations'),
          ),
          body: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            children: [
              // 1. Server Status Banner
              _buildServerStatusCard(theme, true, primaryServerName, currentServerId),
              const SizedBox(height: 18),

              if (profile == null) ...[
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: CircularProgressIndicator(),
                  ),
                ),
              ] else ...[
                // 2. Profile Status
                _buildStatusCard(theme, profile),
                const SizedBox(height: 20),

                // 3. Candidate Refresh
                _buildSectionHeader(theme, 'Candidate Data & Refresh'),
                _buildRefreshCard(theme),
                const SizedBox(height: 20),

                // 4. Onboarding Wizard
                _buildSectionHeader(theme, 'Onboarding & Profile Review'),
                _buildOnboardingTile(theme),
                const SizedBox(height: 20),

                // 5. Language & Foreign Content
                _buildSectionHeader(theme, 'Language & Content Filtering'),
                _buildLanguageSettingsCard(theme, profile),
                const SizedBox(height: 20),

                // 6. Viewing Preferences
                _buildSectionHeader(theme, 'Viewing Preferences'),
                _buildViewingPreferencesCard(theme, profile),
                const SizedBox(height: 20),

                // 7. Server Genres
                _buildSectionHeader(theme, 'Primary Server Genre Affinities'),
                _buildGenresCard(theme, profile),
                const SizedBox(height: 20),

                // 8. Mood Picks
                _buildSectionHeader(theme, 'Preferred Moods & Vibes'),
                _buildMoodsCard(theme, profile),
                const SizedBox(height: 20),

                // 9. Grok AI Intelligence & Insights
                _buildSectionHeader(theme, 'Grok AI Intelligence & Analysis'),
                _buildGrokAiCard(theme, profile),
                const SizedBox(height: 20),

                // 10. Dynamic Home Rows
                _buildSectionHeader(theme, 'Home Rows & Curated Collections'),
                _buildRowManagementCard(theme, profile),
                const SizedBox(height: 20),

                // 11. Negative Signals
                _buildSectionHeader(theme, 'Negative Signals ("Not Interested")'),
                _buildNegativeSignalsCard(theme, profile),
                const SizedBox(height: 20),

                // 12. Azure Cloud Sync & Privacy
                _buildSectionHeader(theme, 'Azure Storage Backup (voltix-taste-profiles)'),
                _buildCloudSyncCard(theme, profile),
                const SizedBox(height: 20),

                // 13. Diagnostics
                _buildSectionHeader(theme, 'Diagnostics & Testing'),
                _buildDiagnosticsCard(theme),
                const SizedBox(height: 20),

                // 14. Reset & Maintenance
                _buildSectionHeader(theme, 'Reset & Maintenance'),
                _buildResetCard(theme),
                const SizedBox(height: 40),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: AppColorScheme.accent,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildServerStatusCard(
    ThemeData theme,
    bool isPrimary,
    String primaryServerName,
    String? currentServerId,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.dns_rounded,
            color: AppColorScheme.accent,
            size: 26,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Recommendations are active across all connected servers',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Primary Server: $primaryServerName • Movies & series from all connected libraries are aggregated and scored.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard(ThemeData theme, TasteProfile profile) {
    final isCompleted = profile.isCompleted;
    final isSkipped = profile.isSkipped;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isCompleted
                ? Icons.check_circle_rounded
                : isSkipped
                    ? Icons.notification_important_rounded
                    : Icons.tune_rounded,
            color: isCompleted
                ? Colors.greenAccent
                : isSkipped
                    ? Colors.amberAccent
                    : theme.colorScheme.primary,
            size: 28,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isCompleted
                      ? 'Taste Profile Completed'
                      : isSkipped
                          ? 'Profile Incomplete (Remind Later)'
                          : 'Profile Not Configured',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  isCompleted
                      ? 'Home screen is fully personalized based on your explicit preferences & primary server library.'
                      : 'Complete the taste questionnaire to personalize home rows and unlock curated collections.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRefreshCard(ThemeData theme) {
    final refreshService = _tasteRepo.refreshService;
    final lastRefreshed = refreshService.lastRefreshedAt;
    final formattedTime = lastRefreshed != null
        ? DateFormat.yMMMd().add_jm().format(lastRefreshed.toLocal())
        : 'Never';

    return TvFocusHighlight(
      builder: (ctx, focused) => ListTile(
        leading: const Icon(Icons.sync_rounded, color: Colors.blueAccent),
        title: const Text('Refresh movie and series data now'),
        subtitle: Text('Last refreshed: $formattedTime'),
        trailing: refreshService.state == RefreshState.refreshing
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              )
            : const Icon(Icons.arrow_forward_ios_rounded, size: 16),
        onTap: refreshService.state == RefreshState.refreshing
            ? null
            : () async {
                HapticFeedback.lightImpact();
                await _tasteRepo.refreshCandidates(force: true);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Movie and series data refreshed successfully!')),
                  );
                }
              },
      ),
    );
  }

  Widget _buildOnboardingTile(ThemeData theme) {
    return TvFocusHighlight(
      builder: (ctx, focused) => ListTile(
        leading: Icon(Icons.psychology_rounded, color: AppColorScheme.accent),
        title: const Text('Redo Taste Onboarding Wizard'),
        subtitle: const Text('Review and update your 8-step questionnaire'),
        trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 16),
        onTap: () {
          HapticFeedback.lightImpact();
          TasteOnboardingWizard.showAsDialog(
            context,
            onComplete: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Taste profile updated successfully!')),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildLanguageSettingsCard(ThemeData theme, TasteProfile profile) {
    final lang = profile.languageSettings;

    return Column(
      children: [
        TvFocusHighlight(
          builder: (ctx, focused) => SwitchListTile(
            title: const Text('Exclude Foreign-Language Content'),
            subtitle: const Text('Only recommend content with English audio or original tracks by default'),
            value: lang.excludeForeignContent,
            onChanged: (val) {
              HapticFeedback.lightImpact();
              _tasteRepo.saveProfile(
                profile.copyWith(
                  languageSettings: lang.copyWith(excludeForeignContent: val),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 4),
        TvFocusHighlight(
          builder: (ctx, focused) => SwitchListTile(
            title: const Text('Allow Unknown Language Metadata'),
            subtitle: const Text('Include titles when language metadata is missing from the server'),
            value: lang.allowUnknownLanguage,
            onChanged: (val) {
              HapticFeedback.lightImpact();
              _tasteRepo.saveProfile(
                profile.copyWith(
                  languageSettings: lang.copyWith(allowUnknownLanguage: val),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildGenresCard(ThemeData theme, TasteProfile profile) {
    final explicitGenres = profile.explicit.genreRatings;
    final inferredGenres = profile.inferred.genreAffinities;

    final allGenreKeys = <String>{
      ...explicitGenres.keys,
      ...inferredGenres.keys,
      'Action',
      'Comedy',
      'Drama',
      'Sci-Fi',
      'Horror',
      'Thriller',
    }.toList()
      ..sort();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.25),
        ),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: allGenreKeys.map((genre) {
          final explicit = explicitGenres[genre];
          final isLove = explicit == TasteRating.love;
          final isLike = explicit == TasteRating.like;
          final isDislike = explicit == TasteRating.dislike;

          return _TvFilterChip(
            selected: isLove || isLike || isDislike,
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isLove) const Icon(Icons.favorite_rounded, size: 14, color: Colors.redAccent),
                if (isLike) const Icon(Icons.thumb_up_rounded, size: 14, color: Colors.greenAccent),
                if (isDislike) const Icon(Icons.thumb_down_rounded, size: 14, color: Colors.orangeAccent),
                if (explicit != null && explicit != TasteRating.neutral)
                  const SizedBox(width: 4),
                Text(genre),
              ],
            ),
            onSelected: (_) {
              final current = explicit ?? TasteRating.neutral;
              final next = switch (current) {
                TasteRating.neutral => TasteRating.love,
                TasteRating.love => TasteRating.like,
                TasteRating.like => TasteRating.dislike,
                _ => TasteRating.neutral,
              };
              final updated = Map<String, TasteRating>.from(explicitGenres);
              if (next == TasteRating.neutral) {
                updated.remove(genre);
              } else {
                updated[genre] = next;
              }
              _tasteRepo.saveProfile(
                profile.copyWith(
                  explicit: profile.explicit.copyWith(genreRatings: updated),
                ),
              );
            },
          );
        }).toList(),
      ),
    );
  }

  Widget _buildViewingPreferencesCard(ThemeData theme, TasteProfile profile) {
    final prefs = profile.explicit.viewingPreferences;
    final selectedPrefIds = prefs.selectedPreferenceIds;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.25),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Format: ${prefs.formatPreference.toUpperCase()} • Era: ${prefs.preferredEra.toUpperCase()}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Maturity Ceiling: ${prefs.maturityCeiling} • Extended Preferences: ${selectedPrefIds.length} active',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              TvFocusHighlight(
                builder: (ctx, focused) => OutlinedButton.icon(
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    TasteOnboardingWizard.showAsDialog(context);
                  },
                  icon: const Icon(Icons.tune_rounded, size: 16),
                  label: const Text('Edit in Wizard'),
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  ),
                ),
              ),
            ],
          ),
          if (selectedPrefIds.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: selectedPrefIds.take(12).map((prefId) {
                final def = TastePreferenceRegistry.getById(prefId);
                final name = def?.displayName ?? prefId;
                return Chip(
                  label: Text(name),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                );
              }).toList(),
            ),
            if (selectedPrefIds.length > 12) ...[
              const SizedBox(height: 6),
              Text(
                '+ ${selectedPrefIds.length - 12} more preferences selected',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildMoodsCard(ThemeData theme, TasteProfile profile) {
    final selectedMoods = profile.explicit.selectedMoods;
    final selectedMoodIds = profile.explicit.selectedMoodIds;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.25),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: MoodCategory.values.map((mood) {
              final isSelected = selectedMoods.contains(mood);
              return _TvFilterChip(
                selected: isSelected,
                label: Text(mood.label),
                avatar: Icon(
                  isSelected ? Icons.check_circle_rounded : Icons.add_circle_outline_rounded,
                  size: 16,
                  color: isSelected ? AppColorScheme.accent : null,
                ),
                onSelected: (val) {
                  final updated = Set<MoodCategory>.from(selectedMoods);
                  if (val) {
                    updated.add(mood);
                  } else {
                    updated.remove(mood);
                  }
                  _tasteRepo.saveProfile(
                    profile.copyWith(
                      explicit: profile.explicit.copyWith(selectedMoods: updated),
                    ),
                  );
                },
              );
            }).toList(),
          ),
          if (selectedMoodIds.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 8),
            Text(
              'Extended Vibes & Moods (${selectedMoodIds.length} selected):',
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: selectedMoodIds.take(15).map((mId) {
                final def = TasteMoodRegistry.getById(mId);
                return Chip(
                  avatar: const Icon(Icons.auto_awesome, size: 12),
                  label: Text(def?.displayName ?? mId),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                );
              }).toList(),
            ),
            if (selectedMoodIds.length > 15) ...[
              const SizedBox(height: 6),
              Text(
                '+ ${selectedMoodIds.length - 15} more vibes selected',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildGrokAiCard(ThemeData theme, TasteProfile profile) {
    final aiService = _tasteRepo.aiService;
    final isLiveAi = aiService.isConfigured;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TvFocusHighlight(
          builder: (ctx, focused) => SwitchListTile(
            title: Row(
              children: [
                const Text('AI Taste Persona Insights'),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColorScheme.accent.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    isLiveAi ? 'LIVE AI' : 'OFFLINE AI',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: isLiveAi ? Colors.greenAccent : AppColorScheme.accent,
                      fontWeight: FontWeight.bold,
                      fontSize: 10,
                    ),
                  ),
                ),
              ],
            ),
            subtitle: Text(
              isLiveAi
                  ? 'Connected to AI Endpoint (${aiService.selectedModel}). Analyzes taste DNA with cinephilic intelligence.'
                  : 'Operating via client-side deterministic synthesis engine. No external server calls required.',
            ),
            value: profile.aiFeaturesEnabled,
            onChanged: (val) {
              HapticFeedback.lightImpact();
              _tasteRepo.toggleAiFeatures(val);
            },
          ),
        ),
        if (profile.aiFeaturesEnabled) ...[
          const SizedBox(height: 4),
          TvFocusHighlight(
            builder: (ctx, focused) => ListTile(
              leading: const Icon(Icons.settings_suggest_rounded),
              title: const Text('AI Service & Endpoint Settings'),
              subtitle: Text(
                isLiveAi
                    ? 'Endpoint: ${aiService.endpoint}\nModel: ${aiService.selectedModel}'
                    : 'Configure xAI Grok API key or custom server LLM endpoint',
              ),
              trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 16),
              onTap: () => _showAiConfigDialog(context),
            ),
          ),
        ],
        if (profile.aiPersonaSummary != null && profile.aiPersonaSummary!.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColorScheme.accent.withValues(alpha: 0.3),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.auto_awesome_rounded, size: 16, color: AppColorScheme.accent),
                    const SizedBox(width: 6),
                    Text(
                      'Your Taste Persona',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: AppColorScheme.accent,
                      ),
                    ),
                    const Spacer(),
                    if (profile.aiLastInsightUtc != null)
                      Text(
                        DateFormat.MMMd().add_jm().format(profile.aiLastInsightUtc!.toLocal()),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                SelectableText(
                  profile.aiPersonaSummary!,
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                ),
              ],
            ),
          ),
        ],
        if (profile.aiFeaturesEnabled) ...[
          const SizedBox(height: 6),
          TvFocusHighlight(
            builder: (ctx, focused) => ListTile(
              leading: _isGeneratingGrokInsight
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome_rounded, color: Colors.purpleAccent),
              title: Text(_isGeneratingGrokInsight
                  ? 'Synthesizing Taste Persona Insights...'
                  : 'Refresh Taste Persona Insights'),
              subtitle: Text(
                isLiveAi
                    ? 'Request live analysis from configured AI endpoint'
                    : 'Re-synthesize profile insight using calibrated offline engine',
              ),
              trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 16),
              onTap: _isGeneratingGrokInsight
                  ? null
                  : () async {
                      HapticFeedback.lightImpact();
                      setState(() => _isGeneratingGrokInsight = true);
                      try {
                        final insight = await _tasteRepo.generateGrokTastePersona();
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(insight != null
                                  ? (isLiveAi
                                      ? 'Live AI insight received successfully!'
                                      : 'Taste persona updated via local synthesis engine!')
                                  : 'Unable to refresh AI insight. Please check network connection.'),
                            ),
                          );
                        }
                      } finally {
                        if (mounted) {
                          setState(() => _isGeneratingGrokInsight = false);
                        }
                      }
                    },
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildRowManagementCard(ThemeData theme, TasteProfile profile) {
    final enabledRows = profile.enabledHomeRows;

    Widget buildRowToggle(PersonalizationRowType row) {
      final isEnabled = enabledRows[row.key] ?? true;
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: TvFocusHighlight(
          builder: (ctx, focused) => SwitchListTile(
            title: Text(row.defaultTitle),
            value: isEnabled,
            dense: true,
            onChanged: (val) {
              HapticFeedback.lightImpact();
              final updated = Map<String, bool>.from(enabledRows)..[row.key] = val;
              _tasteRepo.saveProfile(
                profile.copyWith(enabledHomeRows: updated),
              );
            },
          ),
        ),
      );
    }

    return Column(
      children: [
        ...PersonalizationRowType.values.map(buildRowToggle),
        const SizedBox(height: 4),
        TvFocusHighlight(
          builder: (ctx, focused) => ListTile(
            leading: const Icon(Icons.format_list_numbered_rounded),
            title: const Text('Max Items per Row'),
            subtitle: Text('${profile.maxItemsPerRow} titles per recommendation row'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline, size: 20),
                  tooltip: 'Decrease count',
                  onPressed: profile.maxItemsPerRow > 10
                      ? () {
                          HapticFeedback.lightImpact();
                          final newVal = (profile.maxItemsPerRow - 5).clamp(10, 100);
                          _tasteRepo.saveProfile(
                            profile.copyWith(maxItemsPerRow: newVal),
                          );
                        }
                      : null,
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Text(
                    '${profile.maxItemsPerRow}',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline, size: 20),
                  tooltip: 'Increase count',
                  onPressed: profile.maxItemsPerRow < 100
                      ? () {
                          HapticFeedback.lightImpact();
                          final newVal = (profile.maxItemsPerRow + 5).clamp(10, 100);
                          _tasteRepo.saveProfile(
                            profile.copyWith(maxItemsPerRow: newVal),
                          );
                        }
                      : null,
                ),
              ],
            ),
            onTap: () => _showMaxItemsPickerDialog(context, profile),
          ),
        ),
        const SizedBox(height: 4),
        TvFocusHighlight(
          builder: (ctx, focused) => ListTile(
            leading: const Icon(Icons.dashboard_customize_rounded, size: 22),
            title: const Text('Reorder & Position Home Rows'),
            subtitle: const Text(
              'You can arrange, enable, and move these dynamic rows alongside your server libraries under Personalization → Home Screen → Home Sections.',
            ),
            dense: true,
          ),
        ),
      ],
    );
  }

  void _showMaxItemsPickerDialog(BuildContext context, TasteProfile profile) {
    final options = [10, 15, 20, 25, 30, 40, 50, 75, 100];
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Select Max Items per Row'),
        content: SizedBox(
          width: 320,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: options.map((val) {
                final isSelected = profile.maxItemsPerRow == val;
                return TvFocusHighlight(
                  builder: (tCtx, focused) => ListTile(
                    title: Text('$val titles'),
                    trailing: isSelected
                        ? Icon(Icons.check_circle_rounded, color: AppColorScheme.accent)
                        : null,
                    selected: isSelected,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      _tasteRepo.saveProfile(
                        profile.copyWith(maxItemsPerRow: val),
                      );
                      Navigator.of(ctx).pop();
                    },
                  ),
                );
              }).toList(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showAiConfigDialog(BuildContext context) {
    final prefs = GetIt.instance<UserPreferences>();
    final keyController = TextEditingController(text: prefs.get(UserPreferences.grokApiKey));
    final modelController = TextEditingController(text: prefs.get(UserPreferences.grokModel));
    final endpointController = TextEditingController(text: prefs.get(UserPreferences.grokEndpoint));

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('AI Configuration & Endpoint'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Voltix can run offline with its built-in cinematic synthesis engine, or connect to live AI services (xAI Grok, OpenAI-compatible proxy, or local server LLM).',
                  style: TextStyle(fontSize: 13, height: 1.3),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: keyController,
                  decoration: const InputDecoration(
                    labelText: 'API Key (Optional for offline synthesis)',
                    hintText: 'xai-... or sk-...',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: modelController,
                  decoration: const InputDecoration(
                    labelText: 'Model Name',
                    hintText: 'grok-2-latest',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: endpointController,
                  decoration: const InputDecoration(
                    labelText: 'API Endpoint URL',
                    hintText: 'https://api.x.ai/v1/chat/completions',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              HapticFeedback.lightImpact();
              final messenger = ScaffoldMessenger.of(context);
              final nav = Navigator.of(ctx);
              await prefs.set(UserPreferences.grokApiKey, keyController.text.trim());
              await prefs.set(UserPreferences.grokModel, modelController.text.trim().isNotEmpty ? modelController.text.trim() : 'grok-2-latest');
              await prefs.set(UserPreferences.grokEndpoint, endpointController.text.trim().isNotEmpty ? endpointController.text.trim() : 'https://api.x.ai/v1/chat/completions');
              _tasteRepo.aiService.setApiKey(keyController.text.trim());
              _tasteRepo.aiService.setModel(modelController.text.trim().isNotEmpty ? modelController.text.trim() : 'grok-2-latest');
              _tasteRepo.aiService.setEndpoint(endpointController.text.trim().isNotEmpty ? endpointController.text.trim() : 'https://api.x.ai/v1/chat/completions');
              if (mounted) {
                setState(() {});
              }
              nav.pop();
              messenger.showSnackBar(
                const SnackBar(content: Text('AI configuration saved successfully!')),
              );
            },
            child: const Text('Save Settings'),
          ),
        ],
      ),
    );
  }

  Widget _buildNegativeSignalsCard(ThemeData theme, TasteProfile profile) {
    final signals = profile.negativeSignals;

    if (signals.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.25),
          ),
        ),
        child: Text(
          'No negative signals. Items marked "Not Interested" in context menus will appear here.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Column(
      children: signals.map((sig) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: TvFocusHighlight(
            builder: (ctx, focused) => ListTile(
              leading: const Icon(Icons.block_rounded, color: Colors.orangeAccent),
              title: Text(sig.title),
              subtitle: Text('Blocked ${sig.type}'),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline_rounded),
                tooltip: 'Unblock',
                onPressed: () {
                  HapticFeedback.lightImpact();
                  _tasteRepo.removeNegativeSignal(sig.id);
                },
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildCloudSyncCard(ThemeData theme, TasteProfile profile) {
    final azureSync = _tasteRepo.azureSync;
    final currentProfile = _tasteRepo.currentProfile ?? profile;
    final isSynced = currentProfile.syncStatus == SyncStatus.synced ||
        (currentProfile.lastSyncedAtUtc != null &&
            currentProfile.syncStatus != SyncStatus.pendingUpload);

    return Column(
      children: [
        TvFocusHighlight(
          builder: (ctx, focused) => SwitchListTile(
            title: const Text('Back up my taste profile securely to Azure'),
            subtitle: const Text(
              'Silently backs up your personalized taste profile to cloud storage.',
            ),
            value: currentProfile.azureBackupEnabled,
            onChanged: (val) async {
              HapticFeedback.lightImpact();
              await _tasteRepo.saveProfile(
                currentProfile.copyWith(azureBackupEnabled: val),
              );
              if (val) {
                await _tasteRepo.syncProfileToCloud();
              }
              if (mounted) setState(() {});
            },
          ),
        ),
        if (currentProfile.azureBackupEnabled) ...[
          const SizedBox(height: 4),
          TvFocusHighlight(
            builder: (ctx, focused) => ListTile(
              leading: Icon(
                isSynced
                    ? Icons.cloud_done_rounded
                    : Icons.cloud_upload_rounded,
                color: isSynced
                    ? Colors.greenAccent
                    : Colors.blueAccent,
              ),
              title: Text('Cloud Sync Status: ${isSynced ? "Synced" : currentProfile.syncStatus.value}'),
              subtitle: Text(
                currentProfile.lastSyncedAtUtc != null
                    ? 'Last synced: ${DateFormat.yMMMd().add_jm().format(currentProfile.lastSyncedAtUtc!.toLocal())}'
                    : (azureSync.lastSyncError != null
                        ? 'Sync error: ${azureSync.lastSyncError}'
                        : 'Not synced yet'),
              ),
              trailing: azureSync.isUploading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : TextButton(
                      onPressed: () async {
                        HapticFeedback.lightImpact();
                        final ok = await _tasteRepo.syncProfileToCloud();
                        if (mounted) {
                          setState(() {});
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(ok
                                  ? 'Profile successfully synced to cloud storage!'
                                  : (azureSync.lastSyncError != null
                                      ? 'Sync failed: ${azureSync.lastSyncError}'
                                      : 'Sync in progress or network offline.')),
                            ),
                          );
                        }
                      },
                      child: const Text('Sync Now'),
                    ),
            ),
          ),
        ],
        const SizedBox(height: 4),
        TvFocusHighlight(
          builder: (ctx, focused) => ListTile(
            leading: const Icon(Icons.data_object_rounded),
            title: const Text('View Stored Profile JSON'),
            subtitle: const Text('Inspect raw local data and schema versioning'),
            onTap: () {
              final jsonPretty = const JsonEncoder.withIndent('  ')
                  .convert(profile.toJson());
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Stored Taste Profile (Schema v2)'),
                  content: SizedBox(
                    width: 500,
                    child: SingleChildScrollView(
                      child: SelectableText(
                        jsonPretty,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDiagnosticsCard(ThemeData theme) {
    return TvFocusHighlight(
      builder: (ctx, focused) => ListTile(
        leading: Icon(Icons.analytics_rounded, color: AppColorScheme.accent),
        title: const Text('Jellyfin Data Test Tool'),
        subtitle: const Text('Run full system, token, library indexing, and cloud sync diagnostics'),
        trailing: const Icon(Icons.arrow_forward_ios_rounded, size: 16),
        onTap: () {
          HapticFeedback.lightImpact();
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const DiagnosticsSettingsScreen(),
            ),
          );
        },
      ),
    );
  }

  Widget _buildResetCard(ThemeData theme) {
    return Column(
      children: [
        TvFocusHighlight(
          builder: (ctx, focused) => ListTile(
            leading: const Icon(Icons.refresh_rounded, color: Colors.blueAccent),
            title: const Text('Re-Analyze Watch History'),
            subtitle: const Text('Refresh inferred genre and actor affinities from primary server'),
            onTap: () async {
              HapticFeedback.lightImpact();
              await _tasteRepo.resetInferredProfile();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Watch history re-analyzed successfully.')),
                );
              }
            },
          ),
        ),
        const SizedBox(height: 4),
        TvFocusHighlight(
          builder: (ctx, focused) => ListTile(
            leading: const Icon(Icons.restart_alt_rounded, color: Colors.amberAccent),
            title: const Text('Reset Questionnaire Answers'),
            subtitle: const Text('Clears explicit ratings and returns to uncompleted status'),
            onTap: () async {
              HapticFeedback.lightImpact();
              await _tasteRepo.resetExplicitProfile();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Questionnaire answers reset.')),
                );
              }
            },
          ),
        ),
        const SizedBox(height: 4),
        TvFocusHighlight(
          builder: (ctx, focused) => ListTile(
            leading: const Icon(Icons.delete_forever_rounded, color: Colors.redAccent),
            title: const Text('Delete Local Profile'),
            subtitle: const Text('Removes all taste profile data stored on this device'),
            onTap: () async {
              HapticFeedback.heavyImpact();
              await _tasteRepo.deleteAllData();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Local taste profile deleted.')),
                );
              }
            },
          ),
        ),
      ],
    );
  }
}

class _TvFilterChip extends StatefulWidget {
  final Widget label;
  final bool selected;
  final Widget? avatar;
  final ValueChanged<bool> onSelected;

  const _TvFilterChip({
    required this.label,
    required this.selected,
    this.avatar,
    required this.onSelected,
  });

  @override
  State<_TvFilterChip> createState() => _TvFilterChipState();
}

class _TvFilterChipState extends State<_TvFilterChip> {
  final _focusNode = FocusNode(debugLabel: 'TvFilterChip');
  bool _focused = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focusVisible = InputModeTracker.showFocusVisuals(context, _focused);

    return FocusableActionDetector(
      focusNode: _focusNode,
      onFocusChange: (val) {
        setState(() => _focused = val);
        if (val) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              Scrollable.ensureVisible(
                context,
                alignment: 0.5,
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOut,
              );
            }
          });
        }
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            HapticFeedback.selectionClick();
            widget.onSelected(!widget.selected);
            return null;
          },
        ),
        ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
          onInvoke: (_) {
            HapticFeedback.selectionClick();
            widget.onSelected(!widget.selected);
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          widget.onSelected(!widget.selected);
        },
        child: AnimatedScale(
          scale: focusVisible ? 1.08 : 1.0,
          duration: const Duration(milliseconds: 100),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: focusVisible
                  ? Border.all(color: AppColorScheme.accent, width: 2.5)
                  : null,
              boxShadow: focusVisible
                  ? [
                      BoxShadow(
                        color: AppColorScheme.accent.withValues(alpha: 0.45),
                        blurRadius: 10,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: FilterChip(
              label: widget.label,
              avatar: widget.avatar,
              selected: widget.selected,
              onSelected: (val) {
                HapticFeedback.selectionClick();
                widget.onSelected(val);
              },
            ),
          ),
        ),
      ),
    );
  }
}
