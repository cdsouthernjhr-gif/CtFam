/// Pure input validators. They return an error *key* (not a translated
/// string) so they can be unit tested without a BuildContext; the UI maps the
/// key with `ValidationMessages`.
enum ValidationError {
  required,
  invalidEmail,
  passwordTooShort,
  passwordNeedsLetterAndDigit,
  passwordsDoNotMatch,
  nameTooShort,
  nameTooLong,
  invalidInviteCode,
  invalidPhone,
}

abstract final class Validators {
  static final _email = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');
  static final _phone = RegExp(r'^\+?[0-9 ()-]{6,20}$');

  static const minPasswordLength = 8;

  static ValidationError? email(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return ValidationError.required;
    if (v.length > 254 || !_email.hasMatch(v)) return ValidationError.invalidEmail;
    return null;
  }

  static ValidationError? password(String? value) {
    final v = value ?? '';
    if (v.isEmpty) return ValidationError.required;
    if (v.length < minPasswordLength) return ValidationError.passwordTooShort;
    if (!RegExp(r'[A-Za-z]').hasMatch(v) || !RegExp(r'[0-9]').hasMatch(v)) {
      return ValidationError.passwordNeedsLetterAndDigit;
    }
    return null;
  }

  static ValidationError? confirmPassword(String? value, String original) {
    if ((value ?? '').isEmpty) return ValidationError.required;
    if (value != original) return ValidationError.passwordsDoNotMatch;
    return null;
  }

  /// Mirrors the DB check: display names are 1-60 characters after trim.
  static ValidationError? displayName(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return ValidationError.required;
    if (v.length > 60) return ValidationError.nameTooLong;
    return null;
  }

  /// Mirrors the DB check: family names are 2-80 characters after trim.
  static ValidationError? familyName(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return ValidationError.required;
    if (v.length < 2) return ValidationError.nameTooShort;
    if (v.length > 80) return ValidationError.nameTooLong;
    return null;
  }

  static ValidationError? optionalPhone(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return null;
    if (!_phone.hasMatch(v)) return ValidationError.invalidPhone;
    return null;
  }
}
