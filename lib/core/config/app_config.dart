import 'dart:convert';

/// Compile-time configuration supplied with `--dart-define-from-file`.
///
/// See `.env.example` and DEVELOPMENT.md. Only the Supabase **publishable**
/// key may ever be shipped in the app; [validate] refuses secret keys.
abstract final class AppConfig {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabasePublishableKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

  /// Base of shareable invitation links. The code is appended as `?code=`.
  /// Defaults to the app's custom scheme; set to an https App Link once a
  /// domain is verified.
  static const inviteLinkBase = String.fromEnvironment('INVITE_LINK_BASE', defaultValue: 'familysync://app/join');

  /// Firebase (Cloud Messaging) client identifiers. These are public values
  /// from the Firebase console (Project settings → Your apps → Android); the
  /// FCM service account is never part of the app. Push is disabled when any
  /// of them is missing.
  static const firebaseApiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const firebaseAppId = String.fromEnvironment('FIREBASE_APP_ID');
  static const firebaseMessagingSenderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
  static const firebaseProjectId = String.fromEnvironment('FIREBASE_PROJECT_ID');

  static bool get isPushConfigured =>
      firebaseApiKey.isNotEmpty &&
      firebaseAppId.isNotEmpty &&
      firebaseMessagingSenderId.isNotEmpty &&
      firebaseProjectId.isNotEmpty;

  /// Deep link Supabase Auth redirects to after email confirmation and
  /// password recovery. Must be added to Auth > URL Configuration.
  static const authRedirectUrl = 'familysync://auth-callback';

  /// Returns a problem description, or null when configuration is usable.
  static String? validate({String url = supabaseUrl, String key = supabasePublishableKey}) {
    if (url.isEmpty || key.isEmpty) {
      return 'SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY are not set.';
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http')) {
      return 'SUPABASE_URL is not a valid URL.';
    }
    if (isSecretKey(key)) {
      return 'A secret/service_role key was supplied. Only the publishable '
          'key may be used in the app.';
    }
    return null;
  }

  /// Detects keys that must never be embedded in a client build.
  static bool isSecretKey(String key) {
    if (key.startsWith('sb_secret_')) return true;
    // Legacy JWT keys: inspect the role claim.
    final parts = key.split('.');
    if (parts.length == 3) {
      try {
        final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
        final claims = jsonDecode(payload);
        if (claims is Map && claims['role'] == 'service_role') return true;
      } on FormatException {
        return false;
      }
    }
    return false;
  }

  static Uri inviteLink(String code) {
    final base = Uri.parse(inviteLinkBase);
    return base.replace(queryParameters: {...base.queryParameters, 'code': code});
  }
}
