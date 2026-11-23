import 'dart:async';

import 'package:familysync/features/authentication/data/auth_repository.dart';
import 'package:familysync/features/notifications/data/notification_repository.dart';
import 'package:familysync/features/notifications/domain/notification_models.dart';
import 'package:familysync/features/notifications/presentation/notification_settings_screen.dart';
import 'package:familysync/features/notifications/presentation/notifications_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../helpers/pump_app.dart';

class _MockRepo extends Mock implements NotificationRepository {}

class _MockClient extends Mock implements SupabaseClient {}

class _MockAuth extends Mock implements GoTrueClient {}

void main() {
  late _MockRepo repo;

  setUpAll(() => registerFallbackValue(SignOutScope.local));

  setUp(() {
    repo = _MockRepo();
    when(() => repo.watchInbox()).thenAnswer((_) => const Stream.empty());
  });

  testWidgets('inbox lists notifications and marks all as read', (tester) async {
    when(() => repo.list(limit: any(named: 'limit'))).thenAnswer(
      (_) async => [
        AppNotification(
          id: 'n1',
          type: 'announcement',
          title: 'Kenduri Ahad',
          body: 'Datang jam 12',
          createdAt: DateTime(2026, 11, 23, 9),
        ),
      ],
    );
    when(() => repo.unreadCount()).thenAnswer((_) async => 1);
    when(() => repo.markRead(any())).thenAnswer((_) async {});
    await pumpLocalized(
      tester,
      const NotificationsScreen(),
      overrides: [notificationRepositoryProvider.overrideWithValue(repo)],
    );

    expect(find.text('Kenduri Ahad'), findsOneWidget);
    await tester.tap(find.byTooltip('Tandakan semua dibaca'));
    await tester.pumpAndSettle();
    verify(() => repo.markRead()).called(1);
  });

  testWidgets('settings: privacy default off, toggling preview saves it, push banner when not configured', (
    tester,
  ) async {
    when(() => repo.prefs()).thenAnswer((_) async => const NotificationPrefs());
    when(() => repo.updatePrefs(any())).thenAnswer((_) async {});
    await pumpLocalized(
      tester,
      const NotificationSettingsScreen(),
      overrides: [notificationRepositoryProvider.overrideWithValue(repo)],
    );

    expect(find.textContaining('belum disediakan'), findsOneWidget, reason: 'no Firebase config in tests');
    final preview = tester.widget<SwitchListTile>(find.byKey(const Key('prefs.preview')));
    expect(preview.value, isFalse);

    await tester.tap(find.byKey(const Key('prefs.preview')));
    await tester.pumpAndSettle();
    verify(() => repo.updatePrefs({'show_message_preview': true})).called(1);
  });

  test('sign-out runs registered hooks first (push token removal)', () async {
    final client = _MockClient();
    final auth = _MockAuth();
    when(() => client.auth).thenReturn(auth);
    final order = <String>[];
    when(() => auth.signOut(scope: any(named: 'scope'))).thenAnswer((_) async => order.add('signOut'));
    Future<void> hook() async => order.add('hook');
    AuthRepository.beforeSignOut.add(hook);
    addTearDown(() => AuthRepository.beforeSignOut.remove(hook));

    await AuthRepository(client).signOut();
    expect(order, ['hook', 'signOut']);
  });

  test('a failing hook never blocks sign-out', () async {
    final client = _MockClient();
    final auth = _MockAuth();
    when(() => client.auth).thenReturn(auth);
    var signedOut = false;
    when(() => auth.signOut(scope: any(named: 'scope'))).thenAnswer((_) async => signedOut = true);
    Future<void> broken() => Future.error(StateError('offline'));
    AuthRepository.beforeSignOut.add(broken);
    addTearDown(() => AuthRepository.beforeSignOut.remove(broken));

    await AuthRepository(client).signOut();
    expect(signedOut, isTrue);
  });
}
