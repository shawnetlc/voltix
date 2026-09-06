import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:server_core/server_core.dart';
import 'package:voltix_design/voltix_design.dart';
import '../../../data/models/aggregated_item.dart';
import '../../../data/models/taste_profile/taste_profile_models.dart';
import '../../../data/repositories/taste_profile_repository.dart';
import '../../../data/services/taste_profile/taste_recommendation_engine.dart';
import '../../widgets/bounded_network_image.dart';
import '../../../util/focus/key_event_utils.dart';
import '../../widgets/focus/request_initial_focus.dart';

/// Interactive 8-Step Onboarding Wizard for Jellyfin Taste Profile & Recommendations.
///
/// Steps:
/// 0. Data Preparation and Synchronisation (Resumable, exact status messages, fast transitions).
/// 1. Movies (titles with advice banner, decade filters, shuffle, rating controls).
/// 2. Series (titles with advice banner, format/length filters, shuffle, rating controls).
/// 3. Genres (dynamic server-genre discovery with light blue selected chips and black text).
/// 4. Viewing Experience Lab (movie vs series balance, runtime, binge style, era, maturity, pacing).
/// 5. Moods and Vibes (200 curated moods across 10 categories, search, selected chips).
/// 6. Perfect Experience (dynamic home row preview and Grok AI persona analysis).
/// 7. Profile Review and Completion (summary, atomic persistence, silent cloud sync).
class TasteOnboardingWizard extends StatefulWidget {
  final VoidCallback? onComplete;
  final VoidCallback? onSkip;

  const TasteOnboardingWizard({
    super.key,
    this.onComplete,
    this.onSkip,
  });

  static Future<void> showAsDialog(
    BuildContext context, {
    VoidCallback? onComplete,
    VoidCallback? onSkip,
  }) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog.fullscreen(
        child: TasteOnboardingWizard(
          onComplete: () {
            Navigator.of(ctx).maybePop();
            onComplete?.call();
          },
          onSkip: () {
            Navigator.of(ctx).maybePop();
            onSkip?.call();
          },
        ),
      ),
    );
  }

  @override
  State<TasteOnboardingWizard> createState() => _TasteOnboardingWizardState();
}

class _TasteOnboardingWizardState extends State<TasteOnboardingWizard> {
  final _tasteRepo = GetIt.instance<TasteProfileRepository>();
  final _client = GetIt.instance<MediaServerClient>();
  final _pageController = PageController();

  int _currentStep = 0;
  bool _loading = true;
  bool _refreshingMovies = false;
  bool _refreshingSeries = false;

  // Cached candidates
  List<AggregatedItem> _allMovies = [];
  List<AggregatedItem> _displayedMovies = [];
  List<AggregatedItem> _allSeries = [];
  List<AggregatedItem> _displayedSeries = [];
  List<ServerGenreInfo> _serverGenres = [];

  // Ratings and Preferences State
  final Map<String, TasteRating> _movieRatings = {};
  final Map<String, TasteRating> _seriesRatings = {};
  final Map<String, TasteRating> _genreRatings = {};
  ViewingPreferences _viewingPreferences = const ViewingPreferences();
  LanguageSettings _languageSettings = const LanguageSettings();
  final Set<MoodCategory> _selectedMoods = {};
  final Set<String> _selectedPreferenceIds = {};
  final Set<String> _selectedMoodIds = {};
  final TextEditingController _freeTextController = TextEditingController();

  // Filter State: Movies & Series
  String _movieDecadeFilter = 'all';
  String _seriesFormatFilter = 'all';


  String? _aiPersonaInsight;
  bool _isGeneratingPersona = false;
  bool _finishing = false;

  /// Saved ratings not yet matched to a movie or series library.
  final Map<String, TasteRating> _restoredTitleRatings = {};

  /// Focus target for the primary footer button, so the wizard opens with
  /// "Continue to Movies" selected instead of the header's Skip link.
  final FocusNode _continueFocusNode = FocusNode(debugLabel: 'tasteContinue');

  @override
  void initState() {
    super.initState();
    _tasteRepo.syncManager.addListener(_onSyncProgressUpdated);
    _initializeWizard();
  }

  @override
  void dispose() {
    _tasteRepo.syncManager.removeListener(_onSyncProgressUpdated);
    // A pending debounce would otherwise drop the last few edits on close.
    if (_draftSaveDebounce?.isActive ?? false) {
      _draftSaveDebounce!.cancel();
      unawaited(_writeDraftProfile());
    }
    _continueFocusNode.dispose();
    _pageController.dispose();
    _freeTextController.dispose();
    super.dispose();
  }

  void _onSyncProgressUpdated() {
    if (mounted) setState(() {});
  }

  Future<void> _initializeWizard() async {
    final serverId = _resolveServerId();
    final userId = _resolveUserId();

    // 1. Load pre-existing profile state if available
    final profile = _tasteRepo.currentProfile;
    if (profile != null) {
      // A saved profile stores one combined title->rating map. Loading it into
      // BOTH the movie and series maps double-counted every rating on the
      // review step. Hold it aside and partition it once the library caches
      // land, so each title is counted against the library it came from.
      _restoredTitleRatings.addAll(profile.explicit.titleRatings);
      _genreRatings.addAll(profile.explicit.genreRatings);
      _viewingPreferences = profile.explicit.viewingPreferences;
      _languageSettings = profile.languageSettings;
      _selectedMoods.addAll(profile.explicit.selectedMoods);
      _selectedPreferenceIds
          .addAll(profile.explicit.viewingPreferences.selectedPreferenceIds);
      if (_viewingPreferences.pacingPreference == 'slow-burn') {
        _selectedPreferenceIds.add('style_slow_burn');
      } else if (_viewingPreferences.pacingPreference == 'fast') {
        _selectedPreferenceIds.add('style_fast_paced');
      }
      _selectedMoodIds.addAll(profile.explicit.selectedMoodIds);
      if (profile.explicit.freeTextDescription != null) {
        _freeTextController.text = profile.explicit.freeTextDescription!;
      }
    }

    // Bounded and guarded as one unit. Every await below can reach the
    // server, and this screen is hosted in a barrier-less fullscreen dialog
    // with no way out but the back button. Unbounded, a slow or unreachable
    // server left _loading true forever, which the user sees as a blank screen
    // that never resolves. Empty caches are a perfectly usable starting state
    // -- the sync kicked off below refills them -- so failing here degrades
    // rather than blocks.
    try {
      await () async {
        // 2. Load saved sync progress or start synchronisation
        await _tasteRepo.syncManager.loadSavedProgress(
          serverId: serverId,
          userId: userId,
        );

        // 3. Populate local candidates from cache if already indexed
        _allMovies = await _tasteRepo.loadCachedMovies();
        _allSeries = await _tasteRepo.loadCachedSeries();
        _serverGenres = await _tasteRepo.genreService.discoverServerGenres(
          userId: userId,
          selectedGenreKeys: _genreRatings.keys.toSet(),
        );
      }().timeout(const Duration(seconds: 15));
    } catch (e) {
      debugPrint('[TasteOnboarding] Setup data unavailable, continuing: $e');
    }

    _splitRestoredRatings();
    _applyMovieFilters();
    _applySeriesFilters();

    if (mounted) setState(() => _loading = false);

    // Start fast sync for Step 0 if not completed
    if (!_tasteRepo.syncManager.progressState.isCompleted) {
      _tasteRepo.syncManager.startOrResumeSync(
        serverId: serverId,
        userId: userId,
        languageSettings: _languageSettings,
      ).then((_) {
        if (mounted) {
          _refreshLocalCaches();
        }
      });
    }
  }

  Future<void> _refreshLocalCaches() async {
    final movies = _tasteRepo.syncManager.cachedMovies.isNotEmpty
        ? _tasteRepo.syncManager.cachedMovies
        : await _tasteRepo.loadCachedMovies();
    final series = _tasteRepo.syncManager.cachedSeries.isNotEmpty
        ? _tasteRepo.syncManager.cachedSeries
        : await _tasteRepo.loadCachedSeries();

    if (movies.isNotEmpty) _allMovies = movies;
    if (series.isNotEmpty) _allSeries = series;
    if (_tasteRepo.syncManager.cachedServerGenres.isNotEmpty) {
      _serverGenres = _tasteRepo.syncManager.cachedServerGenres;
    }

    _splitRestoredRatings();
    _applyMovieFilters();
    _applySeriesFilters();
    if (mounted) setState(() {});
  }

