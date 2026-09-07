import 'dart:async';

import 'package:dio/dio.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:get_it/get_it.dart';
import 'package:server_core/server_core.dart';

import '../../auth/repositories/user_repository.dart';
import '../../firebase_options.dart';
import '../../ui/navigation/app_router.dart';
import '../../util/platform_detection.dart';
import 'local_notification_bootstrap.dart';
import 'plugin_sync_service.dart';

/// Every push carries a notification block, so the OS draws background and
/// terminated notifications. Nothing to do here.
@pragma('vm:entry-point')
Future<void> pushBackgroundHandler(RemoteMessage message) async {}

/// Client side of the push notification path.
///
/// Registers the device's FCM token with both:
///   1. The Voltix Studio backend (`/api/push/register-token`) — so the admin
///      Notification Centre can target this device directly or via multicast.
///   2. The Moonfin Jellyfin server plugin — so Seerr request notifications
///      and library alerts reach this device.
///
/// Also subscribes the device to the FCM topic `all` so that topic-based
/// broadcasts from the admin panel are delivered.
class PushMessagingService {
  Future<void>? _initFuture;
  String? _lastRegisteredToken;

  /// Set when a registration attempt was skipped or failed because the plugin
  /// was not reachable yet, so the availability listener can retry it.
  bool _pendingRegistration = false;

  /// Repeated and concurrent callers share one initialization. A failed
  /// initialization clears itself so a later call can retry.
  Future<void> initialize() => _initFuture ??= _doInitialize();

  Future<void> _doInitialize() async {
    // Support Android (mobile, tablet, TV) and iOS
    if (!PlatformDetection.isAndroid && !PlatformDetection.isIOS) return;

    try {
      await Firebase.initializeApp(
        options: PlatformDetection.isAndroid
            ? null
            : DefaultFirebaseOptions.currentPlatform,
      );
    } on FirebaseException catch (e) {
      // A duplicate-app error means Firebase was already initialized earlier in
      // startup, which is fine; anything else aborts push setup.
      if (e.code != 'duplicate-app') {
        _initFuture = null;
        return;
      }
    } catch (_) {
      _initFuture = null;
      return;
    }

    // Initialize the local notification plugin so we can show foreground
    // notifications from the admin panel.
    try {
      await LocalNotificationBootstrap.instance.initialize();
    } catch (_) {}

    _attachAvailabilityListener();

    final messaging = FirebaseMessaging.instance;

    try {
      await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );
    } catch (_) {}

    // ── Topic subscriptions ──────────────────────────────────────────────
    // Subscribe to the default broadcast topics so the admin Notification
    // Centre can reach this device via topic sends. Firebase Console
    // campaigns that target "all app users" use a different mechanism, but
    // the admin panel sends to topic 'all'.
    try {
      await messaging.subscribeToTopic('all');
      if (PlatformDetection.isAndroid) {
        await messaging.subscribeToTopic('android');
      } else if (PlatformDetection.isIOS) {
        await messaging.subscribeToTopic('ios');
      }
    } catch (e) {
      debugPrint('PushMessagingService: topic subscription error: $e');
    }

    // On iOS the APNs token must be present before FCM will hand out a token.
    if (PlatformDetection.isIOS) {
      try {
        final apns = await messaging.getAPNSToken();
        if (apns == null) {
          debugPrint('PushMessagingService: no APNs token; check the Push '
              'Notifications capability and the APNs key in Firebase');
        }
      } catch (e) {
        debugPrint('PushMessagingService: getAPNSToken failed: $e');
      }
    }

    try {
      final token = await messaging.getToken();
      if (token == null) {
        debugPrint('PushMessagingService: getToken returned null');
      }
      await _registerToken(token);
    } catch (e) {
      debugPrint('PushMessagingService: getToken failed: $e');
    }

    messaging.onTokenRefresh.listen((token) {
      _registerToken(token);
    });

