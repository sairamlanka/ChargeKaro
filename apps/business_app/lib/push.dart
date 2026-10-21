import 'dart:async';
import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_data/shared_data.dart';

/// Firebase Cloud Messaging. Off unless the build sets FCM_ENABLED=true and
/// ships google-services.json / GoogleService-Info.plist (both git-ignored).
/// Notifications are always stored in the database too, so the in-app list
/// works without push.
abstract final class Push {
  static const enabled = bool.fromEnvironment('FCM_ENABLED');
  static bool _ready = false;
  static StreamSubscription<String>? _refresh;

  static Future<void> initialize() async {
    if (!enabled || kIsWeb) return;
    try {
      await Firebase.initializeApp();
      _ready = true;
    } catch (e) {
      debugPrint('Push disabled: Firebase is not configured ($e)');
    }
  }

  /// Asks permission and registers this device for the signed-in user.
  static Future<void> register(NotificationRepository repo) async {
    if (!_ready) return;
    final messaging = FirebaseMessaging.instance;
    final settings = await messaging.requestPermission();
    if (settings.authorizationStatus == AuthorizationStatus.denied) return;
    final platform = Platform.isIOS ? 'ios' : 'android';
    // The Edge Function sends through the FCM HTTP v1 API, which addresses
    // devices by registration token. firebase_messaging 17 deprecates
    // getToken in favour of Installation-ID registration; switch both ends
    // together once the server path is verified (docs/deployment.md).
    // ignore: deprecated_member_use
    final token = await messaging.getToken();
    if (token != null) await repo.registerDeviceToken(token, platform: platform, app: ClientApp.business);
    await _refresh?.cancel();
    // ignore: deprecated_member_use
    _refresh = messaging.onTokenRefresh.listen((t) => repo.registerDeviceToken(t, platform: platform, app: ClientApp.business));
  }

  /// Called before sign-out so the device stops receiving this user's pushes.
  static Future<void> unregister(NotificationRepository repo) async {
    if (!_ready) return;
    await _refresh?.cancel();
    // ignore: deprecated_member_use
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) await repo.unregisterDeviceToken(token).catchError((_) {});
  }
}
