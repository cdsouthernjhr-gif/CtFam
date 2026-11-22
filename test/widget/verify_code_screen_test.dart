import 'package:familysync/core/errors/app_failure.dart';
import 'package:familysync/features/authentication/data/auth_repository.dart';
import 'package:familysync/features/authentication/presentation/verify_code_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/pump_app.dart';

class _MockAuth extends Mock implements AuthRepository {}

void main() {
  late _MockAuth auth;
  setUp(() => auth = _MockAuth());

  Future<void> pump(WidgetTester tester, {required bool recovery}) => pumpLocalized(
    tester,
    VerifyCodeScreen(email: 'aminah@example.my', recovery: recovery),
    overrides: [authRepositoryProvider.overrideWithValue(auth)],
  );

  test('OTP format check', () {
    expect(isPlausibleOtp('123456'), isTrue);
    expect(isPlausibleOtp('12345678'), isTrue);
    expect(isPlausibleOtp('12345'), isFalse);
    expect(isPlausibleOtp('12a456'), isFalse);
  });

  testWidgets('recovery code is verified with the recovery type', (tester) async {
    when(
      () => auth.verifyRecoveryCode(
        email: any(named: 'email'),
        code: any(named: 'code'),
      ),
    ).thenAnswer((_) async {});
    await pump(tester, recovery: true);

    expect(find.text('Masukkan kod'), findsOneWidget);
    expect(find.textContaining('aminah@example.my'), findsOneWidget);
    expect(find.text('Hantar semula dalam 60s'), findsOneWidget, reason: 'resend has a cooldown');

    await tester.enterText(find.byKey(const Key('verify.code')), '123');
    await tester.tap(find.text('Sahkan'));
    await tester.pump();
    expect(find.text('Masukkan kod daripada e-mel (6–10 digit)'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('verify.code')), '482913');
    await tester.tap(find.text('Sahkan'));
    await tester.pump();
    verify(() => auth.verifyRecoveryCode(email: 'aminah@example.my', code: '482913')).called(1);
    verifyNever(
      () => auth.verifySignupCode(
        email: any(named: 'email'),
        code: any(named: 'code'),
      ),
    );
  });

  testWidgets('signup code uses the signup verification and shows server errors', (tester) async {
    when(
      () => auth.verifySignupCode(
        email: any(named: 'email'),
        code: any(named: 'code'),
      ),
    ).thenThrow(const AppFailure(FailureKind.invalidCode));
    await pump(tester, recovery: false);

    await tester.enterText(find.byKey(const Key('verify.code')), '000000');
    await tester.tap(find.text('Sahkan'));
    await tester.pump();
    await tester.pump();
    verify(() => auth.verifySignupCode(email: 'aminah@example.my', code: '000000')).called(1);
    expect(find.text('Kod tidak sah atau telah tamat tempoh. Minta kod baharu.'), findsOneWidget);
  });
}