    // ── Foreground notification display ───────────────────────────────────
    // When the app is in the foreground, FCM does NOT show a system
    // notification — it delivers the message silently via onMessage. We must
    // display it ourselves using flutter_local_notifications so admin panel
    // pushes are visible even when the user has the app open.
    FirebaseMessaging.onMessage.listen((message) {
      final notification = message.notification;
      if (notification != null) {
        try {
          LocalNotificationBootstrap.instance.plugin.show(
            id: message.hashCode,
            title: notification.title,
            body: notification.body,
            notificationDetails: const NotificationDetails(
              android: AndroidNotificationDetails(
                seerrNotificationChannelId, // 'seerr_notifications'
                seerrNotificationChannelName, // 'Requests'
                importance: Importance.high,
                priority: Priority.high,
                autoCancel: true,
                playSound: true,
              ),
              iOS: DarwinNotificationDetails(
                presentAlert: true,
                presentSound: true,
                presentBadge: true,
              ),
            ),
            payload: message.data['actionUrl'] ?? message.data['route'],
          );
        } catch (_) {}
      }
    });

    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      _navigateFromMessage(message);
    });

    try {
      final initial = await messaging.getInitialMessage();
      if (initial != null) {
        _navigateFromMessage(initial);
      }
    } catch (_) {}
  }

  /// Re-registers the current FCM token after login. Waits for initialization
  /// instead of bailing: on a cold start with session restore this is reached
  /// before the deferred [initialize] call has run.
  Future<void> registerWithCurrentToken() async {
    if (!PlatformDetection.isAndroid && !PlatformDetection.isIOS) return;
    try {
      await initialize();
      // A server switch reuses the same FCM token, so drop the dedupe and let
      // the new server get its own registration.
      _lastRegisteredToken = null;
      final token = await FirebaseMessaging.instance.getToken();
      await _registerToken(token);
    } catch (_) {
      _pendingRegistration = true;
    }
  }

  /// Retries enrollment once the Moonfin plugin becomes reachable, covering
  /// registrations that were skipped while its availability check was still
  /// in flight.
  void _attachAvailabilityListener() {
    if (GetIt.instance.isRegistered<PluginSyncService>()) {
      final sync = GetIt.instance<PluginSyncService>();
      sync.addListener(() {
        if (sync.pluginAvailable && _pendingRegistration) {
          _pendingRegistration = false;
          unawaited(registerWithCurrentToken());
        }
      });
    }

    // Re-register on login so the push_devices table has the current user.
    if (GetIt.instance.isRegistered<UserRepository>()) {
      final userRepo = GetIt.instance<UserRepository>();
      userRepo.currentUserStream.listen((user) {
        if (user != null) {
          _lastRegisteredToken = null; // force re-registration with user info
          unawaited(registerWithCurrentToken());
        }
      });
    }
  }

  Future<void> _registerToken(String? token) async {
    if (!PlatformDetection.isAndroid && !PlatformDetection.isIOS) return;
    if (token == null || token.isEmpty) {
      debugPrint('PushMessagingService: skip register, no FCM token');
      return;
    }
    if (token == _lastRegisteredToken) return;

    // 1. Register with Voltix Studio Backend — this populates the
    //    push_devices table so the admin Notification Centre can send
    //    direct and multicast pushes to this device.
    unawaited(_registerWithVoltixServer(token));

    // 2. Register with Moonfin Jellyfin server plugin if active session exists
    final client = GetIt.instance.isRegistered<MediaServerClient>()
        ? GetIt.instance<MediaServerClient>()
        : null;
    if (client == null ||
        client.accessToken == null ||
        client.accessToken!.isEmpty) {
      debugPrint('PushMessagingService: skip plugin register, no active session');
      _pendingRegistration = true;
      _lastRegisteredToken = token;
      return;
    }

    if (!GetIt.instance.isRegistered<PluginSyncService>()) {
      debugPrint('PushMessagingService: skip plugin register, plugin sync unavailable');
      _pendingRegistration = true;
      _lastRegisteredToken = token;
      return;
    }
    final sync = GetIt.instance<PluginSyncService>();

    final sent = await sync.registerPushDevice(
      client,
      token: token,
      platform: PlatformDetection.isIOS ? 'ios' : 'android',
      deviceId: _deviceId(token),
    );
    if (!sent) {
      _pendingRegistration = true;
      return;
    }
    _pendingRegistration = false;
    _lastRegisteredToken = token;
  }

  /// Registers the FCM token with the Voltix Studio server so the admin
  /// Notification Centre's push_devices table knows about this device.
  Future<void> _registerWithVoltixServer(String token) async {
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      ));
      final platform = PlatformDetection.isIOS ? 'ios' : 'android';
      final model = PlatformDetection.deviceModel ??
          (PlatformDetection.isTV ? 'Android TV' : 'Android Device');
      final version = PlatformDetection.clientVersion ?? '2.5.0';

      String? username;
      if (GetIt.instance.isRegistered<UserRepository>()) {
        final currentUser = GetIt.instance<UserRepository>().currentUser;
        if (currentUser != null && currentUser.name.isNotEmpty) {
          username = currentUser.name;
        }
      }

      await dio.post(
        'https://www.voltixstudio.com/api/push/register-token',
        data: {
          'token': token,
          'platform': platform,
          'deviceModel': model,
          'appVersion': version,
          if (username != null && username.isNotEmpty) 'username': username,
        },
      );
      debugPrint('PushMessagingService: Registered with Voltix server '
          '(user: ${username ?? 'anonymous'})');
    } catch (e) {
      debugPrint('PushMessagingService: Voltix server registration failed: $e');
    }
  }

  /// Unregister this device with the plugin, e.g. on logout. No-op off mobile
  /// or when there is no active client.
  Future<void> unregister() async {
    if (!PlatformDetection.isAndroid && !PlatformDetection.isIOS) return;

    final client = GetIt.instance.isRegistered<MediaServerClient>()
        ? GetIt.instance<MediaServerClient>()
        : null;
    if (client == null) return;
    if (!GetIt.instance.isRegistered<PluginSyncService>()) return;

    await GetIt.instance<PluginSyncService>().unregisterPushDevice(
      client,
      deviceId: _deviceId(_lastRegisteredToken),
    );
    _lastRegisteredToken = null;
  }

  /// Reuses the app's Jellyfin device id so the plugin can tie the push
  /// registration to the same session; falls back to the token hash if the id
  /// is unavailable.
  String _deviceId(String? token) {
    if (GetIt.instance.isRegistered<DeviceInfo>()) {
      final id = GetIt.instance<DeviceInfo>().id.trim();
      if (id.isNotEmpty) return id;
    }
    return (token ?? '').hashCode.toString();
  }

  void _navigateFromMessage(RemoteMessage message) {
    final route = message.data['actionUrl'] ?? message.data['route'];
    if (route is String && route.trim().isNotEmpty) {
      appRouter.go(route.trim());
    }
  }
}
