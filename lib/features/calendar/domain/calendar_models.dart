import 'package:material_ui/material_ui.dart';

DateTime? _date(Object? v) => v == null ? null : DateTime.parse(v as String).toLocal();

enum EventCategory {
  family('family', Icons.family_restroom_rounded, Color(0xFF3F6FD8)),
  birthday('birthday', Icons.cake_outlined, Color(0xFFD84F8A)),
  school('school', Icons.school_outlined, Color(0xFFE08A1E)),
  appointment('appointment', Icons.medical_services_outlined, Color(0xFF2E9E8F)),
  holiday('holiday', Icons.beach_access_outlined, Color(0xFF8E5BD0)),
  religious('religious', Icons.mosque_outlined, Color(0xFF3A8D3F)),
  work('work', Icons.work_outline, Color(0xFF5D6B7A)),
  other('other', Icons.event_outlined, Color(0xFF8A7356));

  const EventCategory(this.key, this.icon, this.color);

  final String key;
  final IconData icon;
  final Color color;

  static EventCategory parse(String? v) => values.firstWhere((c) => c.key == v, orElse: () => other);
}

enum EventRecurrence {
  none,
  daily,
  weekly,
  monthly,
  yearly;

  static EventRecurrence parse(String? v) => values.firstWhere((r) => r.name == v, orElse: () => none);
}

enum Rsvp {
  pending,
  going,
  maybe,
  declined;

  static Rsvp parse(String? v) => values.firstWhere((r) => r.name == v, orElse: () => pending);
}

/// Reminder choices offered in the UI (minutes before the start).
const reminderChoices = [0, 10, 30, 60, 1440, 10080];

class EventParticipant {
  const EventParticipant({required this.userId, required this.rsvp, this.displayName, this.avatarPath});

  factory EventParticipant.fromJson(Map<String, dynamic> j) {
    final p = j['profiles'];
    return EventParticipant(
      userId: j['user_id'] as String,
      rsvp: Rsvp.parse(j['rsvp'] as String?),
      displayName: p is Map<String, dynamic> ? p['display_name'] as String? : null,
      avatarPath: p is Map<String, dynamic> ? p['avatar_path'] as String? : null,
    );
  }

  final String userId;
  final Rsvp rsvp;
  final String? displayName;
  final String? avatarPath;
}

class FamilyEvent {
  const FamilyEvent({
    required this.id,
    required this.familyId,
    required this.title,
    required this.startsAt,
    required this.endsAt,
    this.description,
    this.location,
    this.category = EventCategory.family,
    this.allDay = false,
    this.timezone = 'Asia/Kuala_Lumpur',
    this.recurrence = EventRecurrence.none,
    this.recurrenceUntil,
    this.participantsOnly = false,
    this.defaultReminders = const [],
    this.createdBy,
    this.revision = 1,
    this.deletedAt,
    this.participants = const [],
  });

  factory FamilyEvent.fromJson(Map<String, dynamic> j) => FamilyEvent(
    id: j['id'] as String,
    familyId: j['family_id'] as String,
    title: j['title'] as String,
    description: j['description'] as String?,
    location: j['location'] as String?,
    category: EventCategory.parse(j['category'] as String?),
    allDay: (j['all_day'] as bool?) ?? false,
    startsAt: _date(j['starts_at'])!,
    endsAt: _date(j['ends_at'])!,
    timezone: (j['timezone'] as String?) ?? 'Asia/Kuala_Lumpur',
    recurrence: EventRecurrence.parse(j['recurrence'] as String?),
    recurrenceUntil: j['recurrence_until'] == null ? null : DateTime.parse(j['recurrence_until'] as String),
    participantsOnly: j['visibility'] == 'participants',
    defaultReminders: [for (final m in (j['default_reminders'] as List?) ?? const []) (m as num).toInt()],
    createdBy: j['created_by'] as String?,
    revision: (j['revision'] as num?)?.toInt() ?? 1,
    deletedAt: _date(j['deleted_at']),
    participants: [
      for (final p in (j['event_participants'] as List?) ?? const [])
        EventParticipant.fromJson(p as Map<String, dynamic>),
    ],
  );

  static const select =
      'id, family_id, title, description, location, category, all_day, starts_at, ends_at, timezone, recurrence, '
      'recurrence_until, visibility, default_reminders, created_by, revision, deleted_at, '
      'event_participants(user_id, rsvp, profiles!event_participants_user_id_fkey(display_name, avatar_path))';

  final String id;
  final String familyId;
  final String title;
  final String? description;
  final String? location;
  final EventCategory category;
  final bool allDay;
  final DateTime startsAt;
  final DateTime endsAt;
  final String timezone;
  final EventRecurrence recurrence;
  final DateTime? recurrenceUntil;
  final bool participantsOnly;
  final List<int> defaultReminders;
  final String? createdBy;
  final int revision;
  final DateTime? deletedAt;
  final List<EventParticipant> participants;

