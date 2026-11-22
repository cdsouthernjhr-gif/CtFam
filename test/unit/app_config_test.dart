import 'dart:convert';

import 'package:familysync/core/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

String _jwt(Map<String, Object> claims) {
  String enc(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${enc({'alg': 'HS256', 'typ': 'JWT'})}.${enc(claims)}.signature';
}

void main() {
  test('missing configuration is reported', () {
    expect(AppConfig.validate(url: '', key: ''), isNotNull);
  });

  test('publishable keys are accepted', () {
    expect(AppConfig.validate(url: 'https://abc.supabase.co', key: 'sb_publishable_abc123'), isNull);
    expect(AppConfig.validate(url: 'https://abc.supabase.co', key: _jwt({'role': 'anon'})), isNull);
  });

  test('secret and service_role keys are refused', () {
    expect(AppConfig.isSecretKey('sb_secret_abc123'), isTrue);
    expect(AppConfig.isSecretKey(_jwt({'role': 'service_role'})), isTrue);
    expect(AppConfig.validate(url: 'https://abc.supabase.co', key: 'sb_secret_x'), isNotNull);
  });

  test('invalid URL is refused', () {
    expect(AppConfig.validate(url: 'not a url', key: 'sb_publishable_x'), isNotNull);
  });
}
