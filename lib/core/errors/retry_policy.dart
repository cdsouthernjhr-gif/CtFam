import 'app_failure.dart';

/// Riverpod's automatic retry for failed providers.
///
/// The default retries every exception up to 10 times (~40 s), and the screen
/// stays on "loading" the whole time, which hides permission or query errors.
/// Only connectivity failures are worth retrying; everything else is shown at
/// once (with the screen's own "Try again" button).
Duration? appRetry(int retryCount, Object error) {
  if (retryCount >= 3) return null;
  if (error is Error) return null; // programming errors
  if (AppFailure.from(error).kind != FailureKind.network) return null;
  return Duration(milliseconds: 500 << retryCount); // 0.5 s, 1 s, 2 s
}
