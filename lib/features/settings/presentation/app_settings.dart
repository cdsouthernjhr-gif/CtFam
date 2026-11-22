import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../shared/providers/session_controller.dart';
import '../data/profile_repository.dart';

const supportedLocales = [Locale('ms'), Locale('en')];

/// UI language. Malay is the primary language; the user's choice is stored in
/// `profiles.locale` and restored after sign-in.
final localeProvider = NotifierProvider<LocaleController, Locale>(LocaleController.new);

class LocaleController extends Notifier<Locale> {
  @override
  Locale build() {
    final status = ref.watch(sessionControllerProvider.select((s) => s.status));
    if (status == SessionStatus.ready || status == SessionStatus.needsFamily) {
      ref.read(profileRepositoryProvider).me().then((p) {
        if (p.locale != state.languageCode) state = Locale(p.locale);
      }, onError: (_) {});
    }
    return stateOrNull ?? const Locale('ms');
  }

  Future<void> set(Locale locale) async {
    state = locale;
    final signedIn = ref.read(currentUserIdProvider) != null;
    if (signedIn) {
      await ref.read(profileRepositoryProvider).update(locale: locale.languageCode);
    }
  }
}

final themeModeProvider = NotifierProvider<ThemeModeController, ThemeMode>(ThemeModeController.new);

class ThemeModeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    final status = ref.watch(sessionControllerProvider.select((s) => s.status));
    if (status == SessionStatus.ready || status == SessionStatus.needsFamily) {
      ref.read(profileRepositoryProvider).themeMode().then((m) {
        state = _parse(m);
      }, onError: (_) {});
    }
    return stateOrNull ?? ThemeMode.system;
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    await ref.read(profileRepositoryProvider).setThemeMode(mode.name);
  }

  static ThemeMode _parse(String v) => switch (v) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };
}
