import 'package:familysync/core/errors/app_failure.dart';
import 'package:familysync/features/authentication/data/auth_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _MockClient extends Mock implements SupabaseClient {}

class _MockAuth extends Mock implements GoTrueClient {}

User _user({required List<UserIdentity> identities}) => User(
  id: 'u1',
  appMetadata: const {},
  userMetadata: const {},
  aud: 'authenticated',
  createdAt: '2026-11-22T00:00:00Z',
  identities: identities,
);

void main() {
  late _MockClient client;
  late _MockAuth auth;
  late AuthRepository repo;

  setUp(() {
    client = _MockClient();
    auth = _MockAuth();
    when(() => client.auth).thenReturn(auth);
    repo = AuthRepository(client);
  });

  void stubSignUp(AuthResponse res) => when(
    () => auth.signUp(
      email: any(named: 'email'),
      password: any(named: 'password'),
      data: any(named: 'data'),
      emailRedirectTo: any(named: 'emailRedirectTo'),
    ),
  ).thenAnswer((_) async => res);

  test('already-registered email (no identities, no session) is reported instead of waiting for a code', () async {
    stubSignUp(AuthResponse(user: _user(identities: const [])));
    expect(
      () => repo.signUp(email: 'a@b.co', password: 'abcd1234', displayName: 'A'),
      throwsA(isA<AppFailure>().having((f) => f.kind, 'kind', FailureKind.emailInUse)),
    );
  });

  test('new account waits for the confirmation code', () async {
    final identity = UserIdentity(
      id: 'i1',
      userId: 'u1',
      identityData: const {},
      identityId: 'i1',
      provider: 'email',
      createdAt: null,
      lastSignInAt: null,
      updatedAt: null,
    );
    stubSignUp(AuthResponse(user: _user(identities: [identity])));
    expect(
      await repo.signUp(email: 'a@b.co', password: 'abcd1234', displayName: 'A'),
      SignUpOutcome.confirmationEmailSent,
    );
  });
}
