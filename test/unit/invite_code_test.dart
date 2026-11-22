import 'package:familysync/core/config/app_config.dart';
import 'package:familysync/core/utils/invite_code.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const code = '7K3M9QX2HV4TB8NC';

  test('normalize matches the database rules', () {
    expect(InviteCode.normalize('7k3m-9qx2 hv4t_b8nc'), code);
    // Look-alikes are mapped exactly like private.normalize_invite_code.
    expect(InviteCode.normalize('OIL'), '011');
  });

  test('well-formed requires 16 Crockford base32 characters', () {
    expect(InviteCode.isWellFormed(code), isTrue);
    expect(InviteCode.isWellFormed('7K3M-9QX2-HV4T-B8NC'), isTrue);
    expect(InviteCode.isWellFormed('7K3M9QX2HV4TB8N'), isFalse); // 15
    expect(InviteCode.isWellFormed('7K3M9QX2HV4TB8NU'), isFalse); // U not in alphabet
  });

  test('format groups by four', () {
    expect(InviteCode.format(code), '7K3M-9QX2-HV4T-B8NC');
  });

  test('extract accepts bare codes and invite links', () {
    expect(InviteCode.extract(' 7k3m-9qx2-hv4t-b8nc '), code);
    expect(InviteCode.extract('familysync://app/join?code=$code'), code);
    expect(InviteCode.extract('https://example.com/join?code=$code&x=1'), code);
    expect(InviteCode.extract('hello'), isNull);
    expect(InviteCode.extract('familysync://app/join?code=SHORT'), isNull);
  });

  test('invite link round-trips through extract', () {
    final link = AppConfig.inviteLink(code).toString();
    expect(link, 'familysync://app/join?code=$code');
    expect(InviteCode.extract(link), code);
  });
}