  bool get isRecurring => recurrence != EventRecurrence.none;

  EventParticipant? participant(String? userId) {
    for (final p in participants) {
      if (p.userId == userId) return p;
    }
    return null;
  }

  int countRsvp(Rsvp r) => participants.where((p) => p.rsvp == r).length;

  /// Copy with [userId]'s RSVP replaced (added when not yet a participant).
  FamilyEvent withRsvp(String userId, Rsvp rsvp) {
    final me = participant(userId);
    final next = [
      for (final p in participants)
        p.userId == userId
            ? EventParticipant(userId: userId, rsvp: rsvp, displayName: p.displayName, avatarPath: p.avatarPath)
            : p,
      if (me == null) EventParticipant(userId: userId, rsvp: rsvp),
    ];
    return FamilyEvent(
      id: id,
      familyId: familyId,
      title: title,
      startsAt: startsAt,
      endsAt: endsAt,
      description: description,
      location: location,
      category: category,
      allDay: allDay,
      timezone: timezone,
      recurrence: recurrence,
      recurrenceUntil: recurrenceUntil,
      participantsOnly: participantsOnly,
      defaultReminders: defaultReminders,
      createdBy: createdBy,
      revision: revision,
      deletedAt: deletedAt,
      participants: next,
    );
  }
}

/// One concrete occurrence of an event (recurring events have many).
class EventOccurrence {
  const EventOccurrence({required this.event, required this.start, required this.end});

  final FamilyEvent event;
  final DateTime start;
  final DateTime end;

  /// True when the occurrence covers any part of the local calendar [day].
  bool coversDay(DateTime day) {
    final dayStart = DateTime(day.year, day.month, day.day);
    final dayEnd = DateTime(day.year, day.month, day.day + 1);
    if (!end.isAfter(start)) return !start.isBefore(dayStart) && start.isBefore(dayEnd);
    // All-day events end at midnight of the following day (exclusive).
    return start.isBefore(dayEnd) && end.isAfter(dayStart);
  }

  bool get spansMultipleDays {
    final s = DateTime(start.year, start.month, start.day);
    final lastInstant = end.isAfter(start) ? end.subtract(const Duration(microseconds: 1)) : end;
    final e = DateTime(lastInstant.year, lastInstant.month, lastInstant.day);
    return e.isAfter(s);
  }
}

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

/// First day shown in a month grid (weeks start on Monday): up to 6 weeks.
DateTime gridStart(DateTime month) {
  final first = DateTime(month.year, month.month);
  return DateTime(first.year, first.month, first.day - (first.weekday - DateTime.monday));
}

/// The 42 days of the month grid for [month].
List<DateTime> monthGridDays(DateTime month) {
  final start = gridStart(month);
  return [for (var i = 0; i < 42; i++) DateTime(start.year, start.month, start.day + i)];
}

/// Occurrences covering [day], all-day first, then by start time.
List<EventOccurrence> occurrencesOn(Iterable<EventOccurrence> all, DateTime day) =>
    all.where((o) => o.coversDay(day)).toList()..sort((a, b) {
      if (a.event.allDay != b.event.allDay) return a.event.allDay ? -1 : 1;
      final c = a.start.compareTo(b.start);
      return c != 0 ? c : a.event.title.compareTo(b.event.title);
    });

/// Groups occurrences by the local start date (agenda view). Multi-day
/// occurrences appear on each day they cover, within [from, to).
Map<DateTime, List<EventOccurrence>> groupByDay(Iterable<EventOccurrence> all, DateTime from, DateTime to) {
  final out = <DateTime, List<EventOccurrence>>{};
  for (var d = dateOnly(from); d.isBefore(to); d = DateTime(d.year, d.month, d.day + 1)) {
    final list = occurrencesOn(all, d);
    if (list.isNotEmpty) out[d] = list;
  }
  return out;
}

/// Validates the event times entered in the form; returns null when valid.
String? validateEventTimes({required DateTime start, required DateTime end, required bool allDay}) {
  if (allDay) return dateOnly(end).isBefore(dateOnly(start)) ? 'end_before_start' : null;
  if (end.isBefore(start)) return 'end_before_start';
  if (end.difference(start) > const Duration(days: 366)) return 'too_long';
  return null;
}

/// Converts form values to the instants stored on the server. All-day events
/// run from local midnight of the first day to local midnight after the last.
(DateTime, DateTime) eventInstants({required DateTime start, required DateTime end, required bool allDay}) {
  if (!allDay) return (start, end);
  final s = dateOnly(start);
  final e = dateOnly(end);
  return (s, DateTime(e.year, e.month, e.day + 1));
}
