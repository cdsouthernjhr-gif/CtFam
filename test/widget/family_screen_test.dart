import 'package:familysync/features/family/data/family_repository.dart';
import 'package:familysync/features/family/domain/family_models.dart';
import 'package:familysync/features/family/presentation/family_screen.dart';
import 'package:familysync/shared/providers/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/pump_app.dart';

class _MockFamilyRepo extends Mock implements FamilyRepository {}

const _family = Family(id: 'f1', name: 'Keluarga Abdullah');

FamilyMember _member(String id, String name, FamilyRole role, {MemberStatus status = MemberStatus.active}) =>
    FamilyMember(
      id: 'm-$id',
      familyId: 'f1',
      userId: id,
      role: role,
      status: status,
      profile: Profile(id: id, displayName: name),
    );

void main() {
  late _MockFamilyRepo repo;

  setUp(() {
    repo = _MockFamilyRepo();
    when(() => repo.watchFamily(any())).thenAnswer((_) => const Stream.empty());
    when(() => repo.family('f1')).thenAnswer((_) async => _family);
    when(() => repo.members('f1')).thenAnswer(
      (_) async => [
        _member('a', 'Aminah', FamilyRole.owner),
        _member('b', 'Badrul', FamilyRole.member),
        _member('p', 'Puteri', FamilyRole.member, status: MemberStatus.pending),
      ],
    );
  });

  Future<void> pumpAs(WidgetTester tester, String userId, FamilyRole role) => pumpLocalized(
    tester,
    const FamilyScreen(),
    overrides: [
      familyRepositoryProvider.overrideWithValue(repo),
      sessionControllerProvider.overrideWith(
        () => FixedSession(
          SessionState(
            status: SessionStatus.ready,
            user: fakeUser(userId),
            activeFamilyId: 'f1',
            memberships: [MyMembership(familyId: 'f1', role: role, status: MemberStatus.active, family: _family)],
          ),
        ),
      ),
    ],
  );

  testWidgets('owner sees pending requests, invite button and member actions', (tester) async {
    await pumpAs(tester, 'a', FamilyRole.owner);

    expect(find.text('Keluarga Abdullah'), findsOneWidget);
    expect(find.text('Permintaan menunggu'), findsOneWidget);
    expect(find.byTooltip('Luluskan'), findsOneWidget);
    expect(find.text('Jemput ahli'), findsOneWidget);
    expect(find.text('Aminah (Anda)'), findsOneWidget);

    await tester.tap(find.text('Badrul'));
    await tester.pumpAndSettle();
    expect(find.text('Keluarkan daripada keluarga'), findsOneWidget);
    expect(find.text('Jadikan pemilik'), findsOneWidget);
  });

  testWidgets('ordinary member sees no management controls', (tester) async {
    await pumpAs(tester, 'b', FamilyRole.member);

    expect(find.text('Permintaan menunggu'), findsNothing);
    expect(find.text('Jemput ahli'), findsNothing);
    expect(find.byIcon(Icons.mail_outline), findsNothing, reason: 'invitation history hidden');

    await tester.tap(find.text('Aminah'));
    await tester.pumpAndSettle();
    expect(find.text('Keluarkan daripada keluarga'), findsNothing);
    expect(find.text('Gantung ahli'), findsNothing);
  });
}