  /// Files each restored rating under the library that actually contains it.
  /// Anything still unmatched stays pending so a later cache refresh can claim
  /// it, and _buildDraftProfile writes it back either way - nothing is lost.
  void _splitRestoredRatings() {
    if (_restoredTitleRatings.isEmpty) return;
    final movieIds = _allMovies.map((m) => m.id).toSet();
    final seriesIds = _allSeries.map((e) => e.id).toSet();
    if (movieIds.isEmpty && seriesIds.isEmpty) return;

    _restoredTitleRatings.forEach((id, rating) {
      if (movieIds.contains(id)) {
        _movieRatings[id] = rating;
      } else if (seriesIds.contains(id)) {
        _seriesRatings[id] = rating;
      }
    });
    _restoredTitleRatings.removeWhere(
      (id, _) => movieIds.contains(id) || seriesIds.contains(id),
    );
  }

  /// Candidates are re-drawn from the server-backed cache every time this
  /// runs, so each visit to the wizard offers a different set to rate rather
  /// than the same fixed 36 titles. The engine still draws from the
  /// top-scoring pool, so the picks stay recognisable.
  void _applyMovieFilters({bool randomize = true}) {
    var list = List<AggregatedItem>.from(_allMovies);

    if (_movieDecadeFilter != 'all') {
      final year = int.tryParse(_movieDecadeFilter) ?? 0;
      if (year > 0) {
        list = list
            .where((m) =>
                (m.productionYear ?? 0) >= year &&
                (m.productionYear ?? 0) < year + 10)
            .toList();
      } else if (_movieDecadeFilter == 'classic') {
        list = list.where((m) => (m.productionYear ?? 0) < 1990).toList();
      }
    }

    _displayedMovies = TasteRecommendationEngine.selectOnboardingTitles(
      libraryItems: list,
      languageSettings: _languageSettings,
      targetCount: 36,
      randomize: randomize,
    );
  }

  void _applySeriesFilters({bool randomize = true}) {
    var list = List<AggregatedItem>.from(_allSeries);

    if (_seriesFormatFilter == 'limited') {
      list = list
          .where((s) =>
              s.rawData['Status'] == 'Ended' ||
              s.name.toLowerCase().contains('limited'))
          .toList();
    } else if (_seriesFormatFilter == 'bingeable') {
      list = list
          .where((s) =>
              (s.rawData['CumulativeRunTimeTicks'] as num? ?? 0) > 0 ||
              (s.communityRating ?? 0.0) >= 8.0)
          .toList();
    }

    _displayedSeries =
        TasteRecommendationEngine.selectOnboardingSeriesCandidates(
      librarySeries: list,
      languageSettings: _languageSettings,
      targetCount: 36,
      randomize: randomize,
    );
  }

  /// Persists the in-progress profile, coalescing bursts of edits.
  ///
  /// Every rating tap and every chip toggle called this, and each call ran a
  /// full TasteProfileRepository.saveProfile: an atomic disk write, a roaming
  /// DisplayPreferences round trip to the server, AND an Azure blob upload.
  /// Rating 36 titles meant 36 of each. On a TV box that is what made the grid
  /// feel like treacle. Edits now settle for [_draftSaveDelay] before one write
  /// goes out, and step changes / completion flush immediately so nothing is
  /// ever lost.
  static const _draftSaveDelay = Duration(milliseconds: 1200);
  Timer? _draftSaveDebounce;

  void _saveDraftProgress({bool immediate = false}) {
    _draftSaveDebounce?.cancel();
    _draftSaveDebounce = null;
    if (immediate) {
      unawaited(_writeDraftProfile());
      return;
    }
    _draftSaveDebounce = Timer(_draftSaveDelay, () {
      _draftSaveDebounce = null;
      unawaited(_writeDraftProfile());
    });
  }

  Future<void> _writeDraftProfile() async {
    try {
      final profile = _buildDraftProfile(status: TasteProfileStatus.inProgress);
      await _tasteRepo.saveProfile(profile);
    } catch (e) {
      debugPrint('[TasteOnboarding] Draft save failed: $e');
    }
  }

  /// One deliberate press must move exactly one step.
  ///
  /// A D-Pad OK on a TV remote emits key-repeat events, and the footer used to
  /// add/remove buttons between steps, which re-parented focus mid-press so the
  /// tail of that same press activated whatever had moved underneath it. Both
  /// routes called _nextPage twice and silently skipped a whole step - which is
  /// why Movies (1), the Viewing Lab (4) and Perfect Experience (6) were never
  /// seen. The footer shape is now fixed (see the build method) and this
  /// cooldown catches anything the shape fix does not.
  static const _stepCooldown = Duration(milliseconds: 500);
  DateTime? _lastStepChangeAt;

