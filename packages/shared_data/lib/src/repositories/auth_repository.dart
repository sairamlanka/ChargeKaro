import 'package:shared_models/shared_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../failure.dart';
import 'base.dart';

/// Supabase Auth plus the signed-in user's access. Roles always come from
/// the database (my_platform_access / my_business_access), never from the
/// client or user metadata.
class AuthRepository extends Repository {
  AuthRepository(super.client, {this.redirectUrl});

  final String? redirectUrl;

  Stream<AuthState> get changes => client.auth.onAuthStateChange;
  User? get currentUser => client.auth.currentUser;

  Future<void> signIn(String email, String password) =>
      guard(() => client.auth.signInWithPassword(email: email.trim().toLowerCase(), password: password));

  /// Returns true when the account needs email confirmation before sign-in.
  Future<bool> signUp({required String email, required String password, required String fullName, String? phone}) =>
      guard(() async {
        final res = await client.auth.signUp(
          email: email.trim().toLowerCase(),
          password: password,
          emailRedirectTo: redirectUrl,
          data: {'full_name': fullName.trim(), 'phone': ?phone},
        );
        return res.session == null;
      });

  Future<void> sendEmailOtp(String email) =>
      guard(() => client.auth.signInWithOtp(email: email.trim().toLowerCase(), shouldCreateUser: false, emailRedirectTo: redirectUrl));

  Future<void> verifyEmailOtp(String email, String token, {OtpType type = OtpType.email}) =>
      guard(() => client.auth.verifyOTP(email: email.trim().toLowerCase(), token: token.trim(), type: type));

  Future<void> resendConfirmation(String email) =>
      guard(() => client.auth.resend(type: OtpType.signup, email: email.trim().toLowerCase(), emailRedirectTo: redirectUrl));

  Future<void> sendPasswordReset(String email) =>
      guard(() => client.auth.resetPasswordForEmail(email.trim().toLowerCase(), redirectTo: redirectUrl));

  Future<void> updatePassword(String password) => guard(() => client.auth.updateUser(UserAttributes(password: password)));

  Future<void> signOut() => guard(() => client.auth.signOut());

  Future<PlatformAccess> platformAccess() async => PlatformAccess.fromJson(await rpc<Object?>('my_platform_access'));

  Future<List<BusinessAccess>> businessAccess() async {
    final list = await rpc<List<dynamic>?>('my_business_access');
    return (list ?? const []).map(BusinessAccess.fromJson).toList();
  }

  Future<Map<String, dynamic>?> myProfile() =>
      guard(() => client.from('profiles').select('id, full_name, phone, email, locale').eq('id', uid).maybeSingle());

  Future<void> updateProfile({required String fullName}) =>
      guard(() async => client.from('profiles').update({'full_name': fullName.trim()}).eq('id', uid));

  /// Maps an auth failure into one the UI can show; exposed for tests.
  static AppFailure describe(Object error) => AppFailure.from(error);
}
