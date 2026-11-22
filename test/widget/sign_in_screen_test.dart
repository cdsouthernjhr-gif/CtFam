import 'package:familysync/features/authentication/data/auth_repository.dart';
import 'package:familysync/features/authentication/presentation/auth_screens.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/pump_app.dart';

class _MockAuth extends Mock implements AuthRepository {}

void main() {
  late _MockAuth auth;
  setUp(() => auth = _MockAuth());

  testWidgets('shows Malay validation errors and does not call the server', (tester) async {
    await pumpLocalized(tester, const SignInScreen(), overrides: [authRepositoryProvider.overrideWithValue(auth)]);

    expect(find.text('Selamat datang ke FamilySync'), findsOneWidget);
    await tester.tap(find.text('Log masuk'));
    await tester.pumpAndSettle();

    expect(find.text('Ruangan ini wajib diisi'), findsNWidgets(2));
    verifyNever(
      () => auth.signIn(
        email: any(named: 'email'),
        password: any(named: 'password'),
      ),
    );
  });

  testWidgets('submits trimmed credentials', (tester) async {
    when(
      () => auth.signIn(
        email: any(named: 'email'),
        password: any(named: 'password'),
      ),
    ).thenAnswer((_) async {});
    await pumpLocalized(tester, const SignInScreen(), overrides: [authRepositoryProvider.overrideWithValue(auth)]);

    await tester.enterText(find.byKey(const Key('signIn.email')), 'aminah@example.my');
    await tester.enterText(find.byKey(const Key('signIn.password')), 'rahsia123');
    await tester.tap(find.text('Log masuk'));
    await tester.pumpAndSettle();

    verify(() => auth.signIn(email: 'aminah@example.my', password: 'rahsia123')).called(1);
  });

  testWidgets('renders in English when selected', (tester) async {
    await pumpLocalized(
      tester,
      const SignInScreen(),
      overrides: [authRepositoryProvider.overrideWithValue(auth)],
      locale: const Locale('en'),
    );
    expect(find.text('Welcome to FamilySync'), findsOneWidget);
  });
}
