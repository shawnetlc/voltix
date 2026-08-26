import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:voltix_design/voltix_design.dart';
import 'package:custom_tv_text_field/custom_tv_text_field.dart';
import 'package:logger/logger.dart';
import 'package:server_core/server_core.dart';

import '../../../auth/repositories/server_repository.dart';
import '../../../auth/repositories/session_repository.dart';
import '../../../auth/store/voltix_session_store.dart';
import '../../../data/services/device_id_service.dart';
import '../../../data/services/voltix_api_service.dart';
import '../../../data/services/voltix_session_service.dart';
import '../../../preference/user_preferences.dart';
import '../../../util/platform_detection.dart';
import '../../navigation/destinations.dart';
import '../../widgets/login_scaffold.dart';
import 'payfast_checkout_screen.dart';

/// Package option model for Voltix subscriptions.
class VoltixSubscriptionPackage {
  final String id;
  final String title;
  final String durationLabel;
  final double price;
  final String pricePerMonthLabel;
  final String? badgeText;
  final int maxDevices;
  final bool isPass;
  final List<String> features;

  const VoltixSubscriptionPackage({
    required this.id,
    required this.title,
    required this.durationLabel,
    required this.price,
    required this.pricePerMonthLabel,
    this.badgeText,
    required this.maxDevices,
    this.isPass = false,
    required this.features,
  });
}

const List<VoltixSubscriptionPackage> kVoltixPackages = [
  VoltixSubscriptionPackage(
    id: 'bundle_deal',
    title: 'Bundle Deal - Library + Live TV',
    durationLabel: 'Billed monthly',
    price: 250.00,
    pricePerMonthLabel: 'R250 / mo',
    badgeText: 'BEST VALUE',
    maxDevices: 1,
    isPass: false,
    features: [
      '1 Concurrent Stream',
      'Access to Media Library & Live TV (4K)',
      'All media stats and EPG guides included',
      'Includes movies & series on Live TV module',
      'Priority server connection & support',
    ],
  ),
  VoltixSubscriptionPackage(
    id: 'media_library',
    title: 'Media Library',
    durationLabel: 'Billed monthly',
    price: 200.00,
    pricePerMonthLabel: 'R200 / mo',
    maxDevices: 1,
    isPass: false,
    features: [
      '1 Concurrent Stream',
      'Stunning 4K & HD Quality',
      'Full server access (39,000+ Movies, 19,800+ Series)',
      'Ad-Free Premium experience',
      'Personal watch history logs',
    ],
  ),
  VoltixSubscriptionPackage(
    id: 'live_tv_hd',
    title: 'Live TV - HD',
    durationLabel: 'Billed monthly',
    price: 170.00,
    pricePerMonthLabel: 'R170 / mo',
    maxDevices: 1,
    isPass: false,
    features: [
      '1 Concurrent Stream',
      'DSTV & all sports channels in HD',
      'Live HD streaming platform with EPG guide',
      'Includes movies & series on Live TV module',
      'Low bandwidth streaming optimization',
    ],
  ),
  VoltixSubscriptionPackage(
    id: 'live_tv_4k',
    title: 'Live TV - 4K',
    durationLabel: 'Billed monthly',
    price: 200.00,
    pricePerMonthLabel: 'R200 / mo',
    maxDevices: 1,
    isPass: false,
    features: [
      '1 Concurrent Stream',
      'DSTV & all sports channels in 4K',
      'High quality faster streaming connection',
      'Includes movies & series on Live TV module',
      'Ultra-low buffering playback',
    ],
  ),
  VoltixSubscriptionPackage(
    id: 'sport_7_days_4k',
    title: 'Sport - 7 days (4K)',
    durationLabel: '7-day once-off pass',
    price: 50.00,
    pricePerMonthLabel: 'R50 once-off',
    badgeText: 'POPULAR',
    maxDevices: 1,
    isPass: true,
    features: [
      '7 days unlimited sport streaming',
      'All sport channels in ultra 4K',
      'All SuperSport channels at 4K',
      'Faster streaming and high definition',
      'One-off pass (no auto-renewal)',
    ],
  ),
  VoltixSubscriptionPackage(
    id: 'sport_7_days_hd',
    title: 'Sport HD - 7 days',
    durationLabel: '7-day once-off pass',
    price: 40.00,
    pricePerMonthLabel: 'R40 once-off',
    maxDevices: 1,
    isPass: true,
    features: [
      '7 days unlimited sport streaming',
      'All sport channels in standard HD',
      'Watch on any supported device',
      'Full access to live match EPG',
      'One-off pass (no auto-renewal)',
    ],
  ),
  VoltixSubscriptionPackage(
    id: 'sport_match_1_day',
    title: 'Sport for the match - 1 day',
    durationLabel: '24-hour once-off pass',
    price: 30.00,
    pricePerMonthLabel: 'R30 once-off',
    maxDevices: 1,
    isPass: true,
    features: [
      '24 hours unlimited sport streaming',
      'All sport channels including SuperSport in 4K',
      'Perfect for the match you are not home to watch',
      'High quality faster streaming',
      'One-off pass (no auto-renewal)',
    ],
  ),
];

