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
    final restored = await GetIt.instance<TasteProfileRepository>()
        .loadProfile(userId: userId, serverId: client.baseUrl)
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
