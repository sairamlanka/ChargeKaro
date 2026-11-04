import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_data/shared_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:retailer_app/data/firebase_phone.dart';
import 'package:retailer_app/l10n/en.dart';
import 'package:retailer_app/l10n/l10n.dart';
import 'package:retailer_app/ui/common/fallback.dart';

void main() {
  const l = L(Locale('en'), en);
  String shown(String code) => localizedFailureMessage(l, FirebasePhoneAuth.failureFor(FirebaseAuthException(code: code)));

  test('Firebase errors read like the existing OTP messages', () {
    expect(shown('invalid-verification-code'), en[K.otpWrongOrExpired]);
    expect(shown('session-expired'), en[K.otpWrongOrExpired]);
    expect(shown('too-many-requests'), en[K.otpTooMany]);
    expect(shown('invalid-phone-number'), en[K.errInvalidPhone]);
    expect(shown('app-not-authorized'), en[K.otpUnavailable]);
    expect(shown('something-new'), en[K.otpSendFailed]);
  });

  test('server refusals of the Firebase token are explained', () {
    expect(localizedFailureMessage(l, const AppFailure(FailureKind.conflict, 'phone_in_use', 'x')), en[K.errPhoneInUse]);
    expect(localizedFailureMessage(l, const AppFailure(FailureKind.unauthenticated, 'firebase_token_stale', 'x')), en[K.otpWrongOrExpired]);
  });

  test('off unless the build turns it on', () => expect(FirebasePhoneConfig.usable, isFalse));
}