/// Native Registration Wizard Screen matching the Voltix web registration experience.
/// Supports 24h Free Trial or Paid Subscriptions with Package selection & In-App Payment processing.
class VoltixRegisterScreen extends StatefulWidget {
  final VoidCallback? onBackToLogin;

  const VoltixRegisterScreen({
    super.key,
    this.onBackToLogin,
  });

  @override
  State<VoltixRegisterScreen> createState() => _VoltixRegisterScreenState();
}

class _VoltixRegisterScreenState extends State<VoltixRegisterScreen> {
  final _logger = Logger();

  // Step state: 0 = Plan Selection, 1 = User Info, 2 = Package & Payment, 3 = Complete
  int _currentStep = 0;
  bool _isTrial = true; // true = 24h trial, false = paid subscription

  // Account Form
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  String _selectedCategory = 'bundle'; // 'bundle', 'livetv', 'library'
  String _liveTvSubCategory = 'monthly'; // 'monthly' vs 'pass'
  VoltixSubscriptionPackage _selectedPackage = kVoltixPackages.first; // Default to Bundle Deal
  String _billingMode = 'recurring'; // 'recurring' (Monthly Auto-Renewing) vs 'once_off' (Once-off Month)
  String _paymentMethod = 'payfast'; // 'payfast' vs 'eft'
  bool _isPendingPayment = false;

  // Focus Nodes for TV & Keyboard navigation
  final _trialOptionFocus = FocusNode(debugLabel: 'TrialOptionFocus');
  final _subOptionFocus = FocusNode(debugLabel: 'SubOptionFocus');
  final _planNextFocus = FocusNode(debugLabel: 'PlanNextFocus');

  final _usernameFocus = FocusNode(debugLabel: 'RegUsernameFocus');
  final _emailFocus = FocusNode(debugLabel: 'RegEmailFocus');
  final _passwordFocus = FocusNode(debugLabel: 'RegPasswordFocus');
  final _confirmPasswordFocus = FocusNode(debugLabel: 'RegConfirmPasswordFocus');
  final _infoNextFocus = FocusNode(debugLabel: 'RegInfoNextFocus');
  final _infoBackFocus = FocusNode(debugLabel: 'RegInfoBackFocus');

  final _paySubmitFocus = FocusNode(debugLabel: 'PaySubmitFocus');
  final _payBackFocus = FocusNode(debugLabel: 'PayBackFocus');

  final _usernameTvFieldKey = GlobalKey<CustomTVTextFieldState>();
  final _emailTvFieldKey = GlobalKey<CustomTVTextFieldState>();
  final _passwordTvFieldKey = GlobalKey<CustomTVTextFieldState>();
  final _confirmPasswordTvFieldKey = GlobalKey<CustomTVTextFieldState>();

  bool _isLoading = false;
  String? _errorMessage;
  String _deviceMac = '...';

  @override
  void initState() {
    super.initState();
    _loadDeviceMac();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _trialOptionFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();

    _trialOptionFocus.dispose();
    _subOptionFocus.dispose();
    _planNextFocus.dispose();

    _usernameFocus.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    _confirmPasswordFocus.dispose();
    _infoNextFocus.dispose();
    _infoBackFocus.dispose();

    _paySubmitFocus.dispose();
    _payBackFocus.dispose();
    super.dispose();
  }

  Future<void> _loadDeviceMac() async {
    final deviceIdService = GetIt.instance<DeviceIdService>();
    final mac = await deviceIdService.getDeviceMac();
    if (mounted) setState(() => _deviceMac = mac);
  }

  void _handleBack() {
    if (_currentStep > 0) {
      setState(() {
        _currentStep--;
        _errorMessage = null;
      });
      return;
    }
    if (widget.onBackToLogin != null) {
      widget.onBackToLogin!();
    } else {
      context.popOrHome();
    }
  }

  void _goToStep(int step) {
    setState(() {
      _currentStep = step;
      _errorMessage = null;
    });
  }

