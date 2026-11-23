import 'package:drift/drift.dart' show DatabaseConnection, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:familysync/core/offline/local_database.dart';
import 'package:familysync/core/offline/offline_store.dart';
import 'package:familysync/core/offline/sync_engine.dart';
import 'package:familysync/core/theme/app_theme.dart';
import 'package:familysync/l10n/generated/app_localizations.dart';
import 'package:familysync/shared/providers/session_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// On-device database in memory, connectivity "on", and RPC replay recorded
/// in [rpcCalls] (no network). Pass [userId] when no session is overridden.
List<Override> offlineOverrides({String? userId, List<(String, Map<String, dynamic>)>? rpcCalls, LocalDatabase? db}) {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true; // one in-memory DB per test
  // Streams close synchronously so widget tests do not see pending timers.
  final database = db ?? LocalDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
  return [
    localDatabaseProvider.overrideWithValue(database),
    offlineStoreProvider.overrideWithValue(OfflineStore(database, currentUserId: () => userId)),
    connectivityProvider.overrideWith((ref) => Stream.value(true)),
    rpcRunnerProvider.overrideWithValue((rpc, params) async => rpcCalls?.add((rpc, params))),
    if (userId != null) currentUserIdProvider.overrideWithValue(userId),
  ];
}

/// Pumps [child] with localisation (Malay by default) and provider overrides.
Future<void> pumpLocalized(
  WidgetTester tester,
  Widget child, {
  List<Override> overrides = const [],
  Locale locale = const Locale('ms'),
  bool defaultOffline = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [if (defaultOffline) ...offlineOverrides(), ...overrides],
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: locale,
        supportedLocales: const [Locale('ms'), Locale('en')],
        localizationsDelegates: const [AppLocalizations.delegate, ...GlobalMaterialLocalizations.delegates],
        home: child,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

User fakeUser(String id) => User(
  id: id,
  appMetadata: const {},
  userMetadata: const {},
  aud: 'authenticated',
  createdAt: '2026-11-22T00:00:00Z',
);

/// Session notifier with a fixed state (no Supabase access).
class FixedSession extends SessionController {
  FixedSession(this.initial);

  final SessionState initial;

  @override
  SessionState build() => initial;

  @override
  Future<void> refresh() async {}
}
