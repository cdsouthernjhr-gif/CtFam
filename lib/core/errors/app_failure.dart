import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Stable, translatable failure categories. Server functions raise short
/// snake_case messages (e.g. `forbidden`, `rate_limited`) that map here.
enum FailureKind {
  network,
  forbidden,
  rateLimited,
  invalidCredentials,
  emailNotConfirmed,
  emailInUse,
  weakPassword,
  confirmationMismatch,
  ownerMustTransfer,
  notFound,
  invalidInput,
  storageRejected,
  unknown,
}

class AppFailure implements Exception {
  const AppFailure(this.kind, [this.debugMessage]);

  final FailureKind kind;
  final String? debugMessage;

  @override
  String toString() => 'AppFailure($kind, $debugMessage)';

  static AppFailure from(Object error) {
    if (error is AppFailure) return error;
    if (error is SocketException || error is TimeoutException) {
      return AppFailure(FailureKind.network, error.toString());
    }
    if (error is AuthException) return _fromAuth(error);
    if (error is PostgrestException) return _fromPostgrest(error);
    if (error is StorageException) {
      return AppFailure(FailureKind.storageRejected, error.message);
    }
    if (error is FunctionException) {
      final details = error.details;
      final code = details is Map ? details['error']?.toString() : null;
      return AppFailure(_kindForCode(code) ?? FailureKind.unknown, '$code ${error.status}');
    }
    final text = error.toString();
    if (text.contains('SocketException') || text.contains('Failed host lookup')) {
      return AppFailure(FailureKind.network, text);
    }
    return AppFailure(FailureKind.unknown, text);
  }

  static AppFailure _fromAuth(AuthException e) {
    final code = e.code ?? '';
    final kind = switch (code) {
      'invalid_credentials' => FailureKind.invalidCredentials,
      'email_not_confirmed' => FailureKind.emailNotConfirmed,
      'user_already_exists' || 'email_exists' => FailureKind.emailInUse,
      'weak_password' => FailureKind.weakPassword,
      'over_email_send_rate_limit' || 'over_request_rate_limit' => FailureKind.rateLimited,
      _ when e is AuthRetryableFetchException => FailureKind.network,
      _ => FailureKind.unknown,
    };
    return AppFailure(kind, '${e.code}: ${e.message}');
  }

  static AppFailure _fromPostgrest(PostgrestException e) {
    final byMessage = _kindForCode(e.message);
    if (byMessage != null) return AppFailure(byMessage, e.message);
    final kind = switch (e.code) {
      '42501' => FailureKind.forbidden,
      'P0429' => FailureKind.rateLimited,
      'P0002' => FailureKind.notFound,
      '22023' || '23514' || '23505' => FailureKind.invalidInput,
      _ => FailureKind.unknown,
    };
    return AppFailure(kind, '${e.code}: ${e.message}');
  }

  static FailureKind? _kindForCode(String? code) => switch (code) {
    'forbidden' || 'cannot_manage_self' => FailureKind.forbidden,
    'rate_limited' => FailureKind.rateLimited,
    'confirmation_mismatch' => FailureKind.confirmationMismatch,
    'owner_must_transfer' => FailureKind.ownerMustTransfer,
    'member_not_found' => FailureKind.notFound,
    'not_authenticated' => FailureKind.forbidden,
    'invalid_max_uses' ||
    'invalid_expiry' ||
    'invalid_status' ||
    'invalid_transition' ||
    'not_pending' ||
    'member_not_active' ||
    'use_transfer_ownership' => FailureKind.invalidInput,
    _ => null,
  };
}