  void _validateStep1AndProceed() {
    setState(() => _errorMessage = null);
    _goToStep(1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _usernameFocus.requestFocus();
    });
  }

  void _validateStep2AndProceed() {
    final username = _usernameController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final confirmPassword = _confirmPasswordController.text;

    if (username.isEmpty) {
      setState(() => _errorMessage = 'Please enter a username');
      return;
    }
    if (username.length < 3) {
      setState(() => _errorMessage = 'Username must be at least 3 characters');
      return;
    }
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _errorMessage = 'Please enter a valid email address');
      return;
    }
    if (password.isEmpty || password.length < 6) {
      setState(() => _errorMessage = 'Password must be at least 6 characters');
      return;
    }
    if (password != confirmPassword) {
      setState(() => _errorMessage = 'Passwords do not match');
      return;
    }

    setState(() => _errorMessage = null);

    if (_isTrial) {
      // 24h trial skips payment step & submits immediately
      _submitRegistration();
    } else {
      // Paid subscription proceeds to package & payment step
      _goToStep(2);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _paySubmitFocus.requestFocus();
      });
    }
  }

  Future<void> _handleSubscribe() async {
    if (!_isTrial && _paymentMethod == 'payfast') {
      final checkoutUrl = 'https://www.voltixstudio.com/subscribe?package=${_selectedPackage.id}&billing=$_billingMode&username=${_usernameController.text}';
      final result = await Navigator.push<bool>(context, MaterialPageRoute(
        builder: (_) => PayFastCheckoutScreen(
          checkoutUrl: checkoutUrl,
          packageName: _selectedPackage.title,
          amount: 'R${_selectedPackage.price}',
        ),
      ));
      if (result == true) {
        _submitRegistration(); // Only submit if payment succeeded
      }
    } else {
      _submitRegistration();
    }
  }

  Future<void> _submitRegistration() async {
    final username = _usernameController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final voltixApi = GetIt.instance<VoltixApiService>();
      final deviceInfo = GetIt.instance<DeviceInfo>();
      final deviceType = PlatformDetection.isTV
          ? 'tv'
          : (PlatformDetection.isAndroid || PlatformDetection.isIOS)
              ? 'mobile'
              : 'desktop';

      final result = await voltixApi.registerAccount(
        username: username,
        email: email,
        password: password,
        isTrial: _isTrial,
        packageId: _isTrial ? 'trial_24h' : _selectedPackage.id,
        packageName: _isTrial ? '24-Hour Free Trial' : _selectedPackage.title,
        packagePrice: _isTrial ? 0.0 : _selectedPackage.price,
        paymentMethod: _isTrial ? 'free_trial' : _paymentMethod,
        paymentDetails: {},
        deviceName: deviceInfo.name,
        deviceType: deviceType,
        macAddress: _deviceMac != '...' ? _deviceMac : null,
      );

      if (!mounted) return;

      // Save Voltix Session
      final sessionStore = GetIt.instance<VoltixSessionStore>();
      await sessionStore.save(
        sessionToken: result.sessionToken,
        userId: result.user.id,
        username: result.user.username,
        displayName: result.user.displayName,
        activeServerId: result.activeServer.id,
        activeServerName: result.activeServer.name,
        activeServerProxyUrl: result.activeServer.proxyUrl,
      );

      // Auto-configure Jellyfin Lumistream server session
      await _configureJellyfinServer(result);
    } catch (e) {
      _logger.e('[VoltixRegister] Registration error: $e');
      if (!mounted) return;

      final rawErr = e.toString().replaceAll('VoltixApiException: ', '');
      if (!_isTrial && (rawErr.toLowerCase().contains('inactive') || rawErr.toLowerCase().contains('subscription'))) {
        // Account registered successfully, pending payment activation
        setState(() {
          _isLoading = false;
          _isPendingPayment = true;
          _currentStep = 3;
        });
        return;
      }

      setState(() {
        _isLoading = false;
        _errorMessage = rawErr;
      });
    }
  }

  Future<void> _configureJellyfinServer(VoltixLoginResult result) async {
    try {
      final serverRepo = GetIt.instance<ServerRepository>();
      final sessionRepo = GetIt.instance<SessionRepository>();
      final userPrefs = GetIt.instance<UserPreferences>();

      sessionRepo.setVoltixOnlySession(
        serverId: result.activeServer.id.toString(),
        userId: result.user.id.toString(),
        username: result.user.username,
      );
      await userPrefs.set(UserPreferences.voltixJellyfinEnabled, result.jellyfinReady);
      await userPrefs.set(UserPreferences.voltixLiveTvEnabled, result.iptvReady);

      if (result.jellyfinReady && result.servers.isNotEmpty) {
        final voltixApi = GetIt.instance<VoltixApiService>();
        for (final vServer in result.servers) {
          try {
            final serverUrl = vServer.absoluteProxyUrl(voltixApi.baseUrl);
            await serverRepo.addServer(serverUrl);
          } catch (_) {}
        }
      }

      if (!mounted) return;

      setState(() {
        _isLoading = false;
        _currentStep = 3; // Registration Success step
      });

      GetIt.instance<VoltixSessionService>().start();

      // Brief delay to show the celebratory success checkmark, then go home.
      await Future.delayed(const Duration(milliseconds: 1200));
      if (mounted) {
        context.go(Destinations.home);
      }
    } catch (e) {
      _logger.e('[VoltixRegister] Jellyfin setup error: $e');
      if (mounted) {
        context.go(Destinations.home);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return LoginScaffold(
      maxWidth: _currentStep == 2 ? 820 : 560,
      header: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: _handleBack,
                tooltip: 'Back',
              ),
              Image.asset('assets/images/logo_and_text.png', height: 44),
              const SizedBox(width: 48), // Spacer to center logo
            ],
          ),
          const SizedBox(height: 12),
          _buildStepProgressIndicator(),
        ],
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: _buildCurrentStepWidget(),
      ),
    );
  }

  Widget _buildStepProgressIndicator() {
    final steps = ['Plan', 'Account', if (!_isTrial) 'Payment', 'Complete'];
    final activeIndex = _currentStep;

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(steps.length, (index) {
        final isActive = index == activeIndex;
        final isPassed = index < activeIndex;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isActive
                      ? AppColorScheme.accent
                      : isPassed
                          ? Colors.greenAccent
                          : Colors.white10,
                  border: Border.all(
                    color: isActive ? Colors.white : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: Center(
                  child: isPassed
                      ? const Icon(Icons.check, size: 14, color: Colors.black)
                      : Text(
                          '${index + 1}',
                          style: TextStyle(
                            color: isActive ? Colors.black : Colors.white70,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                steps[index],
                style: TextStyle(
                  color: isActive
                      ? Colors.white
                      : isPassed
                          ? Colors.white70
                          : Colors.white38,
                  fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                  fontSize: 13,
                ),
              ),
              if (index < steps.length - 1)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  width: 20,
                  height: 2,
                  color: isPassed ? Colors.greenAccent : Colors.white12,
                ),
            ],
          ),
        );
      }),
    );
  }

  Widget _buildCurrentStepWidget() {
    switch (_currentStep) {
      case 0:
        return _buildStep1PlanSelection();
      case 1:
        return _buildStep2AccountDetails();
      case 2:
        return _buildStep3PaymentOptions();
      case 3:
      default:
        return _buildStep4Success();
    }
  }

  // ──────────────── STEP 1: PLAN SELECTION ────────────────

  Widget _buildStep1PlanSelection() {
    return Column(
      key: const ValueKey(1),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Choose Your Access Type',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Get started with a 24-hour trial or unlock full premium access.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 14),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: _buildPlanCard(
                focusNode: _trialOptionFocus,
                title: '24h Free Trial',
                subtitle: '100% Free Access',
                price: 'R0.00',
                badgeText: 'FREE',
                badgeColor: Colors.tealAccent.shade400,
                icon: Icons.bolt_outlined,
                isSelected: _isTrial,
                features: [
                  'Full 24-Hour Pass',
                  'No Credit Card Required',
                  '50,000+ Movies & Series',
                  'Live TV Channels with EPG',
                ],
                onTap: () => setState(() => _isTrial = true),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _buildPlanCard(
                focusNode: _subOptionFocus,
                title: 'Paid Subscription',
                subtitle: 'Full Premium Access',
                price: 'From R170/mo',
                badgeText: 'POPULAR',
                badgeColor: AppColorScheme.accent,
                icon: Icons.workspace_premium,
                isSelected: !_isTrial,
                features: [
                  'Unlimited Long-Term Pass',
                  'Up to 5 Devices (Multi-Room)',
                  '4K HDR + Dolby Vision',
                  'Priority Server Routing',
                ],
                onTap: () => setState(() => _isTrial = false),
              ),
            ),
          ],
        ),
        const SizedBox(height: 28),
        ElevatedButton(
          focusNode: _planNextFocus,
          onPressed: _validateStep1AndProceed,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColorScheme.accent,
            foregroundColor: Colors.black,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _isTrial ? 'Continue with 24h Free Trial' : 'Select Subscription Package',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.arrow_forward, size: 20),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPlanCard({
    required FocusNode focusNode,
    required String title,
    required String subtitle,
    required String price,
    required String badgeText,
    required Color badgeColor,
    required IconData icon,
    required bool isSelected,
    required List<String> features,
    required VoidCallback onTap,
  }) {
    return Focus(
      focusNode: focusNode,
      child: ListenableBuilder(
        listenable: focusNode,
        builder: (context, _) {
          final isFocused = focusNode.hasFocus;

          return GestureDetector(
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isSelected
                    ? AppColorScheme.accent.withValues(alpha: 0.15)
                    : const Color(0xFF141A26),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isFocused
                      ? Colors.white
                      : isSelected
                          ? AppColorScheme.accent
                          : Colors.white12,
                  width: isFocused || isSelected ? 2.5 : 1,
                ),
                boxShadow: isFocused
                    ? [
                        BoxShadow(
                          color: AppColorScheme.accent.withValues(alpha: 0.4),
                          blurRadius: 16,
                          spreadRadius: 2,
                        )
                      ]
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Icon(icon, color: isSelected ? AppColorScheme.accent : Colors.white70, size: 28),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: badgeColor,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          badgeText,
                          style: const TextStyle(
                            color: Colors.black,
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    price,
                    style: TextStyle(
                      color: AppColorScheme.accent,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const Divider(color: Colors.white10, height: 20),
                  ...features.map(
                    (f) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          Icon(Icons.check_circle_outline, size: 14, color: isSelected ? AppColorScheme.accent : Colors.white54),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              f,
                              style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 11),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ──────────────── STEP 2: ACCOUNT DETAILS ────────────────

  Widget _buildStep2AccountDetails() {
    return Column(
      key: const ValueKey(2),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _isTrial ? 'Create Your Free 24h Account' : 'Create Your Voltix Account',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Enter your credentials to set up your account.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13),
        ),
        const SizedBox(height: 20),
        if (_errorMessage != null)
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.redAccent.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.redAccent),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.redAccent, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        _buildInputField(
          controller: _usernameController,
          focusNode: _usernameFocus,
          tvFieldKey: _usernameTvFieldKey,
          label: 'Username',
          hint: 'Choose a username',
          icon: Icons.person_outline,
        ),
        const SizedBox(height: 12),
        _buildInputField(
          controller: _emailController,
          focusNode: _emailFocus,
          tvFieldKey: _emailTvFieldKey,
          label: 'Email Address',
          hint: 'yourname@example.com',
          icon: Icons.email_outlined,
          keyboardType: TextInputType.emailAddress,
        ),
        const SizedBox(height: 12),
        _buildInputField(
          controller: _passwordController,
          focusNode: _passwordFocus,
          tvFieldKey: _passwordTvFieldKey,
          label: 'Password',
          hint: 'Minimum 6 characters',
          icon: Icons.lock_outline,
          obscureText: true,
        ),
        const SizedBox(height: 12),
        _buildInputField(
          controller: _confirmPasswordController,
          focusNode: _confirmPasswordFocus,
          tvFieldKey: _confirmPasswordTvFieldKey,
          label: 'Confirm Password',
          hint: 'Re-enter your password',
          icon: Icons.lock_clock_outlined,
          obscureText: true,
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                focusNode: _infoBackFocus,
                onPressed: () => _goToStep(0),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white24),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('Back'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: ElevatedButton(
                focusNode: _infoNextFocus,
                onPressed: _isLoading ? null : _validateStep2AndProceed,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColorScheme.accent,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            _isTrial ? 'Activate 24h Free Trial' : 'Proceed to Payment',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                          const SizedBox(width: 6),
                          const Icon(Icons.arrow_forward, size: 18),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildInputField({
    required TextEditingController controller,
    required FocusNode focusNode,
    required GlobalKey<CustomTVTextFieldState> tvFieldKey,
    required String label,
    required String hint,
    required IconData icon,
    bool obscureText = false,
    TextInputType keyboardType = TextInputType.text,
  }) {
    if (PlatformDetection.isTV) {
      return ListenableBuilder(
        listenable: focusNode,
        builder: (context, _) {
          final isFocused = focusNode.hasFocus;
          return CustomTVTextField(
            key: tvFieldKey,
            controller: controller,
            isFocused: isFocused,
            hint: label,
            textFieldType: obscureText ? TextFieldType.password : TextFieldType.other,
            filled: true,
            fillColor: isFocused ? Colors.white : Colors.white.withValues(alpha: 0.08),
            borderRadius: 12,
            borderColor: Colors.white.withValues(alpha: 0.1),
            focusedBorderColor: AppColorScheme.accent,
            hintStyle: TextStyle(
              color: isFocused ? Colors.black54 : Colors.white54,
            ),
            textStyle: TextStyle(
              color: isFocused ? Colors.black : Colors.white,
            ),
            prefixIcon: Icon(
              icon,
              color: isFocused ? Colors.black : Colors.white,
            ),
          );
        },
      );
    }

    return TextField(
      controller: controller,
      focusNode: focusNode,
      obscureText: obscureText,
      keyboardType: keyboardType,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, color: AppColorScheme.accent),
        filled: true,
        fillColor: const Color(0xFF141A26),
        labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
        hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.3)),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Colors.white12),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Colors.white12),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: AppColorScheme.accent, width: 2),
        ),
      ),
    );
  }

  // ──────────────── STEP 3: PACKAGES & PAYMENT OPTIONS ────────────────

  Widget _buildStep3PaymentOptions() {
    final isPass = _selectedPackage.isPass;
    final effectiveBillingMode = (isPass || _paymentMethod == 'eft') ? 'once_off' : _billingMode;

    return Column(
      key: const ValueKey(3),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Select Package, Duration & Payment',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Customize your subscription package, duration and payment method.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13),
        ),
        const SizedBox(height: 16),
        if (_errorMessage != null)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.redAccent.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.redAccent),
            ),
            child: Text(_errorMessage!, style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),

        // 1. Choose Service Package (3 Primary Items)
        const Text('1. Choose Service Package:', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 13)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _buildCategoryCard(
                id: 'bundle',
                title: 'Bundle Deal',
                subtitle: 'Live TV & Library',
                icon: Icons.all_inclusive,
                badge: 'BEST VALUE',
                isSelected: _selectedCategory == 'bundle',
                onTap: () {
                  setState(() {
                    _selectedCategory = 'bundle';
                    _selectedPackage = kVoltixPackages.firstWhere((p) => p.id == 'bundle_deal');
                    _billingMode = 'recurring';
                  });
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildCategoryCard(
                id: 'livetv',
                title: 'Live TV',
                subtitle: 'Channels & Sports',
                icon: Icons.live_tv,
                isSelected: _selectedCategory == 'livetv',
                onTap: () {
                  setState(() {
                    _selectedCategory = 'livetv';
                    if (_liveTvSubCategory == 'monthly') {
                      _selectedPackage = kVoltixPackages.firstWhere((p) => p.id == 'live_tv_4k');
                    } else {
                      _selectedPackage = kVoltixPackages.firstWhere((p) => p.id == 'sport_7_days_4k');
                      _billingMode = 'once_off';
                    }
                  });
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildCategoryCard(
                id: 'library',
                title: 'Library Access',
                subtitle: 'Movies & Series',
                icon: Icons.movie_filter,
                isSelected: _selectedCategory == 'library',
                onTap: () {
                  setState(() {
                    _selectedCategory = 'library';
                    _selectedPackage = kVoltixPackages.firstWhere((p) => p.id == 'media_library');
                    _billingMode = 'recurring';
                  });
                },
              ),
            ),
          ],
        ),

        // Live TV Sub-Menu (if Live TV category selected)
        if (_selectedCategory == 'livetv') ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF141A26),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColorScheme.accent.withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Live TV Package Type:', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 12)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ChoiceChip(
                        label: const Center(child: Text('Monthly Packages')),
                        selected: _liveTvSubCategory == 'monthly',
                        selectedColor: AppColorScheme.accent,
                        backgroundColor: const Color(0xFF0F1520),
                        labelStyle: TextStyle(
                          color: _liveTvSubCategory == 'monthly' ? Colors.black : Colors.white70,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                        onSelected: (val) {
                          if (val) {
                            setState(() {
                              _liveTvSubCategory = 'monthly';
                              _selectedPackage = kVoltixPackages.firstWhere((p) => p.id == 'live_tv_4k');
                              _billingMode = 'recurring';
                            });
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ChoiceChip(
                        label: const Center(child: Text('Pass Packages')),
                        selected: _liveTvSubCategory == 'pass',
                        selectedColor: AppColorScheme.accent,
                        backgroundColor: const Color(0xFF0F1520),
                        labelStyle: TextStyle(
                          color: _liveTvSubCategory == 'pass' ? Colors.black : Colors.white70,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                        onSelected: (val) {
                          if (val) {
                            setState(() {
                              _liveTvSubCategory = 'pass';
                              _selectedPackage = kVoltixPackages.firstWhere((p) => p.id == 'sport_7_days_4k');
                              _billingMode = 'once_off';
                            });
                          }
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_liveTvSubCategory == 'monthly') ...[
                  const Text('Select Stream Quality:', style: TextStyle(color: Colors.white60, fontSize: 11)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      _buildPackageOptionTile(
                        pkg: kVoltixPackages.firstWhere((p) => p.id == 'live_tv_4k'),
                        titleOverride: 'Live TV - 4K Stream',
                        isSelected: _selectedPackage.id == 'live_tv_4k',
                        onTap: () => setState(() => _selectedPackage = kVoltixPackages.firstWhere((p) => p.id == 'live_tv_4k')),
                      ),
                      const SizedBox(width: 8),
                      _buildPackageOptionTile(
                        pkg: kVoltixPackages.firstWhere((p) => p.id == 'live_tv_hd'),
                        titleOverride: 'Live TV - HD Stream',
                        isSelected: _selectedPackage.id == 'live_tv_hd',
                        onTap: () => setState(() => _selectedPackage = kVoltixPackages.firstWhere((p) => p.id == 'live_tv_hd')),
                      ),
                    ],
                  ),
                ] else ...[
                  const Text('Select Sport Pass Duration:', style: TextStyle(color: Colors.white60, fontSize: 11)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      _buildPackageOptionTile(
                        pkg: kVoltixPackages.firstWhere((p) => p.id == 'sport_7_days_4k'),
                        titleOverride: '4K 7 Day Sport',
                        isSelected: _selectedPackage.id == 'sport_7_days_4k',
                        onTap: () => setState(() {
                          _selectedPackage = kVoltixPackages.firstWhere((p) => p.id == 'sport_7_days_4k');
                          _billingMode = 'once_off';
                        }),
                      ),
                      const SizedBox(width: 8),
                      _buildPackageOptionTile(
                        pkg: kVoltixPackages.firstWhere((p) => p.id == 'sport_7_days_hd'),
                        titleOverride: 'HD 7 Day Sport',
                        isSelected: _selectedPackage.id == 'sport_7_days_hd',
                        onTap: () => setState(() {
                          _selectedPackage = kVoltixPackages.firstWhere((p) => p.id == 'sport_7_days_hd');
                          _billingMode = 'once_off';
                        }),
                      ),
                      const SizedBox(width: 8),
                      _buildPackageOptionTile(
                        pkg: kVoltixPackages.firstWhere((p) => p.id == 'sport_match_1_day'),
                        titleOverride: 'Day Pass (24h)',
                        isSelected: _selectedPackage.id == 'sport_match_1_day',
                        onTap: () => setState(() {
                          _selectedPackage = kVoltixPackages.firstWhere((p) => p.id == 'sport_match_1_day');
                          _billingMode = 'once_off';
                        }),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],

        const SizedBox(height: 18),

        // 2. Billing Duration Selection
        const Text('2. Choose Duration & Renewal:', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 13)),
        const SizedBox(height: 8),
        if (!isPass) ...[
          _buildDurationCard(
            id: 'recurring',
            title: 'Monthly Subscription (Auto-Renewing)',
            subtitle: 'R${_selectedPackage.price.toStringAsFixed(2)} today, then R${_selectedPackage.price.toStringAsFixed(2)} every month automatically. Cancel anytime.',
            badge: 'RECOMMENDED',
            isSelected: effectiveBillingMode == 'recurring',
            onTap: () => setState(() => _billingMode = 'recurring'),
          ),
          const SizedBox(height: 8),
          _buildDurationCard(
            id: 'once_off',
            title: 'Once-off Month',
            subtitle: 'R${_selectedPackage.price.toStringAsFixed(2)} for 1 month. No auto-renewal — renew manually whenever you choose.',
            isSelected: effectiveBillingMode == 'once_off',
            onTap: () => setState(() => _billingMode = 'once_off'),
          ),
        ] else ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF141A26),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white12),
            ),
            child: Row(
              children: [
                const Icon(Icons.confirmation_number_outlined, color: Colors.amberAccent, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Fixed Pass: ${_selectedPackage.durationLabel} (Once-off access, no auto-renewal).',
                    style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 18),

        // 3. Payment Method Selection
        const Text('3. Select Payment Method:', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 13)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _buildPaymentMethodChoice(
                id: 'payfast',
                label: 'PayFast Card',
                sublabel: 'Instant Activation',
                icon: Icons.credit_card,
                isSelected: _paymentMethod == 'payfast',
                onTap: () => setState(() => _paymentMethod = 'payfast'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _buildPaymentMethodChoice(
                id: 'eft',
                label: 'Direct EFT',
                sublabel: '1-2 Days Clearing',
                icon: Icons.account_balance,
                isSelected: _paymentMethod == 'eft',
                onTap: () => setState(() => _paymentMethod = 'eft'),
              ),
            ),
          ],
        ),

        const SizedBox(height: 14),

        // Payment Method Details
        if (_paymentMethod == 'payfast') ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF141A26),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white12),
            ),
            child: const Row(
              children: [
                Icon(Icons.shield_outlined, color: Colors.tealAccent, size: 24),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Paid securely through PayFast. Your subscription and Jellyfin server access will be activated immediately.',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ] else ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF141A26),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.account_balance, color: Colors.lightBlueAccent, size: 22),
                    SizedBox(width: 8),
                    Text('Direct EFT Banking Details:', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                  ],
                ),
                const SizedBox(height: 8),
                const Text('• Bank: First National Bank (FNB)', style: TextStyle(color: Colors.white70, fontSize: 12)),
                const Text('• Account Name: Voltix Studio', style: TextStyle(color: Colors.white70, fontSize: 12)),
                const Text('• Account Number: 63012345678 (Branch: 250655)', style: TextStyle(color: Colors.white70, fontSize: 12)),
                Text(
                  '• Payment Reference: VOLTIX-${_usernameController.text.trim().isEmpty ? 'USER' : _usernameController.text.trim().toUpperCase()}',
                  style: const TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 18),

        // Total Summary Box
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: AppColorScheme.accent.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColorScheme.accent.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_selectedPackage.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                  Text(
                    effectiveBillingMode == 'recurring' ? 'Monthly Auto-Renewing' : 'Once-off Payment',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 11),
                  ),
                ],
              ),
              Text(
                'R${_selectedPackage.price.toStringAsFixed(2)}',
                style: TextStyle(color: AppColorScheme.accent, fontWeight: FontWeight.w900, fontSize: 20),
              ),
            ],
          ),
        ),

        const SizedBox(height: 18),

        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                focusNode: _payBackFocus,
                onPressed: () => _goToStep(1),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white24),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('Back'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: ElevatedButton(
                focusNode: _paySubmitFocus,
                onPressed: _isLoading ? null : _handleSubscribe,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColorScheme.accent,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                      )
                    : Text(
                        _paymentMethod == 'payfast'
                            ? (effectiveBillingMode == 'recurring'
                                ? 'Subscribe — R${_selectedPackage.price.toStringAsFixed(2)}/mo'
                                : 'Pay R${_selectedPackage.price.toStringAsFixed(2)} Once')
                            : 'Complete EFT Order — R${_selectedPackage.price.toStringAsFixed(2)}',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDurationCard({
    required String id,
    required String title,
    required String subtitle,
    String? badge,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected ? AppColorScheme.accent.withValues(alpha: 0.12) : const Color(0xFF141A26),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? AppColorScheme.accent : Colors.white12,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              color: isSelected ? AppColorScheme.accent : Colors.white38,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                      if (badge != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppColorScheme.accent,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(badge, style: const TextStyle(color: Colors.black, fontSize: 8, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(subtitle, style: TextStyle(color: Colors.white.withValues(alpha: 0.65), fontSize: 11.5)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPaymentMethodChoice({
    required String id,
    required String label,
    required String sublabel,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: isSelected ? AppColorScheme.accent.withValues(alpha: 0.15) : const Color(0xFF141A26),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? AppColorScheme.accent : Colors.white12,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: isSelected ? AppColorScheme.accent : Colors.white60, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(color: isSelected ? Colors.white : Colors.white70, fontWeight: FontWeight.bold, fontSize: 12.5)),
                  Text(sublabel, style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 10.5)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryCard({
    required String id,
    required String title,
    required String subtitle,
    required IconData icon,
    String? badge,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: isSelected ? AppColorScheme.accent.withValues(alpha: 0.18) : const Color(0xFF141A26),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? AppColorScheme.accent : Colors.white12,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            if (badge != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                margin: const EdgeInsets.only(bottom: 4),
                decoration: BoxDecoration(
                  color: AppColorScheme.accent,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(badge, style: const TextStyle(color: Colors.black, fontSize: 8, fontWeight: FontWeight.bold)),
              ),
            ],
            Icon(icon, color: isSelected ? AppColorScheme.accent : Colors.white70, size: 24),
            const SizedBox(height: 6),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.white70,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 10),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPackageOptionTile({
    required VoltixSubscriptionPackage pkg,
    required String titleOverride,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: isSelected ? AppColorScheme.accent.withValues(alpha: 0.2) : const Color(0xFF0F1520),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected ? AppColorScheme.accent : Colors.white12,
              width: isSelected ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                titleOverride,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.white.withValues(alpha: 0.8),
                  fontWeight: FontWeight.bold,
                  fontSize: 11.5,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                'R${pkg.price.toStringAsFixed(2)}',
                style: TextStyle(
                  color: AppColorScheme.accent,
                  fontWeight: FontWeight.w900,
                  fontSize: 13.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ──────────────── STEP 4: SUCCESS ────────────────

  Widget _buildStep4Success() {
    if (_isPendingPayment) {
      final username = _usernameController.text.trim().toUpperCase();
      return Column(
        key: const ValueKey(4),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 16),
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.amber.shade400,
            ),
            child: const Icon(Icons.hourglass_top_rounded, size: 44, color: Colors.black),
          ),
          const SizedBox(height: 20),
          const Text(
            'Order Placed — Pending Activation',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _paymentMethod == 'eft'
                ? 'Your EFT order for R${_selectedPackage.price.toStringAsFixed(2)} has been submitted. Transfer payment using reference VOLTIX-${username.isEmpty ? "USER" : username} to activate.'
                : 'Your PayFast order for R${_selectedPackage.price.toStringAsFixed(2)} has been created. Access will activate automatically once payment clears.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 13.5),
          ),
          const SizedBox(height: 20),
          if (_paymentMethod == 'eft') ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF141A26),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Banking Details for Transfer:', style: TextStyle(color: Colors.tealAccent, fontWeight: FontWeight.bold, fontSize: 12.5)),
                  const SizedBox(height: 6),
                  const Text('• Bank: First National Bank (FNB)', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  const Text('• Account Name: Voltix Studio', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  const Text('• Account Number: 63012345678 (Branch: 250655)', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  Text('• Reference (Required): VOLTIX-${username.isEmpty ? "USER" : username}', style: const TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold, fontSize: 12)),
                ],
              ),
            ),
            const SizedBox(height: 20),
          ],
          ElevatedButton(
            onPressed: () {
              if (widget.onBackToLogin != null) {
                widget.onBackToLogin!();
              } else {
                context.go(Destinations.voltixLogin);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColorScheme.accent,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Return to Login', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          ),
          const SizedBox(height: 16),
        ],
      );
    }

    return Column(
      key: const ValueKey(4),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(height: 20),
        Container(
          width: 80,
          height: 80,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.greenAccent,
          ),
          child: const Icon(Icons.check, size: 48, color: Colors.black),
        ),
        const SizedBox(height: 24),
        const Text(
          'Account Activated!',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _isTrial
              ? 'Your 24-Hour Free Trial is now active. Welcome to Voltix!'
              : 'Your Voltix Subscription is active. Thank you for subscribing!',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 14),
        ),
        const SizedBox(height: 24),
        const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
        ),
        const SizedBox(height: 12),
        const Text(
          'Loading your personalized home screen...',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}
