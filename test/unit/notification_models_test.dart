import 'package:familysync/features/notifications/domain/notification_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const uuid = '3f2504e0-4f89-11d3-9a0c-0305e82c3301';

  test('only known in-app routes are accepted from notification payloads', () {
    expect(safeNotificationRoute('/chat/$uuid'), '/chat/$uuid');
    expect(safeNotificationRoute('/todo/$uuid'), '/todo/$uuid');
    expect(safeNotificationRoute('/family'), '/family');
    expect(safeNotificationRoute('/home'), '/home');
    expect(safeNotificationRoute('https://evil.example/phish'), isNull);
    expect(safeNotificationRoute('/profile/password'), isNull);
    expect(safeNotificationRoute('/chat/not-a-uuid'), isNull);
    expect(safeNotificationRoute('/chat/$uuid/info/../../profile'), isNull);
    expect(safeNotificationRoute(42), isNull);
    expect(safeNotificationRoute(null), isNull);
  });

  test('time of day parsing and formatting', () {
    expect(parseTimeOfDay('22:30:00'), 22 * 60 + 30);
    expect(parseTimeOfDay('07:00'), 7 * 60);
    expect(parseTimeOfDay('25:00:00'), isNull);
    expect(parseTimeOfDay(null), isNull);
    expect(formatTimeOfDay(7 * 60 + 5), '07:05:00');
  });

  test('preferences and notifications from JSON', () {
    final p = NotificationPrefs.fromJson({
      'notify_private_messages': true,
      'notify_group_messages': false,
      'show_message_preview': false,
      'quiet_hours_start': '22:00:00',
      'quiet_hours_end': '07:00:00',
    });
    expect(p.groupMessages, isFalse);
    expect(p.showPreview, isFalse, reason: 'lock-screen privacy default');
    expect(p.quietHoursEnabled, isTrue);
    expect(const NotificationPrefs().quietHoursEnabled, isFalse);

    final n = AppNotification.fromJson({
      'id': 'n1',
      'type': 'private_message',
      'title': 'FamilySync',
      'body': 'Mesej baharu daripada Aminah',
      'data': {'route': '/chat/$uuid'},
      'read_at': null,
      'created_at': '2026-11-23T01:00:00Z',
    });
    expect(n.isRead, isFalse);
    expect(n.route, '/chat/$uuid');
  });
}
