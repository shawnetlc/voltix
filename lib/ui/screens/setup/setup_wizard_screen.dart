import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:voltix_design/voltix_design.dart';
import 'package:server_core/server_core.dart';

import '../../../auth/store/voltix_session_store.dart';
import '../../../data/repositories/taste_profile_repository.dart';
import '../../../data/services/media_server_client_factory.dart';
import '../../../data/services/user_settings_sync_service.dart';
import '../taste_profile/taste_onboarding_wizard.dart';
import '../../../l10n/app_localizations.dart';
import '../../../preference/preference_constants.dart';
import '../../../preference/user_preferences.dart';
import '../../../util/focus/dpad_keys.dart';
import '../../../util/platform_detection.dart';
import '../../navigation/destinations.dart';
import '../../theme/app_theme_controller.dart';
import '../../widgets/login_scaffold.dart';
import '../../widgets/navigation_layout.dart';
import 'setup_wizard_gate.dart';
import 'setup_wizard_previews.dart';

/// The first thing a new user sees after signing in.
///
/// Three questions about how the app should look, then a screen showing what
/// else is in here. It only ever asks about things it can't work out on its
/// own, and only about things a person can answer by looking.
class SetupWizardScreen extends StatefulWidget {
  const SetupWizardScreen({super.key});

  @override
  State<SetupWizardScreen> createState() => _SetupWizardScreenState();
}

class _SetupWizardScreenState extends State<SetupWizardScreen> {
  final _prefs = GetIt.instance<UserPreferences>();
  final _gate = GetIt.instance<SetupWizardGate>();

  final _scopeNode = FocusScopeNode(debugLabel: 'setupWizard');
  final _skipNode = FocusNode(debugLabel: 'setupWizardSkip');
  // Reused across every step. The Next/Back/Skip buttons never lose focus on
  // their own when `setState` swaps the step body in underneath them --
  // that Row is never rebuilt from scratch, so autofocus on a fresh option
  // card can't win against a FocusNode that already holds focus elsewhere
  // in the same FocusScope. Requesting focus onto this node explicitly after
  // every step change is what actually moves the d-pad/keyboard cursor onto
  // the new step's default selection.
  final _stepDefaultFocusNode = FocusNode(debugLabel: 'setupStepDefault');

  List<SetupStep> _steps = const [];
  int _index = 0;
  bool _ready = false;
  bool _leaving = false;
  bool _advancing = true;

  // Held rather than written as they are chosen. Each write kicks off a full
  // profile push that the plugin then echoes back, so the answers across the
  // steps become one batch at the end.
  // Cloud data lives behind a network probe, so the step is appended only
  // once the probe answers -- and only after every default step is done.
  bool _cloudPromptPending = false;
  // Taste needs no probe -- a preference says whether it has been offered.
  bool _tastePromptPending = false;
  bool _tasteChoice = true;
  String? _cloudUsername;
  CloudDataAction? _cloudChoice;

  NavbarPosition? _navbar;
  String? _mediaBar;
  HomeRowsStyle? _homeRows;
  DetailScreenStyle? _detailStyle;

