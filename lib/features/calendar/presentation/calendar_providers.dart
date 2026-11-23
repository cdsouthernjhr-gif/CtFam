import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/offline/sync_engine.dart';
import '../../../shared/providers/session_controller.dart';
import '../data/calendar_repository.dart';
import '../domain/calendar_models.dart';

const _uuid = Uuid();
String newEventId() => _uuid.v4();

/// Debounced tick for family calendar changes (Realtime). Subscribed only
/// while watched; the channel is removed on dispose.
final calendarTickProvider = StreamProvider.autoDispose.family<int, String>((ref, familyId) {
  final controller = StreamController<int>();
  var tick = 0;
  Timer? debounce;
  final sub = ref.watch(calendarRepositoryProvider).watchFamily(familyId).listen((_) {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 300), () => controller.add(++tick));
  });
  ref.onDispose(() {
    debounce?.cancel();
    sub.cancel();
    controller.close();
  });
  return controller.stream;
});

typedef CalendarRange = ({String familyId, DateTime from, DateTime to});

/// Occurrences in a range; refetched on every Realtime change.
final occurrencesProvider = FutureProvider.autoDispose.family<List<EventOccurrence>, CalendarRange>((ref, r) {
  ref.watch(calendarTickProvider(r.familyId));
  return ref.watch(calendarRepositoryProvider).occurrences(r.familyId, r.from, r.to);
});

/// The 6-week grid range for [month].
CalendarRange monthRange(String familyId, DateTime month) {
  final start = gridStart(month);
  return (familyId: familyId, from: start, to: DateTime(start.year, start.month, start.day + 42));
}

/// Agenda / dashboard range: today 00:00 for [days] days.
CalendarRange upcomingRange(String familyId, {int days = 60, DateTime? now}) {
  final today = dateOnly(now ?? DateTime.now());
  return (familyId: familyId, from: today, to: DateTime(today.year, today.month, today.day + days));
}

class CalendarViewState {
  const CalendarViewState({required this.month, required this.selected, this.agenda = false});

  final DateTime month;
  final DateTime selected;
  final bool agenda;

  CalendarViewState copyWith({DateTime? month, DateTime? selected, bool? agenda}) =>
      CalendarViewState(month: month ?? this.month, selected: selected ?? this.selected, agenda: agenda ?? this.agenda);
}

final calendarViewProvider = NotifierProvider<CalendarViewController, CalendarViewState>(CalendarViewController.new);

class CalendarViewController extends Notifier<CalendarViewState> {
  @override
  CalendarViewState build() {
    final today = dateOnly(DateTime.now());
    return CalendarViewState(month: DateTime(today.year, today.month), selected: today);
  }

  void select(DateTime day) {
    final d = dateOnly(day);
    state = state.copyWith(selected: d, month: DateTime(d.year, d.month));
  }

  void shiftMonth(int delta) {
    final m = DateTime(state.month.year, state.month.month + delta);
    final keepDay = state.selected.day.clamp(1, DateTime(m.year, m.month + 1, 0).day);
    state = state.copyWith(month: m, selected: DateTime(m.year, m.month, keepDay));
  }

  void today() => select(DateTime.now());

  void setAgenda(bool agenda) => state = state.copyWith(agenda: agenda);
}

/// One event with live updates (detail screen). An RSVP made offline and
/// still queued is shown in place of the server value.
final eventProvider = FutureProvider.autoDispose.family<FamilyEvent?, ({String familyId, String eventId})>((
  ref,
  k,
) async {
  ref.watch(calendarTickProvider(k.familyId));
  final queuedRsvp = ref.watch(
    syncEngineProvider.select((s) {
      String? last;
      for (final o in s.ops) {
        if (o.kind == OutboxKind.eventRsvp.key && o.entityId == k.eventId) last = opParams(o)['p_rsvp'] as String?;
      }
      return last;
    }),
  );
  final event = await ref.watch(calendarRepositoryProvider).event(k.eventId);
  final me = ref.read(currentUserIdProvider);
  if (event == null || queuedRsvp == null || me == null) return event;
  return event.withRsvp(me, Rsvp.parse(queuedRsvp));
});

final myRemindersProvider = FutureProvider.autoDispose.family<List<int>, String>(
  (ref, eventId) => ref.watch(calendarRepositoryProvider).myReminders(eventId),
);
