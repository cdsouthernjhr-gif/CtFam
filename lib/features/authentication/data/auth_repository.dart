import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/app_config.dart';
import '../../../core/errors/app_failure.dart';
import '../../../shared/providers/supabase_providers.dart';

final authRepositoryProvider = Provider<AuthRepository>((ref) => AuthRepository(ref.watch(supabaseClientProvider)));

enum SignUpOutcome { signedIn, confirmationEmailSent }

class AuthRepository {
  AuthRepository(this._client);

  final SupabaseClient _client;
  GoTrueClient get _auth => _client.auth;

  User? get currentUser => _auth.currentUser;
  Stream<AuthState> get authStateChanges => _auth.onAuthStateChange;

  Future<void> signIn({required String email, required String password}) =>
      _guard(() => _auth.signInWithPassword(email: email.trim(), password: password));

  /// `display_name` in metadata is cosmetic only (profile default). It is
  /// never used for authorization.
  Future<SignUpOutcome> signUp({required String email, required String password, required String displayName}) =>
      _guard(() async {
        final res = await _auth.signUp(
          email: email.trim(),
          password: password,
          data: {'display_name': displayName.trim()},
          emailRedirectTo: AppConfig.authRedirectUrl,
        );
        // When the email is already registered, Supabase returns a user with
        // no identities and sends NO email (protection against account
        // enumeration). Tell the user instead of waiting for a code forever.
        final identities = res.user?.identities;
        if (res.session == null && identities != null && identities.isEmpty) {
          throw const AppFailure(FailureKind.emailInUse, 'repeated signup');
        }
        return res.session != null ? SignUpOutcome.signedIn : SignUpOutcome.confirmationEmailSent;
      });

  Future<void> sendPasswordReset(String email) =>
      _guard(() => _auth.resetPasswordForEmail(email.trim(), redirectTo: AppConfig.authRedirectUrl));

  /// Confirms a new account with the code from the confirmation email.
  /// Emits `signedIn` on success.
  Future<void> verifySignupCode({required String email, required String code}) =>
      _guard(() => _auth.verifyOTP(email: email.trim(), token: code.trim(), type: OtpType.email));

  /// Verifies a password-reset code. Emits `passwordRecovery`, which routes to
  /// the "new password" screen.
  Future<void> verifyRecoveryCode({required String email, required String code}) =>
      _guard(() => _auth.verifyOTP(email: email.trim(), token: code.trim(), type: OtpType.recovery));

  Future<void> resendSignupCode(String email) =>
      _guard(() => _auth.resend(email: email.trim(), type: OtpType.signup, emailRedirectTo: AppConfig.authRedirectUrl));

  Future<void> updatePassword(String newPassword) =>
      _guard(() => _auth.updateUser(UserAttributes(password: newPassword)));

  /// [everywhere] revokes all refresh tokens of this user (all devices).
  Future<void> signOut({bool everywhere = false}) =>
      _guard(() => _auth.signOut(scope: everywhere ? SignOutScope.global : SignOutScope.local));

  /// Deletes the account through the `delete-account` Edge Function, which
  /// holds the service-role key server-side.
  Future<void> deleteAccount() => _guard(() async {
    await _client.functions.invoke('delete-account', method: HttpMethod.post);
    await _auth.signOut(scope: SignOutScope.local);
  });

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }
}
