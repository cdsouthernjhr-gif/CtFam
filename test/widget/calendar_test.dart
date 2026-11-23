import 'package:familysync/features/calendar/data/calendar_repository.dart';
import 'package:familysync/features/calendar/domain/calendar_models.dart';
import 'package:familysync/features/calendar/presentation/calendar_screen.dart';
import 'package:familysync/features/calendar/presentation/event_detail_screen.dart';
import 'package:familysync/features/calendar/presentation/event_form_screen.dart';
import 'package:familysync/features/family/data/family_repository.dart';
import 'package:familysync/features/family/domain/family_models.dart';
import 'package:familysync/features/notifications/data/notification_repository.dart';
import 'package:familysync/shared/providers/session_controller.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/pump_app.dart';

class _MockCalRepo extends Mock implements CalendarRepository {}

class _MockFamilyRepo extends Mock implements FamilyRepository {}

class _MockNotifRepo extends Mock implements NotificationRepository {}

FamilyEvent _event({
  String id = 'e1',
  String title = 'Kenduri',
  String createdBy = 'u2',
  required DateTime start,
  List<EventParticipant> participants = const [],
}) => FamilyEvent(
  id: id,
  familyId: 'F1',
  title: title,
  startsAt: start,
  endsAt: start.add(const Duration(hours: 2)),
  location: 'Rumah Tok',
  createdBy: createdBy,
  participants: participants,
);

