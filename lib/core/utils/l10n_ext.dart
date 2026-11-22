import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/generated/app_localizations.dart';
import '../errors/app_failure.dart';
import 'validators.dart';

extension L10nContext on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);

  /// Localised message for any error thrown by a repository.
  String errorText(Object error) => l10n.failure(AppFailure.from(error).kind);

  void showMessage(String message, {bool error = false}) {
    final messenger = ScaffoldMessenger.maybeOf(this);
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), backgroundColor: error ? Theme.of(this).colorScheme.error : null),
      );
  }

  void showError(Object error) => showMessage(errorText(error), error: true);

  String formatDate(DateTime d) => DateFormat.yMMMd(l10n.localeName).format(d);
  String formatDateTime(DateTime d) => DateFormat.yMMMd(l10n.localeName).add_Hm().format(d);
}

extension AppLocalizationsX on AppLocalizations {
  String failure(FailureKind kind) => switch (kind) {
    FailureKind.network => errorNetwork,
    FailureKind.forbidden => errorForbidden,
    FailureKind.rateLimited => errorRateLimited,
    FailureKind.invalidCredentials => errorInvalidCredentials,
    FailureKind.emailNotConfirmed => errorEmailNotConfirmed,
    FailureKind.emailInUse => errorEmailInUse,
    FailureKind.weakPassword => errorWeakPassword,
    FailureKind.confirmationMismatch => errorConfirmationMismatch,
    FailureKind.ownerMustTransfer => errorOwnerMustTransfer,
    FailureKind.notFound => errorNotFound,
    FailureKind.invalidInput => errorInvalidInput,
    FailureKind.storageRejected => errorStorageRejected,
    FailureKind.invalidCode => errorInvalidCode,
    FailureKind.server => errorServer,
    FailureKind.emailDelivery => errorEmailDelivery,
    FailureKind.unknown => errorGeneric,
  };

  String? validation(ValidationError? e) => switch (e) {
    null => null,
    ValidationError.required => validationRequired,
    ValidationError.invalidEmail => validationEmail,
    ValidationError.passwordTooShort => validationPasswordShort(Validators.minPasswordLength),
    ValidationError.passwordNeedsLetterAndDigit => validationPasswordMix,
    ValidationError.passwordsDoNotMatch => validationPasswordMismatch,
    ValidationError.nameTooShort => validationNameShort,
    ValidationError.nameTooLong => validationNameLong,
    ValidationError.invalidInviteCode => validationInviteCode,
    ValidationError.invalidPhone => validationPhone,
  };
}
