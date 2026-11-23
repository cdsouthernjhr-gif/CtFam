import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/offline/offline_store.dart';
import '../../../shared/providers/supabase_providers.dart';
import '../domain/calendar_models.dart';

final calendarRepositoryProvider = Provider<CalendarRepository>(
  (ref) => CalendarRepository(ref.watch(supabaseClientProvider), offline: ref.watch(offlineStoreProvider)),
);

class CalendarRepository {
  CalendarRepository(this._client, {this._offline});

  final SupabaseClient _client;
  final OfflineStore? _offline;

  Future<Object?> _cached(String key, Future<Object?> Function() fetch) {
    final store = _offline;
    return store == null ? fetch() : store.value(key, fetch);
  }

  String? _timezone;

  String? get _uid => _client.auth.currentUser?.id;

  /// Occurrences of visible events in [from, to). The server expands
  /// recurrences, so client and reminders always agree.
  Future<List<EventOccurrence>> occurrences(String familyId, DateTime from, DateTime to) => _guard(() async {
    final key = 'calendar:$familyId:${from.toUtc().toIso8601String()}:${to.toUtc().toIso8601String()}';
    final data = await _cached(key, () async {
      final rows = await _client.rpc<List<dynamic>>(
        'calendar_occurrences',
        params: {
          'p_family_id': familyId,
          'p_from': from.toUtc().toIso8601String(),
          'p_to': to.toUtc().toIso8601String(),
        },
      );
      final ids = {for (final r in rows) (r as Map<String, dynamic>)['event_id'] as String};
      final events = ids.isEmpty
          ? const <Map<String, dynamic>>[]
          : await _client.from('family_events').select(FamilyEvent.select).inFilter('id', ids.toList());
      return {'occurrences': rows, 'events': events};
    });
    final map = Map<String, dynamic>.from(data! as Map);
    final byId = {
      for (final e in (map['events'] as List).map((r) => FamilyEvent.fromJson(Map<String, dynamic>.from(r as Map))))
        e.id: e,
    };
    return [
      for (final r in (map['occurrences'] as List).map((x) => Map<String, dynamic>.from(x as Map)))
        if (byId[r['event_id']] case final e?)
          EventOccurrence(
            event: e,
            start: DateTime.parse(r['occurrence_start'] as String).toLocal(),
            end: DateTime.parse(r['occurrence_end'] as String).toLocal(),
          ),
    ];
  });

  Future<FamilyEvent?> event(String id) => _guard(() async {
    final row = await _cached(
      'calendar:event:$id',
      () => _client.from('family_events').select(FamilyEvent.select).eq('id', id).maybeSingle(),
    );
    return row == null ? null : FamilyEvent.fromJson(Map<String, dynamic>.from(row as Map));
  });

  /// The signed-in user's own reminders for [eventId] (RLS: own rows only).
  Future<List<int>> myReminders(String eventId) => _guard(() async {
    final rows = await _cached(
      'calendar:reminders:$eventId',
      () => _client.from('event_reminders').select('minutes_before').eq('event_id', eventId).order('minutes_before'),
    );
    return [for (final r in rows! as List) ((r as Map)['minutes_before'] as num).toInt()];
  });

  /// IANA time zone used for recurrence and reminder texts (user preference).
  Future<String> timezone() async {
    if (_timezone != null) return _timezone!;
    try {
      final uid = _uid;
      final row = uid == null
          ? null
          : await _client.from('user_preferences').select('timezone').eq('user_id', uid).maybeSingle();
      _timezone = (row?['timezone'] as String?) ?? 'Asia/Kuala_Lumpur';
    } catch (_) {
      _timezone = 'Asia/Kuala_Lumpur';
    }
    return _timezone!;
  }

  /// Idempotent create (client UUID) or revision-checked update.
  /// [participantIds] / [reminderMinutes] null = unchanged.
  Future<FamilyEvent> upsert({
    required String id,
    required String familyId,
    required String title,
    required DateTime startsAt,
    required DateTime endsAt,
    required bool allDay,
    String? description,
    String? location,
    EventCategory category = EventCategory.family,
    EventRecurrence recurrence = EventRecurrence.none,
    DateTime? recurrenceUntil,
    bool participantsOnly = false,
    List<String>? participantIds,
    List<int>? reminderMinutes,
    int? expectedRevision,
  }) => _guard(() async {
    final tz = await timezone();
    await _client.rpc<Map<String, dynamic>>(
      'upsert_family_event',
      params: {
        'p_id': id,
        'p_family_id': familyId,
        'p_title': title.trim(),
        'p_starts_at': startsAt.toUtc().toIso8601String(),
        'p_ends_at': endsAt.toUtc().toIso8601String(),
        'p_all_day': allDay,
        'p_timezone': tz,
        'p_description': description?.trim(),
        'p_location': location?.trim(),
        'p_category': category.key,
        'p_recurrence': recurrence.name,
        'p_recurrence_until': recurrence == EventRecurrence.none || recurrenceUntil == null
            ? null
            : '${recurrenceUntil.year.toString().padLeft(4, '0')}-'
                  '${recurrenceUntil.month.toString().padLeft(2, '0')}-'
                  '${recurrenceUntil.day.toString().padLeft(2, '0')}',
        'p_visibility': participantsOnly ? 'participants' : 'family',
        'p_participant_ids': participantIds,
        'p_reminder_minutes': reminderMinutes,
        'p_expected_revision': expectedRevision,
      },
    );
    return (await event(id))!;
  });

  Future<void> delete(String id) => _guard(() => _client.rpc<void>('delete_family_event', params: {'p_id': id}));

  Future<void> cancelOccurrence(String id, DateTime occurrenceStart) => _guard(
    () => _client.rpc<Map<String, dynamic>>(
      'cancel_event_occurrence',
      params: {'p_id': id, 'p_occurrence_start': occurrenceStart.toUtc().toIso8601String()},
    ),
  );

  Future<void> setRsvp(String eventId, Rsvp rsvp) =>
      _guard(() => _client.rpc<Map<String, dynamic>>('set_event_rsvp', params: rsvpParams(eventId, rsvp)));

  static Map<String, dynamic> rsvpParams(String eventId, Rsvp rsvp) => {'p_event_id': eventId, 'p_rsvp': rsvp.name};

  Future<List<int>> setReminders(String eventId, List<int> minutes) => _guard(() async {
    final res = await _client.rpc<List<dynamic>>(
      'set_event_reminders',
      params: {'p_event_id': eventId, 'p_minutes': minutes},
    );
    return [for (final m in res) (m as num).toInt()];
  });

  /// Family calendar changes on channel `calendar:{familyId}` (RLS-filtered).
  /// Emits after every change and after (re)subscribing (reconcile by refetch).
  Stream<void> watchFamily(String familyId) {
    late final RealtimeChannel channel;
    final controller = StreamController<void>.broadcast();
    controller.onListen = () {
      channel = _client.channel('calendar:$familyId');
      for (final table in ['family_events', 'event_participants']) {
        channel.onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: table,
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'family_id', value: familyId),
          callback: (_) => controller.add(null),
        );
      }
      channel.subscribe((status, _) {
        if (status == RealtimeSubscribeStatus.subscribed) controller.add(null);
      });
    };
    controller.onCancel = () async {
      await _client.removeChannel(channel);
      await controller.close();
    };
    return controller.stream;
  }

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }
}