  MediaServerClient? get _client {
    try {
      return GetIt.instance<MediaServerClientFactory>().getActiveClient();
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    _scopeNode.dispose();
    _skipNode.dispose();
    _stepDefaultFocusNode.dispose();
    super.dispose();
  }

  /// Moves focus onto whichever card the current step marks as its default
  /// selection. Called after every step transition (and once the first step
  /// is ready) because autofocus alone won't grab focus away from whatever
  /// already holds it -- see the field doc on [_stepDefaultFocusNode].
  void _focusStepDefault() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _stepDefaultFocusNode.requestFocus();
    });
  }

  Future<void> _prepare() async {
    final client = _client;
    if (client == null) {
      _giveUpForNow();
      return;
    }

    final settled = await _gate.waitForSettings(client);
    if (!mounted) return;
    if (!settled) {
      _giveUpForNow();
      return;
    }

    // Kicked off now so the previews carry real artwork by the time the user
    // reaches them. Home shares the same view model, so nothing loads twice.
    unawaited(SetupPreviewData.ensureLoaded());
    unawaited(_probeCloudData());

    final steps = _gate.remainingSteps();
    if (steps.isEmpty) {
      // Everything here was answered on another device. Nothing to show, and
      // nothing to ask again.
      await _gate.markComplete(client);
      _goHome();
      return;
    }

    var tastePromptPending = !_prefs.get(UserPreferences.tasteOnboardingSeen);

    // Same restore-before-asking check as the login screen: a profile
    // already completed elsewhere (roaming DisplayPreferences, or an Azure
    // backup from a previous device) should skip this step rather than make
    // the user answer it again just because it is a fresh install here.
    if (tastePromptPending &&
        GetIt.instance.isRegistered<TasteProfileRepository>() &&
        GetIt.instance.isRegistered<MediaServerClient>()) {
      try {
        final tasteClient = GetIt.instance<MediaServerClient>();
        final userId = tasteClient.userId?.trim() ?? '';
        if (userId.isNotEmpty) {
          final restored = await GetIt.instance<TasteProfileRepository>()
              .loadProfile(userId: userId, serverId: tasteClient.baseUrl)
              .timeout(const Duration(seconds: 6));
          if (restored.isCompleted) {
            tastePromptPending = false;
            await _prefs.set(UserPreferences.tasteOnboardingSeen, true);
          }
        }
      } catch (_) {
        // A restore failure just means the step still gets asked, which is
        // the safe default -- it must not block the rest of the wizard.
      }
    }

    if (!mounted) return;
    setState(() {
      _steps = steps;
      _tastePromptPending = tastePromptPending;
      _ready = true;
    });
    _focusStepDefault();
  }

  /// Asks the sync service whether this user has cloud data, in the
  /// background. Deliberately not awaited: the questions are answerable
  /// without it, and the answer is only needed once they are done.
  Future<void> _probeCloudData() async {
    if (!GetIt.instance.isRegistered<UserSettingsSyncService>()) return;
    final username = GetIt.instance<VoltixSessionStore>().username?.trim();
    if (username == null || username.isEmpty) return;

    final pending = await GetIt.instance<UserSettingsSyncService>()
        .hasPendingCloudPrompt(username);
    if (!mounted || !pending) return;

    setState(() {
      _cloudPromptPending = true;
      _cloudUsername = username;
    });
  }

  /// The steps that only make sense once every default question is answered,
  /// in the order they are added. Cloud comes first: an import can restore a
  /// taste profile, and asking someone to rate titles they already rated on
  /// another device is the one thing worth avoiding here.
  SetupStep? _pendingTrailingStep() {
    if (_cloudPromptPending && !_steps.contains(SetupStep.cloudSync)) {
      return SetupStep.cloudSync;
    }
    if (_tastePromptPending && !_steps.contains(SetupStep.taste)) {
      return SetupStep.taste;
    }
    return null;
  }

  /// Appends the next trailing step, after the last default one. Returns true
  /// if it took over, so the caller advances instead of finishing.
  bool _appendTrailingStepIfPending() {
    final next = _pendingTrailingStep();
    if (next == null) return false;
    setState(() {
      _steps = [..._steps, next];
      _advancing = true;
      _index++;
    });
    _focusStepDefault();
    return true;
  }

  /// Stand down without marking anything done, so a later launch can try again.
  void _giveUpForNow() {
    _gate.deferThisLaunch();
    _goHome();
  }

  void _goHome() {
    if (_leaving || !mounted) return;
    _leaving = true;
    context.go(Destinations.home);
  }

  Future<void> _finish() async {
    final client = _client;
    final navbar = _navbar;

    // Applied BEFORE the answers below. An import restores a whole stored
    // profile, including the four things this wizard just asked about, so
    // writing the answers afterwards keeps the choices made seconds ago from
    // being silently undone by a profile saved months ago.
    final cloudChoice = _cloudChoice;
    final cloudUsername = _cloudUsername;
    if (cloudChoice != null &&
        cloudUsername != null &&
        GetIt.instance.isRegistered<UserSettingsSyncService>()) {
      try {
        await GetIt.instance<UserSettingsSyncService>()
            .applyCloudChoice(cloudChoice, cloudUsername);
      } catch (_) {
        // A failed import must not strand the user in the wizard.
      }
    }

    await _prefs.batchNotifications(() async {
      if (navbar != null) {
        await _prefs.set(UserPreferences.navbarPosition, navbar);
      }
      final mediaBar = _mediaBar;
      if (mediaBar != null) {
        await _prefs.set(UserPreferences.mediaBarMode, mediaBar);
      }
      final homeRows = _homeRows;
      if (homeRows != null) {
        await _prefs.set(UserPreferences.homeRowsStyle, homeRows);
      }
      final detailStyle = _detailStyle;
      if (detailStyle != null) {
        await _prefs.set(UserPreferences.detailScreenStyle, detailStyle);
      }
    });

    // The chrome listens on this rather than the preference, so Home comes up
    // with the bar where it was just asked to be.
    if (navbar != null) {
      NavigationLayout.positionNotifier.value =
          NavigationLayout.sanitizeNavbarPosition(navbar);
    }

    if (client != null) await _gate.markComplete(client);

    // Launched after the wizard has marked itself complete, so a taste run
    // that is abandoned part way cannot strand the user back in setup on the
    // next launch. The seen flag is written only once it has actually been
    // shown, for the same reason.
    if (_steps.contains(SetupStep.taste)) {
      if (_tasteChoice && mounted) {
        await TasteOnboardingWizard.showAsDialog(context);
      }
      await _prefs.set(UserPreferences.tasteOnboardingSeen, true);
    }

    _goHome();
  }

  /// Leaves without answering anything, and without being asked again.
  ///
  /// Skipping is an answer in its own right: it means stop asking. What it must
  /// not do is write the defaults, which would mark them as deliberate choices
  /// and stop any future device from asking either.
  Future<void> _skip() async {
    final client = _client;
    if (client != null) await _gate.markComplete(client);
    _goHome();
  }

  void _advance() {
    if (_index >= _steps.length - 1) {
      if (_appendTrailingStepIfPending()) return;
      unawaited(_finish());
      return;
    }
    // Costs nothing once artwork is in, and gives a slow server another
    // chance to fill the previews before the next step shows them.
    unawaited(SetupPreviewData.ensureLoaded());
    setState(() {
      _advancing = true;
      _index++;
    });
    _focusStepDefault();
  }

  void _goBack() {
    if (_index == 0) return;
    setState(() {
      _advancing = false;
      _index--;
    });
    _focusStepDefault();
  }

  /// BACK never leaves the wizard on the first press. It moves to Skip, so the
  /// way out is always something the user chose to press twice.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (!event.logicalKey.isBackKey) return KeyEventResult.ignored;
    if (_skipNode.hasFocus) {
      unawaited(_skip());
      return KeyEventResult.handled;
    }
    _skipNode.requestFocus();
    return KeyEventResult.handled;
  }

  double get _maxWidth {
    if (PlatformDetection.useLeanbackUi) return 1680;
    if (PlatformDetection.useMobileUi) return 460;
    return 1480;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_skipNode.hasFocus) {
          unawaited(_skip());
          return;
        }
        _skipNode.requestFocus();
      },
      child: Scaffold(
        backgroundColor: AppColorScheme.background,
        // Same animated gradient/particle backdrop as the Welcome/login
        // screen, so both first-run setup and "Run Setup Again" from
        // Settings feel like a continuation of that screen rather than a
        // flatter, unrelated one.
        body: WelcomeBackdrop(
          // Keeps the action row clear of the OS gesture bar on phones.
          child: SafeArea(
            child: FocusScope(
            node: _scopeNode,
            autofocus: true,
            // The route owns the whole screen, so the scope is the trap: there is
            // nothing outside it for focus to travel to, and traversal already
            // stops rather than wrapping at the ends of a row.
            child: Focus(
              onKeyEvent: _onKey,
              canRequestFocus: false,
              skipTraversal: true,
              child: FocusTraversalGroup(
                policy: OrderedTraversalPolicy(),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: _maxWidth),
                    child: _buildSurface(context),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildSurface(BuildContext context) {
    final isMobile = PlatformDetection.useMobileUi;
    final radius = AppRadius.circular(isMobile ? 22 : 28);

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? AppSpacing.spaceSm : AppSpacing.spaceXl,
        vertical: isMobile ? AppSpacing.spaceSm : AppSpacing.spaceXl,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                AppColorScheme.background.withValues(alpha: 0.97),
                AppColorScheme.surface.withValues(alpha: 0.96),
              ],
            ),
            borderRadius: radius,
            border: Border.fromBorderSide(
              ThemeRegistry.active.borders.chipBorder.copyWith(
                color: AppColorScheme.onSurface.withValues(alpha: 0.22),
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: AppColorScheme.scrim.withValues(alpha: 0.35),
                blurRadius: isMobile ? 24 : 40,
                spreadRadius: 1,
              ),
            ],
          ),
          padding: EdgeInsets.all(
            isMobile ? AppSpacing.spaceLg : AppSpacing.space2xl,
          ),
          child: _ready
              ? _buildStep(context)
              : const Center(child: CircularProgressIndicator()),
        ),
      ),
    );
  }

  Widget _buildStep(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final step = _steps[_index];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildTopBar(context, l10n),
        SizedBox(
          height: PlatformDetection.useMobileUi
              ? AppSpacing.spaceMd
              : AppSpacing.spaceXl,
        ),
        Text(
          _questionFor(step, l10n),
          style: TextStyle(
            color: AppColorScheme.onSurface,
            fontSize: PlatformDetection.useMobileUi
                ? AppTypography.fontSizeLg
                : AppTypography.fontSize2xl,
            fontWeight: FontWeight.w600,
            height: 1.2,
          ),
        ),
        const SizedBox(height: AppSpacing.spaceSm),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            switchInCurve: Curves.easeOutCubic,
            transitionBuilder: (child, animation) {
              final offset = Tween<Offset>(
                begin: Offset(_advancing ? 0.06 : -0.06, 0),
                end: Offset.zero,
              ).animate(animation);
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(position: offset, child: child),
              );
            },
            child: KeyedSubtree(
              key: ValueKey(step),
              child: Center(child: _buildStepBody(context, step, l10n)),
            ),
          ),
        ),
        _buildActions(context, l10n),
      ],
    );
  }

  Widget _buildTopBar(BuildContext context, AppLocalizations l10n) {
    return Row(
      children: [
        Row(
          spacing: AppSpacing.spaceSm,
          children: [
            for (var i = 0; i < _steps.length; i++)
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i == _index
                      ? AppColorScheme.onSurface
                      : AppColorScheme.onSurface.withValues(alpha: 0.24),
                ),
              ),
          ],
        ),
        const Spacer(),
        _SetupTextButton(
          label: l10n.setupSkip,
          focusNode: _skipNode,
          order: 90,
          onPressed: () => unawaited(_skip()),
        ),
      ],
    );
  }

  String _questionFor(SetupStep step, AppLocalizations l10n) => switch (step) {
    SetupStep.navbar => l10n.setupNavbarQuestion,
    SetupStep.mediaBar => l10n.setupMediaBarQuestion,
    SetupStep.homeRows => l10n.setupHomeRowsQuestion,
    SetupStep.detailStyle => l10n.setupDetailQuestion,
    SetupStep.tour => l10n.setupTourQuestion,
    SetupStep.cloudSync => 'We found saved settings in your Voltix cloud.',
    SetupStep.taste => 'Want recommendations picked for your taste?',
  };

  Widget _buildStepBody(
    BuildContext context,
    SetupStep step,
    AppLocalizations l10n,
  ) => switch (step) {
    SetupStep.navbar => _buildNavbarStep(l10n),
    SetupStep.mediaBar => _buildMediaBarStep(l10n),
    SetupStep.homeRows => _buildHomeRowsStep(l10n),
    SetupStep.detailStyle => _buildDetailStyleStep(l10n),
    SetupStep.tour => _SetupTourStep(
      prefs: _prefs,
      focusNode: _stepDefaultFocusNode,
    ),
    SetupStep.cloudSync => _buildCloudSyncStep(l10n),
    SetupStep.taste => _buildTasteStep(l10n),
  };

  Widget _buildNavbarStep(AppLocalizations l10n) {
    // The bottom bar is only offered where the app can actually draw one, so
    // this list is two entries on a TV or desktop and three on a phone.
    final positions = NavigationLayout.availableNavbarPositions;
    final labels = {
      NavbarPosition.top: l10n.topBar,
      NavbarPosition.left: l10n.leftSidebar,
      NavbarPosition.bottom: l10n.bottomBar,
    };
    final selected = NavigationLayout.sanitizeNavbarPosition(
      _navbar ?? _prefs.get(UserPreferences.navbarPosition),
    );

    return _OptionLayout(
      columns: positions.length,
      children: [
        for (var i = 0; i < positions.length; i++)
          _OptionCard(
            order: i,
            label: labels[positions[i]] ?? positions[i].name,
            selected: selected == positions[i],
            autofocus: selected == positions[i],
            focusNode: selected == positions[i] ? _stepDefaultFocusNode : null,
            preview: SetupPreview(child: navbarPreview(positions[i])),
            onPressed: () => setState(() => _navbar = positions[i]),
          ),
      ],
    );
  }

  Widget _buildMediaBarStep(AppLocalizations l10n) {
    const modes = [
      UserPreferences.mediaBarModeVoltix,
      UserPreferences.mediaBarModeMakd,
      UserPreferences.mediaBarModeBookshelf,
      UserPreferences.mediaBarModeGallery,
      UserPreferences.mediaBarModeBanner,
      UserPreferences.mediaBarModeAya,
      UserPreferences.mediaBarModeOff,
    ];
    final labels = {
      UserPreferences.mediaBarModeVoltix: l10n.mediaBarModeVoltix,
      UserPreferences.mediaBarModeMakd: l10n.mediaBarModeMakd,
      UserPreferences.mediaBarModeBookshelf: l10n.mediaBarModeBookshelf,
      UserPreferences.mediaBarModeGallery: l10n.mediaBarModeGallery,
      UserPreferences.mediaBarModeBanner: l10n.mediaBarModeBanner,
      UserPreferences.mediaBarModeAya: l10n.mediaBarModeAya,
      UserPreferences.mediaBarModeOff: l10n.mediaBarModeOff,
    };
    final selected = _mediaBar ?? _prefs.get(UserPreferences.mediaBarMode);

    return _OptionLayout(
      columns: 4,
      children: [
        for (var i = 0; i < modes.length; i++)
          _OptionCard(
            order: i,
            label: labels[modes[i]] ?? modes[i],
            selected: selected == modes[i],
            autofocus: selected == modes[i],
            focusNode: selected == modes[i] ? _stepDefaultFocusNode : null,
            preview: SetupPreview(child: mediaBarPreview(modes[i])),
            onPressed: () => setState(() => _mediaBar = modes[i]),
          ),
      ],
    );
  }

  Widget _buildHomeRowsStep(AppLocalizations l10n) {
    final selected = _homeRows ?? _prefs.get(UserPreferences.homeRowsStyle);
    return _OptionLayout(
      columns: 2,
      children: [
        _OptionCard(
          order: 0,
          label: l10n.setupStyleClassic,
          hint: l10n.setupRowsClassicHint,
          selected: selected == HomeRowsStyle.v1,
          autofocus: selected == HomeRowsStyle.v1,
          focusNode:
              selected == HomeRowsStyle.v1 ? _stepDefaultFocusNode : null,
          preview: SetupPreview(child: homeRowsPreview(modern: false)),
          onPressed: () => setState(() => _homeRows = HomeRowsStyle.v1),
        ),
        _OptionCard(
          order: 1,
          label: l10n.setupStyleModern,
          hint: l10n.setupRowsModernHint,
          selected: selected == HomeRowsStyle.v2,
          autofocus: selected == HomeRowsStyle.v2,
          focusNode:
              selected == HomeRowsStyle.v2 ? _stepDefaultFocusNode : null,
          preview: SetupPreview(child: homeRowsPreview(modern: true)),
          onPressed: () => setState(() => _homeRows = HomeRowsStyle.v2),
        ),
      ],
    );
  }

  Widget _buildDetailStyleStep(AppLocalizations l10n) {
    final selected =
        _detailStyle ?? _prefs.get(UserPreferences.detailScreenStyle);
    return _OptionLayout(
      columns: 2,
      children: [
        _OptionCard(
          order: 0,
          label: l10n.setupStyleClassic,
          hint: l10n.setupDetailClassicHint,
          selected: selected == DetailScreenStyle.classic,
          autofocus: selected == DetailScreenStyle.classic,
          focusNode: selected == DetailScreenStyle.classic
              ? _stepDefaultFocusNode
              : null,
          preview: SetupPreview(child: detailStylePreview(modern: false)),
          onPressed: () =>
              setState(() => _detailStyle = DetailScreenStyle.classic),
        ),
        _OptionCard(
          order: 1,
          label: l10n.setupStyleModern,
          hint: l10n.setupDetailModernHint,
          selected: selected == DetailScreenStyle.modern,
          autofocus: selected == DetailScreenStyle.modern,
          focusNode: selected == DetailScreenStyle.modern
              ? _stepDefaultFocusNode
              : null,
          preview: SetupPreview(child: detailStylePreview(modern: true)),
          onPressed: () =>
              setState(() => _detailStyle = DetailScreenStyle.modern),
        ),
      ],
    );
  }

  Widget _buildStepCardPreview({
    required IconData icon,
    required Color accentColor,
    required String tag,
    required String subtitle,
    String? badgeText,
    List<String> featurePills = const [],
  }) {
    final aspect = setupPreviewAspect();
    return AspectRatio(
      aspectRatio: aspect,
      child: SetupPreview(
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                accentColor.withValues(alpha: 0.14),
                AppColorScheme.surface,
                const Color(0xFF0B0E14),
              ],
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (badgeText != null && badgeText.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: accentColor.withValues(alpha: 0.35),
                      width: 0.8,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.person_rounded, size: 11, color: accentColor),
                      const SizedBox(width: 4),
                      Text(
                        badgeText,
                        style: TextStyle(
                          color: accentColor,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: accentColor.withValues(alpha: 0.15),
                  border: Border.all(
                    color: accentColor.withValues(alpha: 0.4),
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: accentColor.withValues(alpha: 0.25),
                      blurRadius: 14,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: Icon(icon, size: 22, color: accentColor),
              ),
              const SizedBox(height: 8),
              Text(
                tag,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (featurePills.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  alignment: WrapAlignment.center,
                  children: featurePills
                      .map((pill) => Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.06),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.1),
                                width: 0.5,
                              ),
                            ),
                            child: Text(
                              pill,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.7),
                                fontSize: 9,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ))
                      .toList(),
                ),
              ] else ...[
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 10,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCloudSyncStep(AppLocalizations l10n) {
    final selected = _cloudChoice;
    final account = _cloudUsername ?? '';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (account.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.spaceMd),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B).withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppColorScheme.accent.withValues(alpha: 0.35),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_done_rounded,
                      size: 15, color: AppColorScheme.accent),
                  const SizedBox(width: 8),
                  Text(
                    'Cloud backup ready for @$account',
                    style: TextStyle(
                      color: AppColorScheme.onSurface,
                      fontSize: AppTypography.fontSizeSm,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        _OptionLayout(
          columns: 3,
          children: [
            _OptionCard(
              order: 0,
              label: 'Import',
              preview: _buildStepCardPreview(
                icon: Icons.cloud_download_rounded,
                accentColor: AppColorScheme.accent,
                tag: 'Restore Backup',
                subtitle: 'Keep earlier answers',
                badgeText: account.isNotEmpty ? '@$account' : 'Voltix Cloud',
                featurePills: const ['Preferences', 'Layout', 'Sync'],
              ),
              hint: 'Restore the settings saved for @$account. '
                  'Your answers on the previous steps are kept.',
              selected: selected == CloudDataAction.importAll,
              autofocus: selected == null || selected == CloudDataAction.importAll,
              focusNode:
                  (selected == null || selected == CloudDataAction.importAll)
                      ? _stepDefaultFocusNode
                      : null,
              onPressed: () =>
                  setState(() => _cloudChoice = CloudDataAction.importAll),
            ),
            _OptionCard(
              order: 1,
              label: 'Start fresh',
              preview: _buildStepCardPreview(
                icon: Icons.auto_awesome_rounded,
                accentColor: const Color(0xFF10B981),
                tag: 'New Baseline',
                subtitle: 'Clean local setup',
                badgeText: 'Local Setup',
                featurePills: const ['Local Defaults', 'Cloud Untouched'],
              ),
              hint: 'Leave the cloud copy untouched and carry on with the '
                  'settings on this device.',
              selected: selected == CloudDataAction.skip,
              autofocus: selected == CloudDataAction.skip,
              focusNode:
                  selected == CloudDataAction.skip ? _stepDefaultFocusNode : null,
              onPressed: () => setState(() => _cloudChoice = CloudDataAction.skip),
            ),
            _OptionCard(
              order: 2,
              label: 'Delete cloud data',
              preview: _buildStepCardPreview(
                icon: Icons.delete_outline_rounded,
                accentColor: const Color(0xFFEF4444),
                tag: 'Clear Cloud Copy',
                subtitle: 'Permanent removal',
                badgeText: 'Danger Zone',
                featurePills: const ['Wipe Server Copy'],
              ),
              hint: 'Remove the saved copy from the cloud for good. This cannot '
                  'be undone.',
              selected: selected == CloudDataAction.delete,
              autofocus: selected == CloudDataAction.delete,
              focusNode: selected == CloudDataAction.delete
                  ? _stepDefaultFocusNode
                  : null,
              onPressed: () =>
                  setState(() => _cloudChoice = CloudDataAction.delete),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTasteStep(AppLocalizations l10n) {
    return _OptionLayout(
      columns: 2,
      children: [
        _OptionCard(
          order: 0,
          label: 'Personalise',
          preview: _buildStepCardPreview(
            icon: Icons.auto_awesome_motion_rounded,
            accentColor: AppColorScheme.accent,
            tag: 'Voltix Recommends',
            subtitle: 'Calibrate stream shelves',
            featurePills: const ['Movies', 'Series', 'Genres', 'Moods'],
          ),
          hint: 'Rate a few titles and genres so the home screen can suggest '
              'things worth watching. Takes a couple of minutes.',
          selected: _tasteChoice,
          autofocus: _tasteChoice,
          focusNode: _tasteChoice ? _stepDefaultFocusNode : null,
          onPressed: () => setState(() => _tasteChoice = true),
        ),
        _OptionCard(
          order: 1,
          label: 'Not now',
          preview: _buildStepCardPreview(
            icon: Icons.schedule_rounded,
            accentColor: AppColorScheme.onSurface.withValues(alpha: 0.7),
            tag: 'Skip for Now',
            subtitle: 'Set up anytime in Settings',
            featurePills: const ['Standard Home Rows'],
          ),
          hint: 'Skip for now. You can build a taste profile at any time from '
              'Settings.',
          selected: !_tasteChoice,
          autofocus: !_tasteChoice,
          focusNode: !_tasteChoice ? _stepDefaultFocusNode : null,
          onPressed: () => setState(() => _tasteChoice = false),
        ),
      ],
    );
  }

  Widget _buildActions(BuildContext context, AppLocalizations l10n) {
    final isLast =
        _index >= _steps.length - 1 && _pendingTrailingStep() == null;
    return Row(
      children: [
        if (_index > 0)
          _SetupTextButton(label: l10n.back, order: 91, onPressed: _goBack),
        const Spacer(),
        _SetupPrimaryButton(
          label: isLast ? l10n.done : l10n.next,
          order: 93,
          onPressed: _advance,
        ),
      ],
    );
  }
}

/// Lays the option cards out at the width the space allows, keeping them the
/// dominant thing on screen rather than thumbnails under a heading.
class _OptionLayout extends StatelessWidget {
  const _OptionLayout({required this.columns, required this.children});

  final int columns;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    // Phones get one sideways strip instead of a stack of rows. The cards are
    // sized so the next one peeks in from the edge, which is what tells the
    // user there is more to scroll, and the action row below never gets
    // pushed off the screen.
    if (PlatformDetection.useMobileUi) {
      return LayoutBuilder(
        builder: (context, constraints) {
          // Breathing room inside the strip, so a card's selection border and
          // its focus growth stay visible instead of clipping against the
          // scroll viewport at the top and at either end.
          const inset = AppSpacing.spaceMd;
          const labelAllowance = 84.0;
          final byWidth = (constraints.maxWidth - inset * 2) * 0.42;
          final byHeight =
              (constraints.maxHeight - inset * 2 - labelAllowance) *
              setupPreviewAspect();
          final width = (byWidth < byHeight ? byWidth : byHeight).clamp(
            120.0,
            220.0,
          );
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(inset),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0) const SizedBox(width: AppSpacing.spaceMd),
                  SizedBox(width: width, child: children[i]),
                ],
              ],
            ),
          );
        },
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final gaps = AppSpacing.spaceMd * (columns - 1);
        final width = ((constraints.maxWidth - gaps) / columns).clamp(
          120.0,
          420.0,
        );
        return SingleChildScrollView(
          child: Wrap(
            spacing: AppSpacing.spaceMd,
            runSpacing: AppSpacing.spaceMd,
            alignment: WrapAlignment.center,
            children: [
              for (final child in children)
                SizedBox(width: width, child: child),
            ],
          ),
        );
      },
    );
  }
}

