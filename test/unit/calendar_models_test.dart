import 'package:familysync/features/calendar/domain/calendar_models.dart';
import 'package:familysync/features/calendar/presentation/calendar_ui.dart';
import 'package:familysync/features/calendar/presentation/event_detail_screen.dart';
import 'package:familysync/features/family/domain/family_models.dart';
import 'package:familysync/features/notifications/domain/notification_models.dart';
import 'package:familysync/l10n/generated/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

FamilyEvent _ev(String id, {bool allDay = false, String title = 'Acara', String? createdBy}) => FamilyEvent(
  id: id,
  familyId: 'F1',
  title: title,
  startsAt: DateTime(2027, 1, 10, 9),
  endsAt: DateTime(2027, 1, 10, 10),
  allDay: allDay,
  createdBy: createdBy,
);

void main() {
  test('month grid: 42 days, Monday first, covers the whole month', () {
    final days = monthGridDays(DateTime(2026, 11));
    expect(days, hasLength(42));
    expect(days.first, DateTime(2026, 10, 26));
    expect(days.every((d) => days.indexOf(d) % 7 != 0 || d.weekday == DateTime.monday), isTrue);
    expect(days.where((d) => d.month == 11), hasLength(30));
  });

  test('coversDay: timed, all-day (exclusive end) and multi-day', () {
    final timed = EventOccurrence(event: _ev('a'), start: DateTime(2027, 1, 10, 23), end: DateTime(2027, 1, 11, 1));
    expect(timed.coversDay(DateTime(2027, 1, 10)), isTrue);
    expect(timed.coversDay(DateTime(2027, 1, 11)), isTrue, reason: 'crosses midnight');
    expect(timed.spansMultipleDays, isTrue);

    final allDay = EventOccurrence(
      event: _ev('b', allDay: true),
      start: DateTime(2027, 1, 10),
      end: DateTime(2027, 1, 11),
    );
    expect(allDay.coversDay(DateTime(2027, 1, 10)), isTrue);
    expect(allDay.coversDay(DateTime(2027, 1, 11)), isFalse, reason: 'end is exclusive');
    expect(allDay.spansMultipleDays, isFalse);

    final instant = EventOccurrence(event: _ev('c'), start: DateTime(2027, 1, 10, 8), end: DateTime(2027, 1, 10, 8));
    expect(instant.coversDay(DateTime(2027, 1, 10)), isTrue);
    expect(instant.coversDay(DateTime(2027, 1, 9)), isFalse);
  });

  test('occurrencesOn sorts all-day first, then by time; groupByDay repeats multi-day events', () {
    final morning = EventOccurrence(
      event: _ev('m', title: 'Pagi'),
      start: DateTime(2027, 1, 10, 8),
      end: DateTime(2027, 1, 10, 9),
    );
    final noon = EventOccurrence(
      event: _ev('n', title: 'Tengah hari'),
      start: DateTime(2027, 1, 10, 12),
      end: DateTime(2027, 1, 10, 13),
    );
    final trip = EventOccurrence(
      event: _ev('t', allDay: true, title: 'Bercuti'),
      start: DateTime(2027, 1, 10),
      end: DateTime(2027, 1, 13),
    );
    expect(occurrencesOn([noon, morning, trip], DateTime(2027, 1, 10)).map((o) => o.event.title), [
      'Bercuti',
      'Pagi',
      'Tengah hari',
    ]);
    final groups = groupByDay([noon, morning, trip], DateTime(2027, 1, 9), DateTime(2027, 1, 20));
    expect(groups.keys, [DateTime(2027, 1, 10), DateTime(2027, 1, 11), DateTime(2027, 1, 12)]);
  });

  test('validation and all-day instants', () {
    final s = DateTime(2027, 1, 10, 9);
    expect(
      validateEventTimes(start: s, end: s.subtract(const Duration(minutes: 1)), allDay: false),
      'end_before_start',
    );
    expect(validateEventTimes(start: s, end: s.add(const Duration(days: 400)), allDay: false), 'too_long');
    expect(validateEventTimes(start: s, end: s, allDay: false), isNull);
    expect(
      validateEventTimes(start: s, end: DateTime(2027, 1, 10, 1), allDay: true),
      isNull,
      reason: 'same day',
    );
    final (a, b) = eventInstants(start: DateTime(2027, 1, 10, 15), end: DateTime(2027, 1, 12, 8), allDay: true);
    expect(a, DateTime(2027, 1, 10));
    expect(b, DateTime(2027, 1, 13));
  });

  test('FamilyEvent.fromJson', () {
    final e = FamilyEvent.fromJson({
      'id': 'e1',
      'family_id': 'F1',
      'title': 'Kenduri',
      'category': 'birthday',
      'all_day': false,
      'starts_at': '2027-01-10T04:00:00+00:00',
      'ends_at': '2027-01-10T08:00:00+00:00',
      'timezone': 'Asia/Kuala_Lumpur',
      'recurrence': 'yearly',
      'recurrence_until': '2030-01-10',
      'visibility': 'participants',
      'default_reminders': [60, 1440],
      'created_by': 'u1',
      'revision': 3,
      'event_participants': [
        {
          'user_id': 'u1',
          'rsvp': 'going',
          'profiles': {'display_name': 'Aminah'},
        },
        {'user_id': 'u2', 'rsvp': 'pending', 'profiles': null},
      ],
    });
    expect(e.category, EventCategory.birthday);
    expect(e.recurrence, EventRecurrence.yearly);
    expect(e.recurrenceUntil, DateTime(2030, 1, 10));
    expect(e.participantsOnly, isTrue);
    expect(e.defaultReminders, [60, 1440]);
    expect(e.startsAt, DateTime.utc(2027, 1, 10, 4).toLocal());
    expect(e.participant('u1')!.rsvp, Rsvp.going);
    expect(e.countRsvp(Rsvp.pending), 1);
    expect(EventCategory.parse('nonsense'), EventCategory.other);
  });

  test('manage permission: creator or owner/admin', () {
    final e = _ev('x', createdBy: 'u1');
    expect(canManageEvent(e, userId: 'u1', role: FamilyRole.member), isTrue);
    expect(canManageEvent(e, userId: 'u2', role: FamilyRole.admin), isTrue);
    expect(canManageEvent(e, userId: 'u2', role: FamilyRole.moderator), isFalse);
    expect(canManageEvent(e, userId: 'u2', role: FamilyRole.member), isFalse);
  });

  test('reminder labels (BM / EN)', () {
    final ms = lookupAppLocalizations(const Locale('ms'));
    final en = lookupAppLocalizations(const Locale('en'));
    expect(reminderLabel(ms, 0), 'Pada masa mula');
    expect(reminderLabel(ms, 30), '30 minit sebelum');
    expect(reminderLabel(ms, 60), '1 jam sebelum');
    expect(reminderLabel(ms, 1440), '1 hari sebelum');
    expect(reminderLabel(ms, 10080), '1 minggu sebelum');
    expect(reminderLabel(en, 120), '2 hours before');
    expect(reminderLabel(en, 1440), '1 day before');
  });

  test('notification taps may open a calendar event, nothing else', () {
    const id = '0b9f3c9e-3f5e-4f0b-9d55-3c1c2b8d7e11';
    expect(safeNotificationRoute('/calendar/$id'), '/calendar/$id');
    expect(safeNotificationRoute('/calendar/$id/edit'), isNull);
    expect(safeNotificationRoute('/calendar/new'), isNull);
  });
}