void main() {
  late _MockCalRepo repo;
  late _MockFamilyRepo familyRepo;
  late _MockNotifRepo notifRepo;
  final today = dateOnly(DateTime.now());

  setUpAll(() {
    registerFallbackValue(DateTime(2000));
    registerFallbackValue(Rsvp.going);
    registerFallbackValue(EventCategory.family);
    registerFallbackValue(EventRecurrence.none);
  });

  setUp(() {
    repo = _MockCalRepo();
    familyRepo = _MockFamilyRepo();
    notifRepo = _MockNotifRepo();
    when(() => repo.watchFamily(any())).thenAnswer((_) => const Stream.empty());
    when(() => notifRepo.watchInbox()).thenAnswer((_) => const Stream.empty());
    when(() => notifRepo.unreadCount()).thenAnswer((_) async => 0);
    when(() => familyRepo.watchFamily(any())).thenAnswer((_) => const Stream.empty());
    when(() => familyRepo.members('F1')).thenAnswer(
      (_) async => const [
        FamilyMember(
          id: 'm1',
          familyId: 'F1',
          userId: 'u1',
          role: FamilyRole.member,
          status: MemberStatus.active,
          profile: Profile(id: 'u1', displayName: 'Aminah'),
        ),
        FamilyMember(
          id: 'm2',
          familyId: 'F1',
          userId: 'u2',
          role: FamilyRole.owner,
          status: MemberStatus.active,
          profile: Profile(id: 'u2', displayName: 'Badrul'),
        ),
      ],
    );
  });

  void tallScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  List<Override> overrides({FamilyRole role = FamilyRole.member}) => [
    calendarRepositoryProvider.overrideWithValue(repo),
    familyRepositoryProvider.overrideWithValue(familyRepo),
    notificationRepositoryProvider.overrideWithValue(notifRepo),
    sessionControllerProvider.overrideWith(
      () => FixedSession(
        SessionState(
          status: SessionStatus.ready,
          user: fakeUser('u1'),
          activeFamilyId: 'F1',
          memberships: [
            MyMembership(
              familyId: 'F1',
              role: role,
              status: MemberStatus.active,
              family: const Family(id: 'F1', name: 'Keluarga'),
            ),
          ],
        ),
      ),
    ),
  ];

  testWidgets('month view lists the selected day, agenda groups upcoming events', (tester) async {
    final start = today.add(const Duration(hours: 20));
    final ev = _event(start: start);
    when(() => repo.occurrences('F1', any(), any()))
        .thenAnswer((_) async => [EventOccurrence(event: ev, start: start, end: start.add(const Duration(hours: 2)))]);
    await pumpLocalized(tester, const CalendarScreen(), overrides: overrides());

    expect(find.text('Kenduri'), findsOneWidget);
    expect(find.textContaining('Rumah Tok'), findsOneWidget);

    // Another day without events
    final other = today.day == 15 ? 16 : 15;
    await tester.tap(find.text('$other').first);
    await tester.pumpAndSettle();
    expect(find.text('Tiada acara pada hari ini.'), findsOneWidget);

    await tester.tap(find.byTooltip('Paparan agenda'));
    await tester.pumpAndSettle();
    expect(find.text('Kenduri'), findsOneWidget);
  });

  testWidgets('detail: RSVP and reminders; members cannot edit others\' events', (tester) async {
    tallScreen(tester);
    final start = today.add(const Duration(days: 2, hours: 10));
    var ev = _event(
      start: start,
      participants: const [
        EventParticipant(userId: 'u2', rsvp: Rsvp.going, displayName: 'Badrul'),
        EventParticipant(userId: 'u1', rsvp: Rsvp.pending, displayName: 'Aminah'),
      ],
    );
    when(() => repo.event('e1')).thenAnswer((_) async => ev);
    when(() => repo.myReminders('e1')).thenAnswer((_) async => [30]);
    when(() => repo.setRsvp('e1', Rsvp.going)).thenAnswer((_) async {
      ev = _event(
        start: start,
        participants: const [
          EventParticipant(userId: 'u2', rsvp: Rsvp.going, displayName: 'Badrul'),
          EventParticipant(userId: 'u1', rsvp: Rsvp.going, displayName: 'Aminah'),
        ],
      );
    });
    when(() => repo.setReminders('e1', any())).thenAnswer((_) async => [30, 60]);

    await pumpLocalized(tester, const EventDetailScreen(eventId: 'e1'), overrides: overrides());
    expect(find.text('Kenduri'), findsOneWidget);
    expect(find.byTooltip('Edit acara'), findsNothing, reason: 'created by someone else; plain member');
    expect(find.textContaining('1 hadir'), findsOneWidget);

    await tester.tap(find.text('Hadir').first);
    await tester.pumpAndSettle();
    verify(() => repo.setRsvp('e1', Rsvp.going)).called(1);
    expect(find.textContaining('2 hadir'), findsOneWidget);

    await tester.ensureVisible(find.text('1 jam sebelum'));
    await tester.tap(find.text('1 jam sebelum'));
    await tester.pumpAndSettle();
    final captured = verify(() => repo.setReminders('e1', captureAny())).captured.single as List<int>;
    expect(captured..sort(), [30, 60]);
  });

  testWidgets('detail: owner/admin sees edit and delete', (tester) async {
    tallScreen(tester);
    when(() => repo.event('e1')).thenAnswer((_) async => _event(start: today.add(const Duration(days: 1))));
    when(() => repo.myReminders('e1')).thenAnswer((_) async => []);
    await pumpLocalized(
      tester,
      const EventDetailScreen(eventId: 'e1'),
      overrides: overrides(role: FamilyRole.admin),
    );
    expect(find.byTooltip('Edit acara'), findsOneWidget);
    expect(find.byTooltip('Padam'), findsOneWidget);
    expect(find.text('Jawab RSVP untuk menetapkan peringatan anda sendiri.'), findsOneWidget);
  });

  testWidgets('form: title required; save sends a client id, invitees and reminders', (tester) async {
    tallScreen(tester);
    when(
      () => repo.upsert(
        id: any(named: 'id'),
        familyId: any(named: 'familyId'),
        title: any(named: 'title'),
        startsAt: any(named: 'startsAt'),
        endsAt: any(named: 'endsAt'),
        allDay: any(named: 'allDay'),
        description: any(named: 'description'),
        location: any(named: 'location'),
        category: any(named: 'category'),
        recurrence: any(named: 'recurrence'),
        recurrenceUntil: any(named: 'recurrenceUntil'),
        participantsOnly: any(named: 'participantsOnly'),
        participantIds: any(named: 'participantIds'),
        reminderMinutes: any(named: 'reminderMinutes'),
        expectedRevision: any(named: 'expectedRevision'),
      ),
    ).thenAnswer((_) async => _event(start: today));
    await pumpLocalized(
      tester,
      EventFormScreen(initialDate: today.add(const Duration(days: 3))),
      overrides: overrides(),
    );

    await tester.tap(find.text('Simpan'));
    await tester.pumpAndSettle();
    expect(find.text('Ruangan ini wajib diisi'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).first, 'Hari jadi Tok');
    await tester.ensureVisible(find.text('Badrul'));
    await tester.tap(find.text('Badrul'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Simpan'));
    await tester.pumpAndSettle();

    final call = verify(
      () => repo.upsert(
        id: captureAny(named: 'id'),
        familyId: 'F1',
        title: 'Hari jadi Tok',
        startsAt: captureAny(named: 'startsAt'),
        endsAt: any(named: 'endsAt'),
        allDay: false,
        description: any(named: 'description'),
        location: any(named: 'location'),
        category: EventCategory.family,
        recurrence: EventRecurrence.none,
        recurrenceUntil: any(named: 'recurrenceUntil'),
        participantsOnly: false,
        participantIds: captureAny(named: 'participantIds'),
        reminderMinutes: captureAny(named: 'reminderMinutes'),
        expectedRevision: null,
      ),
    );
    call.called(1);
    final c = call.captured;
    expect((c[0] as String).length, 36, reason: 'client-generated UUID');
    expect(dateOnly(c[1] as DateTime), today.add(const Duration(days: 3)));
    expect(c[2], ['u2']);
    expect(c[3], [30]);
  });
}
