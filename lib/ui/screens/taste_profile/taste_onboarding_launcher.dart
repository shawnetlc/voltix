import '../../../auth/store/voltix_session_store.dart';
import 'package:flutter/widgets.dart';
import 'package:get_it/get_it.dart';
import 'package:logger/logger.dart';
import 'package:server_core/server_core.dart';

import '../../../data/repositories/taste_profile_repository.dart';
import '../../../preference/user_preferences.dart';
import 'taste_onboarding_wizard.dart';

/// Decides whether to run the taste onboarding wizard, and runs it.
///
/// ─── Why this is a shared function ───────────────────────────────────────────
///
/// This logic used to live inline in one place: the post-login path in
/// [VoltixLoginScreen]. Registration did not have it — `_configureJellyfinServer`
/// finished and went straight to the home screen.
///
/// That looked like a platform difference, and it was reported as one: taste
/// recommendations started on TV and not on mobile. It is not. A television
/// cannot realistically be used to sign up — no keyboard worth typing a card
/// into — so every TV user arrives through sign-in and gets the wizard. A new
/// mobile user registers in the app, which is the path that never had it. Same
/// build, same code, different door.
///
/// Anything that lands a user on the home screen for the first time should call
/// this, which is why it is a function rather than another copy of the block.
final _logger = Logger();

/// How long to wait for a previously completed profile to come back from the
/// cloud before deciding this user has never onboarded.
const _restoreTimeout = Duration(seconds: 6);

/// Shows the taste onboarding wizard if this user has not completed it.
///
/// Safe to call from any post-authentication path, and safe to call more than
/// once — it is a no-op after the wizard has actually been shown.
///
/// Returns true if the wizard was displayed.
Future<bool> maybeShowTasteOnboarding(BuildContext context) async {
  if (GetIt.instance.isRegistered<VoltixSessionStore>() &&
      GetIt.instance<VoltixSessionStore>().isKidsProfile) {
    _logger.i('[TasteOnboarding] Kids profile active; skipping taste onboarding.');
    return false;
  }

  final userPrefs = GetIt.instance<UserPreferences>();
  var hasSeenWizard = userPrefs.get(UserPreferences.tasteOnboardingSeen);
  if (hasSeenWizard) return false;

  // The wizard reaches for MediaServerClient and TasteProfileRepository in its
  // field initializers, so constructing it without them throws.
  //
  // This matters on the registration path specifically: a Voltix account with
  // no Jellyfin entitlement never adds a server, so there is no client to build
  // recommendations from. Skip, and deliberately do NOT mark the wizard as seen
  // — the one-shot flag should be spent on a wizard that actually ran, so this
  // user still gets asked once they have a library.
  if (!GetIt.instance.isRegistered<TasteProfileRepository>() ||
      !GetIt.instance.isRegistered<MediaServerClient>()) {
    _logger.i('[TasteOnboarding] No media server yet; deferring the wizard.');
    return false;
  }

  final client = GetIt.instance<MediaServerClient>();
  final userId = client.userId?.trim() ?? '';
  if (userId.isEmpty) {
    _logger.i('[TasteOnboarding] No user id yet; deferring the wizard.');
    return false;
  }

  // Give a profile the user already completed a chance to come back — from
  // Jellyfin's roaming DisplayPreferences, or from the Azure backup written the
  // last time they finished onboarding on any device. Without this, a fresh
  // install or a second device re-runs the wizard even though the answers are
  // already in the cloud, because nothing ever asked.
  try {
    final activeProfileId = GetIt.instance.isRegistered<VoltixSessionStore>()
        ? GetIt.instance<VoltixSessionStore>().activeProfileId
        : null;
    final restored = await GetIt.instance<TasteProfileRepository>()
        .loadProfile(
          userId: userId,
          serverId: client.baseUrl,
          profileId: activeProfileId,
        )
        .timeout(_restoreTimeout);
    if (restored.isCompleted) {
      await userPrefs.set(UserPreferences.tasteOnboardingSeen, true);
      return false;
    }
  } catch (e) {
    // A restore failure must not block the way in. Worst case the wizard asks
    // again, which the user can skip; getting stuck here is not recoverable.
    _logger.w('[TasteOnboarding] Profile restore failed: $e');
  }

  if (!context.mounted) return false;

  await TasteOnboardingWizard.showAsDialog(context);

  // Marked only once it has actually been shown. Setting it beforehand spends
  // the single shot even when the wizard never managed to load, which is how a
  // taste profile could be lost for good after one bad launch.
  await userPrefs.set(UserPreferences.tasteOnboardingSeen, true);
  return true;
}

/// Prompts the active user with the taste wizard when they have no completed
/// taste profile. Called from the home screen on every platform (mobile, TV,
/// desktop), so it covers the paths [maybeShowTasteOnboarding] never sees:
/// auto-login straight to home, switching to a profile that was never set up,
/// and users who skipped the wizard earlier ("remind me").
///
/// Unlike [maybeShowTasteOnboarding] this does not stop at the one-shot
/// `tasteOnboardingSeen` flag, because that flag is app-wide and is spent the
/// first time any profile sees the wizard. It asks at most once per app run
/// per user/profile, so skipping never nags within a session.
///
/// Returns true if the wizard was displayed.
Future<bool> maybePromptMissingTasteProfile(BuildContext context) async {
  final getIt = GetIt.instance;
  if (getIt.isRegistered<VoltixSessionStore>() &&
      getIt<VoltixSessionStore>().isKidsProfile) {
    return false;
  }
  if (!getIt.isRegistered<TasteProfileRepository>() ||
      !getIt.isRegistered<MediaServerClient>()) {
    return false;
  }
  if (TasteOnboardingWizard.wasShownThisSession()) return false;

  final client = getIt<MediaServerClient>();
  final userId = client.userId?.trim() ?? '';
  if (userId.isEmpty) return false;

  final repo = getIt<TasteProfileRepository>();
  final current = repo.currentProfile;
  if (current != null &&
      current.userId == userId &&
      current.isCompleted) {
    return false;
  }

  try {
    final activeProfileId = getIt.isRegistered<VoltixSessionStore>()
        ? getIt<VoltixSessionStore>().activeProfileId
        : null;
    final restored = await repo
        .loadProfile(
          userId: userId,
          serverId: client.baseUrl,
          profileId: activeProfileId,
        )
        .timeout(_restoreTimeout);
    if (restored.isCompleted) return false;
  } catch (e) {
    // Could not confirm either way (offline, slow server). Do not interrupt
    // the user on a guess; the next launch will check again.
    _logger.w('[TasteOnboarding] Missing-profile check failed: $e');
    return false;
  }

  if (!context.mounted || TasteOnboardingWizard.wasShownThisSession()) {
    return false;
  }
  _logger.i('[TasteOnboarding] No completed taste profile; prompting wizard.');
  await TasteOnboardingWizard.showAsDialog(context);
  return true;
}
