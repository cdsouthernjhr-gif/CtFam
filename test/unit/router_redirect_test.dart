import 'package:familysync/core/router/app_router.dart';
import 'package:familysync/core/router/routes.dart';
import 'package:familysync/shared/providers/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

String? go(SessionStatus status, String path, {String? pendingInvite}) =>
    resolveRedirect(SessionState(status: status, pendingInviteCode: pendingInvite), Uri.parse(path));

void main() {
  test('unconfigured always shows config error', () {
    expect(go(SessionStatus.unconfigured, Routes.home), Routes.configError);
    expect(go(SessionStatus.unconfigured, Routes.configError), isNull);
  });

  test('signed out users can only reach public routes', () {
    expect(go(SessionStatus.signedOut, Routes.home), Routes.signIn);
    expect(go(SessionStatus.signedOut, Routes.family), Routes.signIn);
    expect(go(SessionStatus.signedOut, Routes.join), Routes.signIn);
    expect(go(SessionStatus.signedOut, Routes.signUp), isNull);
    expect(go(SessionStatus.signedOut, Routes.forgotPassword), isNull);
    expect(go(SessionStatus.signedOut, '/verify-code?email=a@b.co&purpose=recovery'), isNull);
  });

  test('users without a family are kept in onboarding', () {
    expect(go(SessionStatus.needsFamily, Routes.home), Routes.onboarding);
    expect(go(SessionStatus.needsFamily, Routes.family), Routes.onboarding);
    expect(go(SessionStatus.needsFamily, Routes.join), isNull);
    expect(go(SessionStatus.needsFamily, Routes.createFamily), isNull);
  });

  test('pending invite deep link resumes after sign-in', () {
    expect(go(SessionStatus.needsFamily, Routes.onboarding, pendingInvite: 'ABC'), '/join?code=ABC');
    expect(go(SessionStatus.ready, Routes.home, pendingInvite: 'ABC'), '/join?code=ABC');
    expect(go(SessionStatus.ready, '/join?code=ABC', pendingInvite: 'ABC'), isNull);
  });

  test('ready users skip entry screens', () {
    expect(go(SessionStatus.ready, Routes.signIn), Routes.home);
    expect(go(SessionStatus.ready, Routes.onboarding), Routes.home);
    expect(go(SessionStatus.ready, Routes.family), isNull);
    expect(go(SessionStatus.ready, Routes.invite), isNull);
  });

  test('password recovery forces the reset screen', () {
    expect(go(SessionStatus.passwordRecovery, Routes.home), Routes.resetPassword);
    expect(go(SessionStatus.passwordRecovery, Routes.resetPassword), isNull);
    expect(
      go(SessionStatus.passwordRecovery, Routes.verifyCode),
      Routes.resetPassword,
      reason: 'a verified recovery code always leads to the new-password screen',
    );
  });
}