  void _goToStep(int step) {
    if (step < 0 || step > 7 || step == _currentStep) return;
    final last = _lastStepChangeAt;
    if (last != null && DateTime.now().difference(last) < _stepCooldown) {
      return;
    }
    _lastStepChangeAt = DateTime.now();
    HapticFeedback.lightImpact();
    _saveDraftProgress(immediate: true);
    setState(() => _currentStep = step);
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        step,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeInOut,
      );
    }
    if (step == 6 &&
        _tasteRepo.currentProfile?.aiFeaturesEnabled == true &&
        _aiPersonaInsight == null) {
      _generatePersonaInsight();
    }
  }

  void _nextPage() {
    if (_currentStep < 7) {
      _goToStep(_currentStep + 1);
    } else {
      _finishOnboarding();
    }
  }

  void _prevPage() {
    if (_currentStep > 0) {
      _goToStep(_currentStep - 1);
    }
  }

  Future<void> _generatePersonaInsight() async {
    setState(() => _isGeneratingPersona = true);
    final tempProfile = _buildDraftProfile(status: TasteProfileStatus.inProgress);
    final insight =
        await _tasteRepo.grokAi.generateTastePersonaInsight(tempProfile);
    if (mounted) {
      setState(() {
        _aiPersonaInsight = insight;
        _isGeneratingPersona = false;
      });
    }
  }

  // The profile is stored under a (serverId, userId) key, and the wizard MUST
  // write to the same key the caller read from. TasteProfileRepository.loadProfile
  // stamps currentProfile with exactly the ids it was queried with - the home
  // screen passes client.baseUrl and client.userId - so currentProfile is the
  // authoritative key here. serverContext.primaryServerId was consulted first
  // before, and it returns an internal session id that need not equal the base
  // URL: the profile then saved under a key nobody reads back, the home screen
  // saw notStarted and reopened the wizard at the sync step. It only appeared
  // to work on the second attempt because the store returns its in-memory
  // fallback once something has been written.
  String _resolveUserId() {
    for (final candidate in [
      _tasteRepo.currentProfile?.userId,
      _client.userId,
      _tasteRepo.serverContext.authenticatedUserId,
    ]) {
      final value = candidate?.trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  String _resolveServerId() {
    for (final candidate in [
      _tasteRepo.currentProfile?.serverId,
      _client.baseUrl,
      _tasteRepo.serverContext.primaryServerId,
    ]) {
      final value = candidate?.trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return 'primary-server';
  }

  TasteProfile _buildDraftProfile({TasteProfileStatus? status}) {
    final serverId = _resolveServerId();
    final userId = _resolveUserId();

    final combinedRatings = <String, TasteRating>{}
      ..addAll(_restoredTitleRatings)
      ..addAll(_movieRatings)
      ..addAll(_seriesRatings);

    final combinedNames = <String, String>{};
    if (_tasteRepo.currentProfile?.explicit.titleNames != null) {
      combinedNames.addAll(_tasteRepo.currentProfile!.explicit.titleNames);
    }
    for (final item in _allMovies) {
      if (item.name.isNotEmpty && combinedRatings.containsKey(item.id)) {
        combinedNames[item.id] = item.name;
      }
    }
    for (final item in _allSeries) {
      if (item.name.isNotEmpty && combinedRatings.containsKey(item.id)) {
        combinedNames[item.id] = item.name;
      }
    }

    final explicit = ExplicitTasteProfile(
      titleRatings: combinedRatings,
      titleNames: combinedNames,
      genreRatings: _genreRatings,
      viewingPreferences: _viewingPreferences.copyWith(
        selectedPreferenceIds: _selectedPreferenceIds,
      ),
      selectedMoods: _selectedMoods,
      selectedMoodIds: _selectedMoodIds,
      freeTextDescription: _freeTextController.text.trim().isNotEmpty
          ? _freeTextController.text.trim()
          : null,
      completedAt: DateTime.now(),
    );

    final currentRev = int.tryParse(_tasteRepo.currentProfile?.profileRevision ?? '0') ?? 0;

    return TasteProfile(
      profileId: _tasteRepo.currentProfile?.profileId ??
          'profile_${DateTime.now().millisecondsSinceEpoch}',
      serverId: serverId,
      userId: userId,
      schemaVersion: 1,
      profileRevision: (currentRev + 1).toString(),
      createdAtUtc:
          _tasteRepo.currentProfile?.createdAtUtc ?? DateTime.now().toUtc(),
      updatedAtUtc: DateTime.now().toUtc(),
      lastUpdated: DateTime.now().toUtc(),
      status: status ?? TasteProfileStatus.completed,
      explicit: explicit,
      inferred: _tasteRepo.currentProfile?.inferred ?? InferredTasteProfile(),
      languageSettings: _languageSettings,
      aiFeaturesEnabled: _tasteRepo.currentProfile?.aiFeaturesEnabled ?? true,
      aiPersonaSummary: _aiPersonaInsight,
      azureBackupEnabled: _tasteRepo.currentProfile?.azureBackupEnabled ?? true,
      enabledHomeRows: _tasteRepo.currentProfile?.enabledHomeRows ?? const {},
    );
  }

  /// Wraps one wizard page so only the visible one can take D-Pad focus.
  ///
  /// Deliberately ONLY ExcludeFocus. Wrapping a page in a FocusScope or a
  /// FocusTraversalGroup makes it a traversal boundary: once the D-Pad entered
  /// the movie grid there was no way back down to the footer, so the wizard
  /// could not be advanced past step 1 at all. Sharing one traversal scope with
  /// the footer is what lets Down out of the grid reach Continue.
  Widget _focusablePage(int index, Widget child) {
    return ExcludeFocus(
      excluding: _currentStep != index,
      child: child,
    );
  }

  Future<void> _finishOnboarding() async {
    if (_finishing) return;

    // The profile is keyed by userId. On a first run there is no cached
    // profile to fall back on, so if the server context has not published the
    // authenticated user yet this used to save under an empty id: the home
    // screen then looked the profile up by the real id, found nothing, and
    // reopened the wizard at the sync step. The second run only worked because
    // the first had populated currentProfile. Resolve against the live client
    // first and refuse to complete without a real id.
    final userId = _resolveUserId();
    if (userId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text(
              'Still connecting to your server - give it a moment and try again.',
            ),
          ),
        );
      }
      return;
    }

    _draftSaveDebounce?.cancel();
    _draftSaveDebounce = null;

    setState(() => _finishing = true);
    try {
      final draft = _buildDraftProfile(status: TasteProfileStatus.completed);

      // AI Analysis: Determine top 3-5 home rows / curated collections based on user picks
      final suggestedRows = await _tasteRepo.grokAi.suggestTopHomeRows(draft);

      // Disable all 14 rows by default, then enable only the AI-suggested rows
      final initialEnabledRows = <String, bool>{
        for (final r in PersonalizationRowType.values) r.key: false,
      };
      for (final row in suggestedRows) {
        initialEnabledRows[row.key] = true;
      }

      final profile = draft.copyWith(enabledHomeRows: initialEnabledRows);
      await _tasteRepo.saveProfile(profile);
      _tasteRepo.startSilentBackgroundPopulation();
    } catch (e) {
      debugPrint('[TasteOnboarding] Failed to save profile: $e');
      if (mounted) {
        setState(() => _finishing = false);
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('Could not save your profile: $e')),
        );
      }
      return;
    }

    if (mounted) {
      if (widget.onComplete != null) {
        widget.onComplete!();
      } else {
        Navigator.of(context).maybePop();
      }
    }
  }

  Future<void> _skip() async {
    HapticFeedback.lightImpact();
    await _tasteRepo.skipOnboarding();
    if (mounted) {
      if (widget.onSkip != null) {
        widget.onSkip!();
      } else {
        Navigator.of(context).maybePop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_loading) {
      // Painted explicitly. This screen is hosted in a Dialog.fullscreen, which
      // takes its background from the ambient Material theme -- so a bare
      // Center rendered as a full WHITE screen carrying a spinner that is all
      // but invisible on a TV across the room.
      return ColoredBox(
        color: AppColorScheme.background,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                  'Retrieving stream choices to personalize your viewing '
                  'experience. This may take a minute.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColorScheme.onSurface),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return RequestInitialFocus(
      targetNode: _continueFocusNode,
      child: Column(
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColorScheme.accent.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.auto_awesome_rounded,
                    color: AppColorScheme.accent,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Taste Profile & Recommendations',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        'Step ${_currentStep + 1} of 8 · ${_stepTitle(_currentStep)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                _FocusRing(
                  builder: (node) => TextButton(
                    focusNode: node,
                    onPressed: _skip,
                    child: const Text('Skip (Remind Later)'),
                  ),
                ),
              ],
            ),
          ),

          // Progress Bar
          LinearProgressIndicator(
            value: (_currentStep + 1) / 8,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation(AppColorScheme.accent),
            minHeight: 3,
          ),

          // Page View
          Expanded(
            child: PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              onPageChanged: (page) {
                if (_currentStep != page) {
                  setState(() => _currentStep = page);
                }
              },
              children: [
                // Every page of a PageView stays alive in the widget tree, so
                // without this the D-Pad could focus chips on pages that are
                // off-screen - the user navigates and selects things they
                // cannot see. Only the visible page is focusable.
                _focusablePage(0, _buildStep0Sync(theme)),
                _focusablePage(1, _buildStep1Movies(theme)),
                _focusablePage(2, _buildStep2Series(theme)),
                _focusablePage(3, _buildStep3Genres(theme)),
                _focusablePage(4, _buildStep4ViewingLab(theme)),
                _focusablePage(5, _buildStep5Moods(theme)),
                _focusablePage(6, _buildStep6PerfectExperience(theme)),
                _focusablePage(7, _buildStep7ReviewAndComplete(theme)),
              ],
            ),
          ),

          // Footer Controls
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              border: Border(
                top: BorderSide(
                  color:
                      theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // The footer keeps a FIXED widget shape on every step. Adding
                // or removing a button between steps re-parented D-Pad focus
                // mid-press, and the rest of that press then activated the
                // button that slid underneath it - skipping a step. Only
                // enablement and opacity change now, never the structure.
                Opacity(
                  opacity: _currentStep > 0 ? 1.0 : 0.0,
                  child: _FocusRing(
                    builder: (node) => OutlinedButton.icon(
                      focusNode: node,
                      onPressed: _currentStep > 0 ? _prevPage : null,
                      icon: const Icon(Icons.arrow_back_rounded, size: 18),
                      label: const Text('Back'),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Opacity(
                      opacity:
                          (_currentStep == 1 || _currentStep == 2) ? 1.0 : 0.0,
                      child: _FocusRing(
                        builder: (node) => TextButton(
                          focusNode: node,
                          onPressed: (_currentStep == 1 || _currentStep == 2)
                              ? _nextPage
                              : null,
                          child: const Text('Skip Step'),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _FocusRing(
                      node: _continueFocusNode,
                      builder: (node) => FilledButton.icon(
                        focusNode: node,
                        onPressed: _finishing ? null : _nextPage,
                        icon: Icon(
                          _currentStep == 7
                              ? Icons.check_circle_rounded
                              : Icons.arrow_forward_rounded,
                          size: 18,
                        ),
                        label: Text(_currentStep == 7
                            ? 'Finish & Personalize'
                            : _currentStep == 0
                                ? 'Continue to Movies'
                                : 'Continue'),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColorScheme.accent,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 22, vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _stepTitle(int step) {
    switch (step) {
      case 0:
        return 'Data Synchronisation';
      case 1:
        return 'Movies';
      case 2:
        return 'Series';
      case 3:
        return 'Favorite Genres';
      case 4:
        return 'Viewing Experience Lab';
      case 5:
        return 'Moods & Vibes';
      case 6:
        return 'Perfect Experience';
      case 7:
        return 'Review & Completion';
      default:
        return '';
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Step 0: Data Preparation and Synchronisation
  // ──────────────────────────────────────────────────────────────────────────

  Widget _buildStep0Sync(ThemeData theme) {
    final syncState = _tasteRepo.syncManager.progressState;
    final isSyncing = _tasteRepo.syncManager.isSynchronizing;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.2),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  color: AppColorScheme.accent,
                  size: 24,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    'Retrieving stream choices to personalize your viewing experience. This may take a minute - it will be worth the wait.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),

          // Wheel / Spinner Progress
          SizedBox(
            width: 110,
            height: 110,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CircularProgressIndicator(
                  value: syncState.progressPercent / 100.0,
                  strokeWidth: 8,
                  backgroundColor:
                      theme.colorScheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation(AppColorScheme.accent),
                ),
                Center(
                  child: Text(
                    '${syncState.progressPercent.toInt()}%',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Exact Status Message
          Text(
            syncState.statusMessage,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),

          if (syncState.failoverMessage != null) ...[
            const SizedBox(height: 10),
            Text(
              syncState.failoverMessage!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.tertiary,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],

          const SizedBox(height: 28),

          // Step Checklist
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                _buildSyncChecklistItem(
                  title: 'Movies Library',
                  step: SyncStep.movies,
                  syncState: syncState,
                  theme: theme,
                ),
                const Divider(height: 16),
                _buildSyncChecklistItem(
                  title: 'Series & Shows Library',
                  step: SyncStep.series,
                  syncState: syncState,
                  theme: theme,
                ),
                const Divider(height: 16),
                _buildSyncChecklistItem(
                  title: 'Genre Topologies & Shelves',
                  step: SyncStep.genres,
                  syncState: syncState,
                  theme: theme,
                ),
                const Divider(height: 16),
                _buildSyncChecklistItem(
                  title: 'Viewing History & Affinities',
                  step: SyncStep.viewingLab,
                  syncState: syncState,
                  theme: theme,
                ),
                const Divider(height: 16),
                _buildSyncChecklistItem(
                  title: 'Mood & Vibe Taxonomy',
                  step: SyncStep.moodsAndVibes,
                  syncState: syncState,
                  theme: theme,
                ),
                const Divider(height: 16),
                _buildSyncChecklistItem(
                  title: 'Choice Retrieval Matrix',
                  step: SyncStep.perfectExperience,
                  syncState: syncState,
                  theme: theme,
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Retry / Cancel / Resume Controls
          if (syncState.errorMessage != null) ...[
            Text(
              syncState.errorMessage!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: 12),
            _FocusRing(
              builder: (node) => FilledButton.icon(
              focusNode: node,
              onPressed: () {
                // Same key resolution as _initializeWizard, so a retry
                // resumes the progress the first attempt saved instead of
                // starting a second, unrelated sync record.
                final serverId = _resolveServerId();
                final userId = _resolveUserId();
                _tasteRepo.syncManager.startOrResumeSync(
                  serverId: serverId,
                  userId: userId,
                  languageSettings: _languageSettings,
                  forceRestart: true,
                );
              },
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry Synchronisation'),
              ),
            ),
          ] else if (isSyncing) ...[
            OutlinedButton.icon(
              onPressed: () => _tasteRepo.syncManager.cancelSync(),
              icon: const Icon(Icons.cancel_outlined),
              label: const Text('Cancel Sync'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSyncChecklistItem({
    required String title,
    required SyncStep step,
    required SyncProgressState syncState,
    required ThemeData theme,
  }) {
    final isDone = syncState.completedSteps.contains(step);
    final isCurrent = syncState.currentStep == step && !isDone;

    return Row(
      children: [
        if (isDone)
          const Icon(Icons.check_circle_rounded, color: Colors.green, size: 20)
        else if (isCurrent)
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          )
        else
          Icon(
            Icons.radio_button_unchecked,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            size: 20,
          ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: isDone ? FontWeight.w600 : FontWeight.normal,
              color: isDone
                  ? theme.colorScheme.onSurface
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (isDone)
          Text(
            'Ready',
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.green),
          ),
      ],
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Step 1: Movies
  // ──────────────────────────────────────────────────────────────────────────

  Widget _buildStep1Movies(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Advice Banner
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppColorScheme.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: AppColorScheme.accent.withValues(alpha: 0.25),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.shuffle_rounded, size: 18, color: AppColorScheme.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Select titles you enjoy, and click Shuffle to randomize for more choices to select.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        Padding(
          padding: const EdgeInsets.fromLTRB(24, 6, 24, 8),
          child: Row(
            children: [
              _FocusRing(
                builder: (node) => OutlinedButton.icon(
                  focusNode: node,
                  onPressed: _refreshingMovies ? null : _shuffleMovies,
                  icon: _refreshingMovies
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.shuffle_rounded, size: 16),
                  label: Text(_refreshingMovies ? 'Shuffling...' : 'Shuffle'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: _HorizontalWheelGuard(
                    child: Row(
                      children: [
                        _buildFilterChip(
                          label: 'All Decades',
                          selected: _movieDecadeFilter == 'all',
                          onSelected: () => setState(() {
                            _movieDecadeFilter = 'all';
                            _applyMovieFilters();
                          }),
                        ),
                        const SizedBox(width: 8),
                        _buildFilterChip(
                          label: '2020s',
                          selected: _movieDecadeFilter == '2020',
                          onSelected: () => setState(() {
                            _movieDecadeFilter = '2020';
                            _applyMovieFilters();
                          }),
                        ),
                        const SizedBox(width: 8),
                        _buildFilterChip(
                          label: '2010s',
                          selected: _movieDecadeFilter == '2010',
                          onSelected: () => setState(() {
                            _movieDecadeFilter = '2010';
                            _applyMovieFilters();
                          }),
                        ),
                        const SizedBox(width: 8),
                        _buildFilterChip(
                          label: '2000s',
                          selected: _movieDecadeFilter == '2000',
                          onSelected: () => setState(() {
                            _movieDecadeFilter = '2000';
                            _applyMovieFilters();
                          }),
                        ),
                        const SizedBox(width: 8),
                        _buildFilterChip(
                          label: '1990s',
                          selected: _movieDecadeFilter == '1990',
                          onSelected: () => setState(() {
                            _movieDecadeFilter = '1990';
                            _applyMovieFilters();
                          }),
                        ),
                        const SizedBox(width: 8),
                        _buildFilterChip(
                          label: 'Classics',
                          selected: _movieDecadeFilter == 'classic',
                          onSelected: () => setState(() {
                            _movieDecadeFilter = 'classic';
                            _applyMovieFilters();
                          }),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 6),

        // Movie Cards Grid
        Expanded(
          child: _displayedMovies.isEmpty
              ? _buildEmptyCandidateState(
                  theme: theme,
                  noun: 'movies',
                  filtered: _movieDecadeFilter != 'all',
                )
              : GridView.builder(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 140,
                    childAspectRatio: 0.65,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: _displayedMovies.length,
                  itemBuilder: (context, index) {
                    final item = _displayedMovies[index];
                    final rating =
                        _movieRatings[item.id] ?? TasteRating.neutral;
                    return _buildMediaCard(
                      item: item,
                      rating: rating,
                      onCycleRating: () {
                        setState(() {
                          _movieRatings[item.id] = _nextRating(rating);
                        });
                        _saveDraftProgress();
                      },
                      theme: theme,
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _shuffleMovies() =>
      _shuffleFromServer(itemType: 'Movie', isMovies: true);

  Future<void> _shuffleSeries() =>
      _shuffleFromServer(itemType: 'Series', isMovies: false);

  /// Each live shuffle adds up to 100 items to the pool. Rated titles are
  /// never dropped; everything else is trimmed oldest-first so a long session
  /// on a low-memory TV box cannot grow the pool without bound.
  static const _maxCandidatePool = 1200;

  void _trimCandidatePool(List<AggregatedItem> pool) {
    if (pool.length <= _maxCandidatePool) return;
    final rated = <AggregatedItem>[];
    final rest = <AggregatedItem>[];
    for (final item in pool) {
      final isRated = _movieRatings.containsKey(item.id) ||
          _seriesRatings.containsKey(item.id) ||
          _restoredTitleRatings.containsKey(item.id);
      (isRated ? rated : rest).add(item);
    }
    final keep = (_maxCandidatePool - rated.length).clamp(0, rest.length);
    final trimmed = [...rated, ...rest.sublist(rest.length - keep)];
    pool
      ..clear()
      ..addAll(trimmed);
  }

  /// Asks the server for a fresh random draw rather than reshuffling what is
  /// already cached, so Shuffle can reach titles the Step 0 sync never pulled.
  ///
  /// Jellyfin's `SortBy=Random` does the drawing server-side. The result still
  /// goes through the recommendation engine so the language rules, edition
  /// dedupe and franchise cap all hold, and every fetched title is merged into
  /// the local cache so ratings and later filtering keep working offline.
  ///
  /// Any failure - offline, timeout, a server that ignores Random - falls back
  /// to a local reshuffle, so the button never dead-ends.
  Future<void> _shuffleFromServer({
    required String itemType,
    required bool isMovies,
  }) async {
    if (isMovies ? _refreshingMovies : _refreshingSeries) return;
    setState(() {
      if (isMovies) {
        _refreshingMovies = true;
      } else {
        _refreshingSeries = true;
      }
    });

    try {
      final client =
          _tasteRepo.serverContext.getPrimaryClient(_resolveServerId()) ??
              _client;
      final res = await client.itemsApi.getItems(
        recursive: true,
        includeItemTypes: [itemType],
        sortBy: 'Random',
        limit: 100,
        fields:
            'Genres,PrimaryImageAspectRatio,UserData,CommunityRating,VoteCount,'
            'CriticRating,ProductionYear,OfficialRating,RunTimeTicks,'
            'OriginalLanguage,MediaStreams,SpokenLanguages,CollectionId,'
            'SeriesId,ImageTags,Overview,People,ProviderIds',
      );

      final serverId = _resolveServerId();
      final fetched = <AggregatedItem>[];
      for (final raw in (res['Items'] as List? ?? [])
          .whereType<Map<String, dynamic>>()) {
        final id = raw['Id']?.toString() ?? '';
        if (id.isEmpty) continue;
        fetched.add(
          AggregatedItem(id: id, serverId: serverId, rawData: raw),
        );
      }

      if (fetched.isNotEmpty) {
        // Merge into the cache so the decade/format filters and the ratings
        // map keep seeing these titles after the draw.
        final knownIds = (isMovies ? _allMovies : _allSeries)
            .map((e) => e.id)
            .toSet();
        final additions =
            fetched.where((e) => !knownIds.contains(e.id)).toList();
        if (isMovies) {
          _allMovies.addAll(additions);
          _trimCandidatePool(_allMovies);
        } else {
          _allSeries.addAll(additions);
          _trimCandidatePool(_allSeries);
        }
      }
    } catch (e) {
      debugPrint('[TasteOnboarding] Live shuffle failed, using cache: $e');
    }

    if (!mounted) return;
    setState(() {
      if (isMovies) {
        _applyMovieFilters(randomize: true);
        _refreshingMovies = false;
      } else {
        _applySeriesFilters(randomize: true);
        _refreshingSeries = false;
      }
    });
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Step 2: Series
  // ──────────────────────────────────────────────────────────────────────────

  Widget _buildStep2Series(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Advice Banner
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AppColorScheme.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: AppColorScheme.accent.withValues(alpha: 0.25),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.shuffle_rounded, size: 18, color: AppColorScheme.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Select series you enjoy, and click Shuffle to randomize for more choices to select.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        Padding(
          padding: const EdgeInsets.fromLTRB(24, 6, 24, 8),
          child: Row(
            children: [
              _FocusRing(
                builder: (node) => OutlinedButton.icon(
                  focusNode: node,
                  onPressed: _refreshingSeries ? null : _shuffleSeries,
                  icon: _refreshingSeries
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.shuffle_rounded, size: 16),
                  label: Text(_refreshingSeries ? 'Shuffling...' : 'Shuffle'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: _HorizontalWheelGuard(
                    child: Row(
                      children: [
                        _buildFilterChip(
                          label: 'All Formats',
                          selected: _seriesFormatFilter == 'all',
                          onSelected: () => setState(() {
                            _seriesFormatFilter = 'all';
                            _applySeriesFilters();
                          }),
                        ),
                        const SizedBox(width: 8),
                        _buildFilterChip(
                          label: 'Limited Series',
                          selected: _seriesFormatFilter == 'limited',
                          onSelected: () => setState(() {
                            _seriesFormatFilter = 'limited';
                            _applySeriesFilters();
                          }),
                        ),
                        const SizedBox(width: 8),
                        _buildFilterChip(
                          label: 'Bingeable Favorites',
                          selected: _seriesFormatFilter == 'bingeable',
                          onSelected: () => setState(() {
                            _seriesFormatFilter = 'bingeable';
                            _applySeriesFilters();
                          }),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 6),

        // Series Grid
        Expanded(
          child: _displayedSeries.isEmpty
              ? _buildEmptyCandidateState(
                  theme: theme,
                  noun: 'series',
                  filtered: _seriesFormatFilter != 'all',
                )
              : GridView.builder(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 140,
                    childAspectRatio: 0.65,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: _displayedSeries.length,
                  itemBuilder: (context, index) {
                    final item = _displayedSeries[index];
                    final rating =
                        _seriesRatings[item.id] ?? TasteRating.neutral;
                    return _buildMediaCard(
                      item: item,
                      rating: rating,
                      onCycleRating: () {
                        setState(() {
                          _seriesRatings[item.id] = _nextRating(rating);
                        });
                        _saveDraftProgress();
                      },
                      theme: theme,
                    );
                  },
                ),
        ),
      ],
    );
  }



  Widget _buildMediaCard({
    required AggregatedItem item,
    required TasteRating rating,
    required VoidCallback onCycleRating,
    required ThemeData theme,
  }) {
    final posterUrl = item.id.isNotEmpty
        ? _client.imageApi.getPrimaryImageUrl(
            item.id,
            maxWidth: 240,
            maxHeight: 360,
            tag: item.primaryImageTag,
          )
        : null;

    return FocusableActionDetector(
      autofocus: false,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (intent) {
            HapticFeedback.selectionClick();
            onCycleRating();
            return null;
          },
        ),
      },
      child: Builder(
        builder: (ctx) {
          final isFocused = Focus.of(ctx).hasFocus;
          if (isFocused) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (ctx.mounted) {
                _ensureVisibleWithinNearestScrollable(
                  ctx,
                  alignment: 0.5,
                  alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOut,
                );
              }
            });
          }

          final borderColor = isFocused
              ? AppColorScheme.accent
              : _ratingBorderColor(rating);
          final borderWidth = isFocused
              ? 3.0
              : (rating != TasteRating.neutral && rating != TasteRating.unseen
                  ? 2.5
                  : 1.0);

          return GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              onCycleRating();
            },
            child: AnimatedScale(
              scale: isFocused ? 1.06 : 1.0,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: borderColor,
                    width: borderWidth,
                  ),
                  boxShadow: isFocused
                      ? [
                          BoxShadow(
                            color: AppColorScheme.accent.withValues(alpha: 0.55),
                            blurRadius: 14,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: posterUrl != null && posterUrl.isNotEmpty
                          ? BoundedNetworkImage(
                              imageUrl: posterUrl,
                              fit: BoxFit.cover,
                              maxWidth: 240,
                              minWidth: 64,
                              errorBuilder: (_, _, _) => Container(
                                color: theme.colorScheme.surfaceContainerHighest,
                                child: const Center(
                                  child: Icon(Icons.movie_outlined,
                                      size: 28, color: Colors.white38),
                                ),
                              ),
                            )
                          : Container(
                              color: theme.colorScheme.surfaceContainerHighest,
                              child: const Center(
                                child: Icon(Icons.movie_outlined,
                                    size: 28, color: Colors.white38),
                              ),
                            ),
                    ),
                    // Gradient Overlay
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withValues(alpha: 0.1),
                            Colors.black.withValues(alpha: 0.85),
                          ],
                          stops: const [0.5, 1.0],
                        ),
                      ),
                    ),
                    // Focus Indicator Badge (when focused on TV)
                    if (isFocused)
                      Positioned(
                        top: 6,
                        left: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColorScheme.accent,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'SELECT',
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                    // Title & Year
                    Positioned(
                      bottom: 6,
                      left: 6,
                      right: 6,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            item.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              height: 1.15,
                            ),
                          ),
                          if (item.productionYear != null)
                            Text(
                              '${item.productionYear}',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.7),
                                fontSize: 9.5,
                              ),
                            ),
                        ],
                      ),
                    ),
                    // Rating Badge
                    if (rating != TasteRating.neutral && rating != TasteRating.unseen)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 3),
                          decoration: BoxDecoration(
                            color: _ratingBadgeColor(rating),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            _ratingEmoji(rating),
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Step 3: Genres (Light Blue Background & Black Text on Selection)
  // ──────────────────────────────────────────────────────────────────────────

  Widget _buildStep3Genres(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Rate genres from your primary library shelves to calibrate recommendations.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _serverGenres.map((genre) {
              final key = genre.key;
              final rating = _genreRatings[key] ?? TasteRating.neutral;
              final isSelected = rating != TasteRating.neutral &&
                  rating != TasteRating.unseen;

              return _buildSelectableChip(
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      genre.label,
                      style: TextStyle(
                        color: isSelected ? Colors.black : theme.colorScheme.onSurface,
                        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    if (isSelected) ...[
                      const SizedBox(width: 4),
                      Text(_ratingEmoji(rating)),
                    ],
                  ],
                ),
                selected: isSelected,
                selectedColor: const Color(0xFFBAE6FD), // Light blue shade (Tailwind Sky 200)
                onSelected: () {
                  setState(() {
                    _genreRatings[key] = _nextRating(rating);
                  });
                  _saveDraftProgress();
                },
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Step 4: Viewing Experience Lab
  // ──────────────────────────────────────────────────────────────────────────

  Widget _buildStep4ViewingLab(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Customize viewing pacing, format balance, and runtime limits.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),

          // Format Balance
          _buildLabSectionHeader('Format Balance', theme),
          Row(
            children: [
              _buildChoiceChip(
                label: 'Both Movies & Series',
                selected: _viewingPreferences.formatPreference == 'both',
                onSelected: () => setState(() {
                  _viewingPreferences = _viewingPreferences.copyWith(
                      formatPreference: 'both');
                  _saveDraftProgress();
                }),
              ),
              const SizedBox(width: 8),
              _buildChoiceChip(
                label: 'Movies Only',
                selected: _viewingPreferences.formatPreference == 'movies',
                onSelected: () => setState(() {
                  _viewingPreferences = _viewingPreferences.copyWith(
                      formatPreference: 'movies');
                  _saveDraftProgress();
                }),
              ),
              const SizedBox(width: 8),
              _buildChoiceChip(
                label: 'Series Only',
                selected: _viewingPreferences.formatPreference == 'series',
                onSelected: () => setState(() {
                  _viewingPreferences = _viewingPreferences.copyWith(
                      formatPreference: 'series');
                  _saveDraftProgress();
                }),
              ),
            ],
          ),

          const SizedBox(height: 20),

          // Movie Runtime Limits
          _buildLabSectionHeader('Movie Runtime Limit', theme),
          Row(
            children: [
              _buildChoiceChip(
                label: 'Any Length',
                selected: _viewingPreferences.maxMovieLengthMinutes == 0,
                onSelected: () => setState(() {
                  _viewingPreferences = _viewingPreferences.copyWith(
                      maxMovieLengthMinutes: 0);
                  _saveDraftProgress();
                }),
              ),
              const SizedBox(width: 8),
              _buildChoiceChip(
                label: '< 90 mins',
                selected: _viewingPreferences.maxMovieLengthMinutes == 90,
                onSelected: () => setState(() {
                  _viewingPreferences = _viewingPreferences.copyWith(
                      maxMovieLengthMinutes: 90);
                  _saveDraftProgress();
                }),
              ),
              const SizedBox(width: 8),
              _buildChoiceChip(
                label: '< 120 mins',
                selected: _viewingPreferences.maxMovieLengthMinutes == 120,
                onSelected: () => setState(() {
                  _viewingPreferences = _viewingPreferences.copyWith(
                      maxMovieLengthMinutes: 120);
                  _saveDraftProgress();
                }),
              ),
            ],
          ),

          const SizedBox(height: 20),

          // Binge vs Weekly
          _buildLabSectionHeader('Pacing & Viewing Style', theme),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildChoiceChip(
                label: 'Binge-Watcher',
                selected:
                    _selectedPreferenceIds.contains('style_binge_watcher'),
                onSelected: () => _togglePreferenceId('style_binge_watcher'),
              ),
              _buildChoiceChip(
                label: 'Weekly Episodic',
                selected: _selectedPreferenceIds.contains('style_episodic'),
                onSelected: () => _togglePreferenceId('style_episodic'),
              ),
              _buildChoiceChip(
                label: 'Slow-Burn Cinema',
                selected: _selectedPreferenceIds.contains('style_slow_burn') ||
                    _viewingPreferences.pacingPreference == 'slow-burn',
                onSelected: () => _togglePreferenceId('style_slow_burn'),
              ),
              _buildChoiceChip(
                label: 'Fast-Paced Action',
                selected: _selectedPreferenceIds.contains('style_fast_paced') ||
                    _viewingPreferences.pacingPreference == 'fast',
                onSelected: () => _togglePreferenceId('style_fast_paced'),
              ),
            ],
          ),

          const SizedBox(height: 20),

          // Era Preferences
          _buildLabSectionHeader('Preferred Release Era', theme),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildChoiceChip(
                label: 'All Eras',
                selected: _viewingPreferences.preferredEra == 'any',
                onSelected: () => setState(() {
                  _viewingPreferences = _viewingPreferences.copyWith(
                      preferredEra: 'any');
                  _saveDraftProgress();
                }),
              ),
              _buildChoiceChip(
                label: 'Modern (2015+)',
                selected: _viewingPreferences.preferredEra == 'modern',
                onSelected: () => setState(() {
                  _viewingPreferences = _viewingPreferences.copyWith(
                      preferredEra: 'modern');
                  _saveDraftProgress();
                }),
              ),
              _buildChoiceChip(
                label: 'Golden Age (1990–2014)',
                selected: _viewingPreferences.preferredEra == 'golden',
                onSelected: () => setState(() {
                  _viewingPreferences = _viewingPreferences.copyWith(
                      preferredEra: 'golden');
                  _saveDraftProgress();
                }),
              ),
              _buildChoiceChip(
                label: 'Classics (< 1990)',
                selected: _viewingPreferences.preferredEra == 'classic',
                onSelected: () => setState(() {
                  _viewingPreferences = _viewingPreferences.copyWith(
                      preferredEra: 'classic');
                  _saveDraftProgress();
                }),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _togglePreferenceId(String id) {
    setState(() {
      if (_selectedPreferenceIds.contains(id)) {
        _selectedPreferenceIds.remove(id);
      } else {
        _selectedPreferenceIds.add(id);
      }

      // Synchronize pacingPreference with selected style IDs
      if (id == 'style_slow_burn') {
        if (_selectedPreferenceIds.contains('style_slow_burn')) {
          _selectedPreferenceIds.remove('style_fast_paced');
          _viewingPreferences = _viewingPreferences.copyWith(
            pacingPreference: 'slow-burn',
          );
        } else {
          _viewingPreferences = _viewingPreferences.copyWith(
            pacingPreference: 'any',
          );
        }
      } else if (id == 'style_fast_paced') {
        if (_selectedPreferenceIds.contains('style_fast_paced')) {
          _selectedPreferenceIds.remove('style_slow_burn');
          _viewingPreferences = _viewingPreferences.copyWith(
            pacingPreference: 'fast',
          );
        } else {
          _viewingPreferences = _viewingPreferences.copyWith(
            pacingPreference: 'any',
          );
        }
      }

      _viewingPreferences = _viewingPreferences.copyWith(
        selectedPreferenceIds: _selectedPreferenceIds,
      );
    });
    _saveDraftProgress();
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Step 5: Moods and Vibes
  // ──────────────────────────────────────────────────────────────────────────

  Widget _buildStep5Moods(ThemeData theme) {
    final categories = TasteMoodRegistry.categories;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // No search field here. A TextField is the first focusable widget on
        // the page, so on a TV it grabbed D-Pad focus and threw up the
        // on-screen keyboard before the user could reach a single mood chip.
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Pick the vibes you are drawn to. Choose as many as you like.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (_selectedMoodIds.isNotEmpty) ...[
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFBAE6FD),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${_selectedMoodIds.length} selected',
                    style: const TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            itemCount: categories.length,
            itemBuilder: (context, index) {
              final catId = categories[index];
              final catName = TasteMoodRegistry.categoryName(catId);
              final moods = TasteMoodRegistry.getByCategory(catId);
              if (moods.isEmpty) return const SizedBox.shrink();

              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      catName,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: moods.map((mood) {
                        final isSelected =
                            _selectedMoodIds.contains(mood.id);
                        return _buildSelectableChip(
                          label: Text(
                            mood.displayName,
                            style: TextStyle(
                              color: isSelected ? Colors.black : theme.colorScheme.onSurface,
                              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                            ),
                          ),
                          selected: isSelected,
                          selectedColor: const Color(0xFFBAE6FD),
                          onSelected: () {
                            setState(() {
                              if (isSelected) {
                                _selectedMoodIds.remove(mood.id);
                              } else {
                                _selectedMoodIds.add(mood.id);
                              }
                            });
                            _saveDraftProgress();
                          },
                        );
                      }).toList(),
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

  // ──────────────────────────────────────────────────────────────────────────
  // Step 6: Perfect Experience
  // ──────────────────────────────────────────────────────────────────────────

  Widget _buildStep6PerfectExperience(ThemeData theme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Your Generated Experience Matrix',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Here is a preview of the dynamic recommendation rows tailored to your profile.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),

          // Grok AI Persona Summary Card if enabled
          if (_tasteRepo.currentProfile?.aiFeaturesEnabled == true) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiaryContainer
                    .withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: theme.colorScheme.tertiary.withValues(alpha: 0.3),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.auto_awesome_rounded,
                        color: AppColorScheme.accent,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'AI Taste Persona Insight',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_isGeneratingPersona)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 12),
                          Text('Synthesizing your cinematic persona...'),
                        ],
                      ),
                    )
                  else
                    Text(
                      _aiPersonaInsight ??
                          'Curating top titles, narrative arcs, and atmospheric preferences based on your inputs.',
                      style: theme.textTheme.bodyMedium,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 20),
          ],

          // Home Rows List Preview
          _buildHomeRowPreviewCard(
            title: 'Recommended for You',
            subtitle: 'Weighted multi-genre scoring with diversity balance.',
            icon: Icons.recommend_rounded,
            theme: theme,
          ),
          const SizedBox(height: 12),
          _buildHomeRowPreviewCard(
            title: 'Series You Might Binge',
            subtitle: 'Optimized for high ratings and engaging storylines.',
            icon: Icons.tv_rounded,
            theme: theme,
          ),
          const SizedBox(height: 12),
          _buildHomeRowPreviewCard(
            title: 'Matching Your Mood',
            subtitle:
                'Filtered dynamically to match selected vibe profiles.',
            icon: Icons.mood_rounded,
            theme: theme,
          ),
          const SizedBox(height: 12),
          _buildHomeRowPreviewCard(
            title: 'Hidden Gems',
            subtitle: 'Critically acclaimed titles you may not have discovered yet.',
            icon: Icons.diamond_outlined,
            theme: theme,
          ),
        ],
      ),
    );
  }

  Widget _buildHomeRowPreviewCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required ThemeData theme,
  }) {
    // Step 6 was built entirely from Containers and Text, so it held no
    // focusable widget at all. On a TV that makes the page impossible to enter
    // with the D-Pad and it reads as if the wizard skipped it. The cards are
    // now focus targets: they highlight and scroll into view like every other
    // control in the wizard, even though there is nothing to activate.
    return FocusableActionDetector(
      child: Builder(
        builder: (ctx) {
          final isFocused = Focus.of(ctx).hasFocus;
          if (isFocused) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (ctx.mounted) {
                _ensureVisibleWithinNearestScrollable(
                  ctx,
                  alignment: 0.5,
                  alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeOut,
                );
              }
            });
          }
          return AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: isFocused
                  ? Border.all(color: AppColorScheme.accent, width: 2.5)
                  : Border.all(color: Colors.transparent, width: 2.5),
              boxShadow: isFocused
                  ? [
                      BoxShadow(
                        color: AppColorScheme.accent.withValues(alpha: 0.45),
                        blurRadius: 10,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: _homeRowPreviewBody(
              title: title,
              subtitle: subtitle,
              icon: icon,
              theme: theme,
            ),
          );
        },
      ),
    );
  }

  Widget _homeRowPreviewBody({
    required String title,
    required String subtitle,
    required IconData icon,
    required ThemeData theme,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColorScheme.accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: AppColorScheme.accent, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  subtitle,
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

  // ──────────────────────────────────────────────────────────────────────────
  // Step 7: Profile Review and Completion
  // ──────────────────────────────────────────────────────────────────────────

  Widget _buildStep7ReviewAndComplete(ThemeData theme) {
    final ratedMoviesCount = _movieRatings.values
        .where((r) => r != TasteRating.neutral && r != TasteRating.unseen)
        .length;
    final ratedSeriesCount = _seriesRatings.values
        .where((r) => r != TasteRating.neutral && r != TasteRating.unseen)
        .length;
    final ratedGenresCount = _genreRatings.values
        .where((r) => r != TasteRating.neutral && r != TasteRating.unseen)
        .length;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Ready to Personalize Voltix',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Review your preferences below. You can adjust these anytime in Settings.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),

          // Summary Statistics
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                _buildSummaryRow(
                  label: 'Movies Rated',
                  value: '$ratedMoviesCount titles',
                  icon: Icons.movie_outlined,
                  theme: theme,
                ),
                const Divider(height: 18),
                _buildSummaryRow(
                  label: 'Series Rated',
                  value: '$ratedSeriesCount titles',
                  icon: Icons.tv_outlined,
                  theme: theme,
                ),
                const Divider(height: 18),
                _buildSummaryRow(
                  label: 'Genres Calibrated',
                  value: '$ratedGenresCount genres',
                  icon: Icons.category_outlined,
                  theme: theme,
                ),
                const Divider(height: 18),
                _buildSummaryRow(
                  label: 'Moods & Vibes Selected',
                  value: '${_selectedMoodIds.length} vibes',
                  icon: Icons.mood_outlined,
                  theme: theme,
                ),
              ],
            ),
          ),

          const SizedBox(height: 32),

          // Action Button
          SizedBox(
            width: double.infinity,
            child: _FocusRing(
              builder: (node) => FilledButton.icon(
              focusNode: node,
              onPressed: _finishing ? null : _finishOnboarding,
              icon: _finishing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check_circle_rounded),
              label: Text(
                _finishing
                    ? 'AI personalizing your home rows...'
                    : 'Complete & Launch Personalized Experience',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: AppColorScheme.accent,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryRow({
    required String label,
    required String value,
    required IconData icon,
    required ThemeData theme,
  }) {
    return Row(
      children: [
        Icon(icon, size: 20, color: AppColorScheme.accent),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Helper Widgets & Rating Mapping
  // ──────────────────────────────────────────────────────────────────────────

  Widget _buildFilterChip({
    required String label,
    required bool selected,
    required VoidCallback onSelected,
  }) =>
      _buildChoiceChip(
        label: label,
        selected: selected,
        onSelected: onSelected,
      );

  Widget _buildChoiceChip({
    required String label,
    required bool selected,
    required VoidCallback onSelected,
  }) {
    // The chip's own actions only fire if something upstream turns the remote's
    // OK press into an ActivateIntent. Hosted inside a fullscreen dialog that
    // plumbing does not reach these chips, so the press focused them and did
    // nothing. Handling the key here as well makes selection work on its own
    // terms, and handleOneShotSelect is what keeps the D-Pad's key-repeat from
    // toggling a chip twice per press -- the same repeat behaviour already
    // documented on _stepCooldown above.
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) => handleOneShotSelect(event, onSelected),
      child: FocusableActionDetector(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (intent) {
            HapticFeedback.selectionClick();
            onSelected();
            return null;
          },
        ),
        ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
          onInvoke: (intent) {
            HapticFeedback.selectionClick();
            onSelected();
            return null;
          },
        ),
      },
      child: Builder(
        builder: (ctx) {
          final isFocused = Focus.of(ctx).hasFocus;
          if (isFocused) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (ctx.mounted) {
                _ensureVisibleWithinNearestScrollable(
                  ctx,
                  alignment: 0.5,
                  alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeOut,
                );
              }
            });
          }
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              HapticFeedback.selectionClick();
              onSelected();
            },
            child: AnimatedScale(
              scale: isFocused ? 1.08 : 1.0,
              duration: const Duration(milliseconds: 100),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: isFocused
                      ? Border.all(color: AppColorScheme.accent, width: 3)
                      : null,
                  boxShadow: isFocused
                      ? [
                          BoxShadow(
                            color: AppColorScheme.accent.withValues(alpha: 0.5),
                            blurRadius: 14,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
                padding: const EdgeInsets.all(3),
                child: ExcludeFocus(
                  child: ChoiceChip(
                    label: Text(label),
                    selected: selected,
                    selectedColor: const Color(0xFFBAE6FD),
                    labelStyle: TextStyle(
                      color: selected ? Colors.black : null,
                      fontWeight: selected ? FontWeight.w700 : null,
                    ),
                    onSelected: (_) {
                      HapticFeedback.selectionClick();
                      onSelected();
                    },
                  ),
                ),
              ),
            ),
          );
        },
      ),
      ),
    );
  }

  Widget _buildSelectableChip({
    required Widget label,
    required bool selected,
    Color? selectedColor,
    required VoidCallback onSelected,
  }) {
    return FocusableActionDetector(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (intent) {
            HapticFeedback.selectionClick();
            onSelected();
            return null;
          },
        ),
        ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
          onInvoke: (intent) {
            HapticFeedback.selectionClick();
            onSelected();
            return null;
          },
        ),
      },
      child: Builder(
        builder: (ctx) {
          final isFocused = Focus.of(ctx).hasFocus;
          if (isFocused) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (ctx.mounted) {
                _ensureVisibleWithinNearestScrollable(
                  ctx,
                  alignment: 0.5,
                  alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeOut,
                );
              }
            });
          }
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              HapticFeedback.selectionClick();
              onSelected();
            },
            child: AnimatedScale(
              scale: isFocused ? 1.08 : 1.0,
              duration: const Duration(milliseconds: 100),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: isFocused
                      ? Border.all(color: AppColorScheme.accent, width: 3)
                      : null,
                  boxShadow: isFocused
                      ? [
                          BoxShadow(
                            color: AppColorScheme.accent.withValues(alpha: 0.5),
                            blurRadius: 14,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
                padding: const EdgeInsets.all(3),
                child: ExcludeFocus(
                  child: FilterChip(
                    label: label,
                    selected: selected,
                    selectedColor: selectedColor ?? const Color(0xFFBAE6FD),
                    checkmarkColor: selected ? Colors.black : null,
                    side: BorderSide(
                      color: selected
                          ? const Color(0xFF38BDF8)
                          : Theme.of(ctx)
                              .colorScheme
                              .outlineVariant
                              .withValues(alpha: 0.4),
                      width: selected ? 1.5 : 1.0,
                    ),
                    onSelected: (_) {
                      HapticFeedback.selectionClick();
                      onSelected();
                    },
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// "No movies found matching filter" was shown even while the Step 0 sync
  /// was still pulling the library, which reads as a broken screen rather than
  /// a slow one. Say what is actually happening, and offer the way out.
  Widget _buildEmptyCandidateState({
    required ThemeData theme,
    required String noun,
    required bool filtered,
  }) {
    final syncing = !_tasteRepo.syncManager.progressState.isCompleted;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (syncing) ...[
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(height: 16),
              Text(
                'Still pulling $noun from your server. They will appear here '
                'as soon as the library finishes indexing.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ] else ...[
              Icon(
                Icons.movie_filter_outlined,
                size: 34,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              Text(
                filtered
                    ? 'No $noun matched that filter.'
                    : 'No $noun to show yet.',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                filtered
                    ? 'Pick a different filter, or hit Shuffle to pull a fresh '
                        'batch straight from the server.'
                    : 'Hit Shuffle to pull a fresh batch straight from the '
                        'server, or skip this step.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLabSectionHeader(String title, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  TasteRating _nextRating(TasteRating current) {
    switch (current) {
      case TasteRating.neutral:
        return TasteRating.love;
      case TasteRating.love:
        return TasteRating.like;
      case TasteRating.like:
        return TasteRating.dislike;
      case TasteRating.dislike:
        return TasteRating.unseen;
      case TasteRating.unseen:
        return TasteRating.neutral;
    }
  }

  Color _ratingBorderColor(TasteRating rating) {
    switch (rating) {
      case TasteRating.love:
        return Colors.transparent;
      case TasteRating.like:
        return Colors.blueAccent;
      case TasteRating.dislike:
        return Colors.redAccent;
      case TasteRating.unseen:
      case TasteRating.neutral:
        return Colors.transparent;
    }
  }

  Color _ratingBadgeColor(TasteRating rating) {
    switch (rating) {
      case TasteRating.love:
        return Colors.transparent;
      case TasteRating.like:
        return Colors.blueAccent;
      case TasteRating.dislike:
        return Colors.redAccent;
      case TasteRating.unseen:
      case TasteRating.neutral:
        return Colors.grey;
    }
  }

  String _ratingEmoji(TasteRating rating) {
    switch (rating) {
      case TasteRating.love:
        return '❤️';
      case TasteRating.like:
        return '👍';
      case TasteRating.dislike:
        return '👎';
      case TasteRating.unseen:
      case TasteRating.neutral:
        return '';
    }
  }
}

/// A [Scrollable.ensureVisible] that stops at the nearest enclosing
/// [Scrollable] instead of climbing into every ancestor Scrollable the way
/// the built-in static method does.
///
/// Scrollable.ensureVisible walks outward and animates EVERY Scrollable it
/// finds along the way -- useful when a focused item sits inside nested
/// lists that all need to reveal it, but wrong here: every chip and card in
/// this wizard lives inside the wizard's own outer PageView, which is also
/// a Scrollable. NeverScrollableScrollPhysics on that PageView only blocks
/// user drag, not a programmatic ensureVisible, so the built-in helper was
/// quietly nudging the whole page over and back on every focus change --
/// what read as the entire wizard screen jumping each time focus moved
/// between the era/format chips (or the Shuffle button beside them).
Future<void> _ensureVisibleWithinNearestScrollable(
  BuildContext context, {
  double alignment = 0.0,
  Duration duration = Duration.zero,
  Curve curve = Curves.ease,
  ScrollPositionAlignmentPolicy alignmentPolicy =
      ScrollPositionAlignmentPolicy.explicit,
}) async {
  final scrollable = Scrollable.maybeOf(context);
  final renderObject = context.findRenderObject();
  if (scrollable == null || renderObject == null) return;
  await scrollable.position.ensureVisible(
    renderObject,
    alignment: alignment,
    duration: duration,
    curve: curve,
    alignmentPolicy: alignmentPolicy,
  );
}

/// Stops a vertical mouse-wheel scroll from dragging a horizontal filter
/// strip sideways.
///
/// Flutter's default [Scrollable] falls back to the wheel's vertical delta
/// whenever the horizontal delta is zero, which is exactly what a plain
/// mouse wheel reports. That made the decade/format filter chips next to
/// the Shuffle button visibly slide left/right any time the cursor merely
/// passed over that row while the user was scrolling the page below.
/// Wrapping the chip [Row] in this [Listener] intercepts vertical-dominant
/// wheel events before the ancestor [SingleChildScrollView] sees them
/// (child listeners are dispatched before their ancestors), consuming
/// those and leaving genuine horizontal wheel/trackpad input -- and
/// drag / D-Pad `Scrollable.ensureVisible` scrolling -- untouched.
class _HorizontalWheelGuard extends StatelessWidget {
  final Widget child;
  const _HorizontalWheelGuard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent &&
            event.scrollDelta.dy.abs() >= event.scrollDelta.dx.abs()) {
          GestureBinding.instance.pointerSignalResolver.register(event, (_) {});
        }
      },
      child: child,
    );
  }
}

/// A high-contrast focus ring for controls that bring their own focus node.
///
/// Material's default focus treatment is a faint overlay tint - fine at arm's
/// length with a mouse, invisible across a lounge. Everything the D-Pad can
/// land on wears this instead: a thick accent border plus a glow, so where you
/// are is never in question. The ring is drawn OUTSIDE the child and reserves
/// its own space, so nothing shifts when focus arrives.
class _FocusRing extends StatefulWidget {
  final Widget Function(FocusNode node) builder;

  /// Supply a node when something else needs to drive focus to this control
  /// (the wizard hands its own node to the primary Continue button so the
  /// first thing highlighted on open is Continue, not the Skip link).
  final FocusNode? node;

  const _FocusRing({
    required this.builder,
    this.node,
  });

  @override
  State<_FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<_FocusRing> {
  FocusNode? _ownNode;

  FocusNode get _node => widget.node ?? (_ownNode ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _node.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(_FocusRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.node, widget.node)) {
      oldWidget.node?.removeListener(_onFocusChanged);
      _node.addListener(_onFocusChanged);
    }
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _node.removeListener(_onFocusChanged);
    // Only dispose a node this widget created; a caller-supplied node is
    // owned by the caller.
    _ownNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focused = _node.hasFocus;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: focused ? AppColorScheme.accent : Colors.transparent,
          width: 3,
        ),
        boxShadow: focused
            ? [
                BoxShadow(
                  color: AppColorScheme.accent.withValues(alpha: 0.5),
                  blurRadius: 14,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: widget.builder(_node),
    );
  }
}
