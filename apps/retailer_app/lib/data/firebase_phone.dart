import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_data/shared_data.dart';

/// Phone codes sent and checked by Firebase Authentication instead of the
/// Supabase SMS hook. On when the build sets FIREBASE_OTP=true with the
/// Firebase app's values (env/development.json); otherwise sign-in keeps
/// using Supabase phone OTP (the dev code screen in development).
abstract final class FirebasePhoneConfig {
  static const enabled = bool.fromEnvironment('FIREBASE_OTP');
  static const _apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const _appId = String.fromEnvironment('FIREBASE_APP_ID');
  static const _senderId = String.fromEnvironment('FIREBASE_SENDER_ID');
  static const _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');

  static bool get usable => enabled && !kIsWeb && _apiKey.isNotEmpty && _appId.isNotEmpty && _projectId.isNotEmpty;

  static FirebaseOptions get options =>
      const FirebaseOptions(apiKey: _apiKey, appId: _appId, messagingSenderId: _senderId, projectId: _projectId);
}

/// Sends a code to a phone and turns the code the customer types into a
/// Firebase ID token for the firebase-phone-auth Edge Function.
class FirebasePhoneAuth {
  FirebasePhoneAuth({FirebaseAuth? auth}) : _given = auth;

  final FirebaseAuth? _given;
  FirebaseAuth? _auth;
  String? _phone;
  String? _verificationId;
  int? _resendToken;

  /// Set when Android read the SMS by itself; no typing needed.
  PhoneAuthCredential? _instant;

  Future<FirebaseAuth> _ready() async {
    if (_auth != null) return _auth!;
    if (_given != null) return _auth = _given;
    if (Firebase.apps.isEmpty) await Firebase.initializeApp(options: FirebasePhoneConfig.options);
    return _auth = FirebaseAuth.instance;
  }

  Future<void> send(String phone) async {
    final auth = await _ready();
    final done = Completer<void>();
    final resend = phone == _phone ? _resendToken : null;
    _phone = phone;
    _instant = null;
    await auth.verifyPhoneNumber(
      phoneNumber: phone,
      forceResendingToken: resend,
      timeout: const Duration(seconds: 60),
      codeSent: (id, token) {
        _verificationId = id;
        _resendToken = token;
        if (!done.isCompleted) done.complete();
      },
      verificationCompleted: (credential) {
        _instant = credential;
        if (!done.isCompleted) done.complete();
      },
      verificationFailed: (e) {
        if (!done.isCompleted) done.completeError(failureFor(e));
      },
      codeAutoRetrievalTimeout: (id) => _verificationId ??= id,
    );
    return done.future.timeout(const Duration(seconds: 90),
        onTimeout: () => throw const AppFailure(FailureKind.network, 'sms_send_failed', 'The code could not be sent. Please try again.'));
  }

  /// A fresh Firebase ID token for the verified phone. Firebase's own sign-in
  /// is closed straight after; the app's session is Supabase's.
  Future<String> verify(String phone, String code) async {
    final auth = await _ready();
    final id = _verificationId;
    final credential = code.trim().isEmpty && _instant != null
        ? _instant!
        : (id == null || phone != _phone)
            ? throw const AppFailure(FailureKind.validation, 'otp_expired', 'The code is wrong or has expired.')
            : PhoneAuthProvider.credential(verificationId: id, smsCode: code.trim());
    try {
      final result = await auth.signInWithCredential(credential);
      final token = await result.user?.getIdToken(true);
      if (token == null) throw const AppFailure(FailureKind.server, 'sms_send_failed', 'Please try again.');
      return token;
    } on FirebaseAuthException catch (e) {
      throw failureFor(e);
    } finally {
      unawaited(auth.signOut().catchError((_) {}));
    }
  }

  /// Firebase error codes as the app's existing OTP failure codes.
  static AppFailure failureFor(FirebaseAuthException e) => switch (e.code) {
        'invalid-verification-code' || 'invalid-verification-id' || 'session-expired' || 'code-expired' =>
          const AppFailure(FailureKind.validation, 'otp_expired', 'The code is wrong or has expired.'),
        'too-many-requests' || 'quota-exceeded' =>
          const AppFailure(FailureKind.conflict, 'over_sms_send_rate_limit', 'Too many attempts. Please wait and try again.'),
        'invalid-phone-number' => const AppFailure(FailureKind.validation, 'invalid_phone', 'Enter a valid mobile number.'),
        'operation-not-allowed' || 'app-not-authorized' || 'missing-client-identifier' =>
          AppFailure(FailureKind.server, 'phone_provider_disabled', 'Phone sign-in is not available right now.', detail: e.code),
        'network-request-failed' => const AppFailure(FailureKind.network, 'network', 'No connection. Check your internet and try again.'),
        _ => AppFailure(FailureKind.server, 'sms_send_failed', 'The code could not be sent. Please try again.', detail: '${e.code}: ${e.message}'),
      };
}
