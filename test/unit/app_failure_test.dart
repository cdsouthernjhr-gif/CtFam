import 'dart:io';

import 'package:familysync/core/errors/app_failure.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('server RPC messages map to failure kinds', () {
    expect(AppFailure.from(const PostgrestException(message: 'forbidden', code: '42501')).kind, FailureKind.forbidden);
    expect(
      AppFailure.from(const PostgrestException(message: 'rate_limited', code: 'P0429')).kind,
      FailureKind.rateLimited,
    );
    expect(
      AppFailure.from(const PostgrestException(message: 'owner_must_transfer', code: '22023')).kind,
      FailureKind.ownerMustTransfer,
    );
    expect(
      AppFailure.from(const PostgrestException(message: 'permission denied for table x', code: '42501')).kind,
      FailureKind.forbidden,
    );
  });

  test('auth errors', () {
    expect(AppFailure.from(const AuthException('x', code: 'invalid_credentials')).kind, FailureKind.invalidCredentials);
    expect(AppFailure.from(const AuthException('x', code: 'email_not_confirmed')).kind, FailureKind.emailNotConfirmed);
    expect(AppFailure.from(const AuthException('x', code: 'weak_password')).kind, FailureKind.weakPassword);
  });

  test('network errors', () {
    expect(AppFailure.from(const SocketException('down')).kind, FailureKind.network);
  });

  test('unknown errors never throw', () {
    expect(AppFailure.from(StateError('boom')).kind, FailureKind.unknown);
  });
}
