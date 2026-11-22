import 'package:familysync/core/utils/validators.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('email', () {
    test('accepts normal addresses', () {
      expect(Validators.email('aminah@example.my'), isNull);
      expect(Validators.email('  a.b+c@d.co  '), isNull);
    });
    test('rejects empty and malformed', () {
      expect(Validators.email(''), ValidationError.required);
      expect(Validators.email(null), ValidationError.required);
      expect(Validators.email('no-at-sign'), ValidationError.invalidEmail);
      expect(Validators.email('a@b'), ValidationError.invalidEmail);
      expect(Validators.email('a b@c.com'), ValidationError.invalidEmail);
    });
  });

  group('password', () {
    test('requires length and a letter+digit mix', () {
      expect(Validators.password(''), ValidationError.required);
      expect(Validators.password('abc1'), ValidationError.passwordTooShort);
      expect(Validators.password('abcdefgh'), ValidationError.passwordNeedsLetterAndDigit);
      expect(Validators.password('12345678'), ValidationError.passwordNeedsLetterAndDigit);
      expect(Validators.password('keluarga2026'), isNull);
    });
    test('confirmation must match', () {
      expect(Validators.confirmPassword('x', 'y'), ValidationError.passwordsDoNotMatch);
      expect(Validators.confirmPassword('', 'y'), ValidationError.required);
      expect(Validators.confirmPassword('same1234', 'same1234'), isNull);
    });
  });

  group('names mirror database checks', () {
    test('display name 1..60', () {
      expect(Validators.displayName('   '), ValidationError.required);
      expect(Validators.displayName('A'), isNull);
      expect(Validators.displayName('x' * 61), ValidationError.nameTooLong);
    });
    test('family name 2..80', () {
      expect(Validators.familyName('A'), ValidationError.nameTooShort);
      expect(Validators.familyName('Keluarga Abdullah'), isNull);
      expect(Validators.familyName('x' * 81), ValidationError.nameTooLong);
    });
    test('optional phone', () {
      expect(Validators.optionalPhone(''), isNull);
      expect(Validators.optionalPhone('+60 12-345 6789'), isNull);
      expect(Validators.optionalPhone('call me'), ValidationError.invalidPhone);
    });
  });
}