/// Anything in the wizard a person can land on and press.
///
/// One place for it so the remote, the pointer and the keyboard all behave the
/// same wherever they are, and so focus looks like focus does everywhere else.
class _Focusable extends StatefulWidget {
  const _Focusable({
    required this.order,
    required this.onPressed,
    required this.builder,
    this.focusNode,
    this.autofocus = false,
  });

  final int order;
  final VoidCallback onPressed;
  final Widget Function(bool focused) builder;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<_Focusable> createState() => _FocusableState();
}

class _FocusableState extends State<_Focusable> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return FocusTraversalOrder(
      order: NumericFocusOrder(widget.order.toDouble()),
      child: Focus(
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        onFocusChange: (value) => setState(() => _focused = value),
        onKeyEvent: (node, event) {
          if (!isActivateKey(event)) return KeyEventResult.ignored;
          widget.onPressed();
          return KeyEventResult.handled;
        },
        child: GestureDetector(
          onTap: widget.onPressed,
          child: widget.builder(_focused),
        ),
      ),
    );
  }
}

/// One pickable layout, shown rather than described.
class _OptionCard extends StatelessWidget {
  const _OptionCard({
    required this.order,
    required this.label,
    required this.preview,
    required this.selected,
    required this.onPressed,
    this.hint,
    this.autofocus = false,
    this.focusNode,
  });

