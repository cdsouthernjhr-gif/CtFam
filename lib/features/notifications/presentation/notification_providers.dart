import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/session_controller.dart';
import '../data/notification_repository.dart';
import '../domain/notification_models.dart';

/// Ticks on inbox changes (channel `notifications:{uid}`), while watched.
final inboxTickProvider = StreamProvider.autoDispose<int>((ref) {
  ref.watch(currentUserIdProvider);
  var tick = 0;
  return ref.watch(notificationRepositoryProvider).watchInbox().map((_) => ++tick);
});

final inboxProvider = FutureProvider.autoDispose<List<AppNotification>>((ref) {
  ref.watch(inboxTickProvider);
  return ref.watch(notificationRepositoryProvider).list();
});

final unreadNotificationsProvider = FutureProvider.autoDispose<int>((ref) {
  ref.watch(inboxTickProvider);
  return ref.watch(notificationRepositoryProvider).unreadCount();
});

final notificationPrefsProvider = FutureProvider.autoDispose<NotificationPrefs>(
  (ref) => ref.watch(notificationRepositoryProvider).prefs(),
);
