import 'dart:io';

import 'package:familysync/core/errors/app_failure.dart';
import 'package:familysync/core/errors/retry_policy.dart';
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
    expect(AppFailure.from(const AuthException('x', code: 'otp_expired')).kind, FailureKind.invalidCode);
  });

  test('network errors', () {
    expect(AppFailure.from(const SocketException('down')).kind, FailureKind.network);
    expect(
      AppFailure.from(AuthRetryableFetchException(message: 'ClientException: Failed host lookup')).kind,
      FailureKind.network,
      reason: 'no status code = real connectivity failure',
    );
  });

  test('HTTP 5xx from Auth is a server problem, not "no internet"', () {
    expect(
      AppFailure.from(
        AuthRetryableFetchException(
          message: '{"code":500,"error_code":"unexpected_failure","msg":"Error sending recovery email"}',
          statusCode: '500',
        ),
      ).kind,
      FailureKind.emailDelivery,
    );
    expect(
      AppFailure.from(AuthRetryableFetchException(message: '{"msg":"Internal error"}', statusCode: '503')).kind,
      FailureKind.server,
    );
  });

  test('unknown errors never throw', () {
    expect(AppFailure.from(StateError('boom')).kind, FailureKind.unknown);
  });

  group('retry policy', () {
    test('retries only network failures, at most 3 times', () {
      const network = AppFailure(FailureKind.network);
      expect(appRetry(0, network), const Duration(milliseconds: 500));
      expect(appRetry(2, network), const Duration(seconds: 2));
      expect(appRetry(3, network), isNull);
      expect(appRetry(0, const AppFailure(FailureKind.forbidden)), isNull, reason: 'shown at once');
      expect(appRetry(0, const PostgrestException(message: 'ambiguous', code: 'PGRST201')), isNull);
      expect(appRetry(0, StateError('bug')), isNull);
    });
  });
}