  final int order;
  final String label;
  final String? hint;
  final Widget preview;
  final bool selected;
  final bool autofocus;
  final FocusNode? focusNode;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final accent = AppColorScheme.onSurface;

    return _Focusable(
      order: order,
      autofocus: autofocus,
      focusNode: focusNode,
      onPressed: onPressed,
      builder: (focused) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: AppSpacing.spaceSm,
        children: [
          AnimatedScale(
            scale: focused ? 1.035 : 1,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              decoration: BoxDecoration(
                borderRadius: AppRadius.circular(10),
                border: Border.all(
                  color: focused
                      ? accent
                      : accent.withValues(alpha: selected ? 0.34 : 0.14),
                  width: focused ? 2 : 1,
                ),
                boxShadow: focused
                    ? [
                        BoxShadow(
                          color: accent.withValues(alpha: 0.34),
                          blurRadius: 22,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              child: ClipRRect(
                borderRadius: AppRadius.circular(10),
                child: preview,
              ),
            ),
          ),
          Row(
            spacing: AppSpacing.spaceXs,
            children: [
              if (selected)
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: accent,
                  ),
                ),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? accent : accent.withValues(alpha: 0.7),
                    fontSize: AppTypography.fontSizeSm,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
          if (hint != null)
            Text(
              hint!,
              style: TextStyle(
                color: accent.withValues(alpha: 0.55),
                fontSize: AppTypography.fontSizeXs,
                height: 1.3,
              ),
            ),
        ],
      ),
    );
  }
}

