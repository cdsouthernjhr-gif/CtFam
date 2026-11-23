import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../family/domain/family_models.dart';
import '../domain/calendar_models.dart';

String eventCategoryLabel(AppLocalizations l, EventCategory c) => switch (c) {
  EventCategory.family => l.evCatFamily,
  EventCategory.birthday => l.evCatBirthday,
  EventCategory.school => l.catSchool,
  EventCategory.appointment => l.evCatAppointment,
  EventCategory.holiday => l.evCatHoliday,
  EventCategory.religious => l.evCatReligious,
  EventCategory.work => l.evCatWork,
  EventCategory.other => l.evCatOther,
};

String eventRecurrenceLabel(AppLocalizations l, EventRecurrence r) => switch (r) {
  EventRecurrence.none => l.repeatNone,
  EventRecurrence.daily => l.repeatDaily,
  EventRecurrence.weekly => l.repeatWeekly,
  EventRecurrence.monthly => l.repeatMonthly,
  EventRecurrence.yearly => l.repeatYearly,
};

String rsvpLabel(AppLocalizations l, Rsvp r) => switch (r) {
  Rsvp.pending => l.rsvpPending,
  Rsvp.going => l.rsvpGoing,
  Rsvp.maybe => l.rsvpMaybe,
  Rsvp.declined => l.rsvpDeclined,
};

IconData rsvpIcon(Rsvp r) => switch (r) {
  Rsvp.pending => Icons.help_outline,
  Rsvp.going => Icons.check_circle,
  Rsvp.maybe => Icons.help,
  Rsvp.declined => Icons.cancel_outlined,
};

String reminderLabel(AppLocalizations l, int minutes) {
  if (minutes == 0) return l.reminderAtStart;
  if (minutes % 10080 == 0) return l.reminderWeeks(minutes ~/ 10080);
  if (minutes % 1440 == 0) return l.reminderDays(minutes ~/ 1440);
  if (minutes % 60 == 0) return l.reminderHours(minutes ~/ 60);
  return l.reminderMinutes(minutes);
}

/// "09:00 – 10:30", "Sepanjang hari", or with dates for multi-day occurrences.
String occurrenceTimeLabel(AppLocalizations l, EventOccurrence o) {
  final loc = l.localeName;
  if (o.event.allDay) {
    if (!o.spansMultipleDays) return l.eventAllDay;
    final last = o.end.subtract(const Duration(days: 1));
    return '${DateFormat.MMMd(loc).format(o.start)} – ${DateFormat.MMMd(loc).format(last)}';
  }
  if (o.spansMultipleDays) {
    final f = DateFormat.MMMd(loc).add_Hm();
    return '${f.format(o.start)} – ${f.format(o.end)}';
  }
  final hm = DateFormat.Hm(loc);
  return o.end.isAfter(o.start) ? '${hm.format(o.start)} – ${hm.format(o.end)}' : hm.format(o.start);
}

/// Display name for a participant, preferring the family nickname.
String participantName(EventParticipant p, List<FamilyMember> members) {
  for (final m in members) {
    if (m.userId == p.userId && m.displayName.isNotEmpty) return m.displayName;
  }
  return p.displayName ?? '?';
}

class EventOccurrenceTile extends StatelessWidget {
  const EventOccurrenceTile({
    required this.occurrence,
    required this.myUserId,
    required this.onTap,
    this.showDate = false,
    super.key,
  });

  final EventOccurrence occurrence;

  /// Prefix the time with the date (lists spanning several days).
  final bool showDate;
  final String? myUserId;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final e = occurrence.event;
    final mine = e.participant(myUserId);
    final subtitle = [
      if (showDate) DateFormat.MMMEd(l.localeName).format(occurrence.start),
      occurrenceTimeLabel(l, occurrence),
      if (e.location != null) e.location!,
    ].join(' · ');
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: e.category.color.withValues(alpha: 0.15),
        foregroundColor: e.category.color,
        child: Icon(e.category.icon, size: 20),
      ),
      title: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (e.isRecurring) Icon(Icons.repeat, size: 16, color: Theme.of(context).colorScheme.outline),
          if (mine != null && mine.rsvp != Rsvp.pending) ...[
            const SizedBox(width: 4),
            Icon(
              rsvpIcon(mine.rsvp),
              size: 18,
              semanticLabel: rsvpLabel(l, mine.rsvp),
              color: mine.rsvp == Rsvp.going ? Colors.green.shade600 : Theme.of(context).colorScheme.outline,
            ),
          ],
        ],
      ),
    );
  }
}