class _SetupTextButton extends StatelessWidget {
  const _SetupTextButton({
    required this.label,
    required this.order,
    required this.onPressed,
    this.focusNode,
  });

  final String label;
  final int order;
  final VoidCallback onPressed;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return _Focusable(
      order: order,
      focusNode: focusNode,
      onPressed: onPressed,
      builder: (focused) => Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.spaceSm,
          vertical: AppSpacing.spaceXs,
        ),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: focused ? AppColorScheme.onSurface : Colors.transparent,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: AppColorScheme.onSurface.withValues(
              alpha: focused ? 1 : 0.62,
            ),
            fontSize: AppTypography.fontSizeSm,
          ),
        ),
      ),
    );
  }
}

class _SetupPrimaryButton extends StatelessWidget {
  const _SetupPrimaryButton({
    required this.label,
    required this.order,
    required this.onPressed,
  });

  final String label;
  final int order;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return _Focusable(
      order: order,
      onPressed: onPressed,
      builder: (focused) => AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.spaceXl,
          vertical: AppSpacing.spaceSm,
        ),
        decoration: BoxDecoration(
          color: AppColorScheme.accent,
          borderRadius: AppRadius.circular(8),
          boxShadow: focused
              ? [
                  BoxShadow(
                    color: AppColorScheme.accent.withValues(alpha: 0.5),
                    blurRadius: 18,
                    spreadRadius: 1,
                  ),
                ]
              : null,
          border: Border.all(
            color: focused ? AppColorScheme.onSurface : Colors.transparent,
            width: 2,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: AppColorScheme.onAccent,
            fontSize: AppTypography.fontSizeSm,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// The closing screen: pick a look, then a list of what else lives in
/// Settings. Only the theme writes anything.
class _SetupTourStep extends StatefulWidget {
  const _SetupTourStep({required this.prefs, this.focusNode});

  final UserPreferences prefs;
  final FocusNode? focusNode;

  @override
  State<_SetupTourStep> createState() => _SetupTourStepState();
}

class _SetupTourStepState extends State<_SetupTourStep> {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final active = widget.prefs.get(UserPreferences.visualTheme);

    // Glass is registered in ThemeRegistry now, so every built-in theme
    // Settings > Appearance can show is offered here too -- no exclusion.
    final availableThemes = VisualThemeId.values.toList();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: AppSpacing.spaceLg,
        children: [
          Text(
            l10n.setupPickALook,
            style: TextStyle(
              color: AppColorScheme.onSurface.withValues(alpha: 0.62),
              fontSize: AppTypography.fontSizeSm,
            ),
          ),
          Wrap(
            spacing: AppSpacing.spaceMd,
            runSpacing: AppSpacing.spaceMd,
            children: [
              for (var i = 0; i < availableThemes.length; i++)
                _ThemeSwatch(
                  order: i,
                  theme: availableThemes[i],
                  selected: active == availableThemes[i],
                  autofocus: active == availableThemes[i],
                  focusNode: active == availableThemes[i]
                      ? widget.focusNode
                      : null,
                  // Written straight away rather than held back with the
                  // rest, because the point is that the wizard restyles
                  // around you as you move across the row.
                  //
                  // Must go through AppThemeController, not a bare prefs.set:
                  // writing the preference alone never calls
                  // ThemeRegistry.setActiveById or notifies the controller
                  // the rest of the app listens to, so the swatch would show
                  // as selected while the actual theme around it never
                  // changed. applyThemeById also clears any leftover
                  // customThemeId from a synced/plugin theme, which would
                  // otherwise keep overriding this choice.
                  onPressed: () async {
                    await AppThemeScope.of(context)
                        .applyThemeSelection(widget.prefs, availableThemes[i]);
                    if (mounted) setState(() {});
                  },
                ),
            ],
          ),
          Container(
            padding: const EdgeInsets.all(AppSpacing.spaceMd),
            decoration: BoxDecoration(
              color: AppColorScheme.onSurface.withValues(alpha: 0.04),
              borderRadius: AppRadius.circular(12),
              border: Border.all(
                color: AppColorScheme.onSurface.withValues(alpha: 0.14),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: AppSpacing.spaceXs,
              children: [
                Row(
                  spacing: AppSpacing.spaceSm,
                  children: [
                    Icon(
                      Icons.settings_rounded,
                      size: 18,
                      color: AppColorScheme.onSurface,
                    ),
                    Text(
                      l10n.setupTourMoreHeader,
                      style: TextStyle(
                        color: AppColorScheme.onSurface,
                        fontSize: AppTypography.fontSizeSm,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                for (final entry in [
                  l10n.setupTourBulletRequests,
                  l10n.setupTourBulletSyncPlay,
                  l10n.liveTv,
                  l10n.setupTourBulletThemes,
                  if (!PlatformDetection.useLeanbackUi)
                    l10n.setupTourBulletDownloads,
                  l10n.setupTourBulletMore,
                ])
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: AppSpacing.spaceSm,
                    children: [
                      Text(
                        '\u2022',
                        style: TextStyle(
                          color: AppColorScheme.onSurface.withValues(
                            alpha: 0.65,
                          ),
                          fontSize: AppTypography.fontSizeXs,
                          height: 1.4,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          entry,
                          style: TextStyle(
                            color: AppColorScheme.onSurface.withValues(
                              alpha: 0.65,
                            ),
                            fontSize: AppTypography.fontSizeXs,
                            height: 1.4,
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
}

class _ThemeSwatch extends StatelessWidget {
  const _ThemeSwatch({
    required this.order,
    required this.theme,
    required this.selected,
    required this.autofocus,
    required this.onPressed,
    this.focusNode,
  });

  final int order;
  final VisualThemeId theme;
  final bool selected;
  final bool autofocus;
  final FocusNode? focusNode;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final label = switch (theme) {
      VisualThemeId.voltix => l10n.themeVoltix,
      VisualThemeId.neonPulse => l10n.themeNeonPulse,
      VisualThemeId.glass => l10n.themeGlass,
      VisualThemeId.eightbitHero => l10n.theme8BitHero,
    };
    final spec = ThemeRegistry.resolveById(
      AppThemeController.builtInThemeIdFor(theme),
    );

    return _Focusable(
      order: order,
      autofocus: autofocus,
      focusNode: focusNode,
      onPressed: onPressed,
      builder: (focused) => Column(
        spacing: AppSpacing.spaceXs,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 72,
            height: 44,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [spec.colors.surface, spec.colors.background],
              ),
              borderRadius: AppRadius.circular(8),
              border: Border.all(
                color: focused
                    ? AppColorScheme.onSurface
                    : AppColorScheme.onSurface.withValues(
                        alpha: selected ? 0.4 : 0.16,
                      ),
                width: focused ? 2 : 1,
              ),
              boxShadow: focused
                  ? [
                      BoxShadow(
                        color: AppColorScheme.onSurface.withValues(alpha: 0.3),
                        blurRadius: 18,
                      ),
                    ]
                  : null,
            ),
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 4,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: spec.colors.accent,
                    ),
                  ),
                  Container(
                    width: 22,
                    height: 4,
                    decoration: BoxDecoration(
                      color: spec.colors.onSurface.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Text(
            label,
            style: TextStyle(
              color: AppColorScheme.onSurface.withValues(
                alpha: selected ? 1 : 0.62,
              ),
              fontSize: AppTypography.fontSizeXs,
            ),
          ),
        ],
      ),
    );
  }
}
