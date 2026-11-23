import 'package:familysync/features/family/domain/family_models.dart';
import 'package:familysync/features/family_links/data/links_repository.dart';
import 'package:familysync/features/family_links/domain/link_models.dart';
import 'package:familysync/features/family_links/presentation/family_links_screen.dart';
import 'package:familysync/shared/providers/session_controller.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/pump_app.dart';

class _MockLinks extends Mock implements LinksRepository {}

void main() {
  late _MockLinks repo;

  setUp(() {
    repo = _MockLinks();
    when(() => repo.clan('C1')).thenAnswer(
      (_) async => const [
        LinkedFamily(
          familyId: 'P',
          name: 'Keluarga Abdul Rahman',
          memberCount: 8,
          depth: 0,
          relation: LinkRelation.parent,
        ),
        LinkedFamily(
          familyId: 'C1',
          name: 'Keluarga Saya',
          memberCount: 4,
          depth: 1,
          parentFamilyId: 'P',
          relation: LinkRelation.self,
        ),
      ],
    );
    when(() => repo.requests('C1')).thenAnswer(
      (_) async => const [
        LinkRequest(
          id: 'r1',
          parentFamilyId: 'C1',
          childFamilyId: 'C2',
          otherFamilyName: 'Keluarga Anak',
          incoming: true,
        ),
      ],
    );
    when(() => repo.respond('r1', approve: true)).thenAnswer((_) async {});
  });

  List<Override> overrides(FamilyRole role) => [
    linksRepositoryProvider.overrideWithValue(repo),
    sessionControllerProvider.overrideWith(
      () => FixedSession(
        SessionState(
          status: SessionStatus.ready,
          user: fakeUser('u1'),
          activeFamilyId: 'C1',
          memberships: [
            MyMembership(
              familyId: 'C1',
              role: role,
              status: MemberStatus.active,
              family: const Family(id: 'C1', name: 'Keluarga Saya'),
            ),
            const MyMembership(
              familyId: 'P',
              role: FamilyRole.member,
              status: MemberStatus.active,
              family: Family(id: 'P', name: 'Keluarga Abdul Rahman'),
            ),
          ],
        ),
      ),
    ),
  ];

  testWidgets('admin sees the clan, approves an incoming request; already-linked families are not offered', (
    tester,
  ) async {
    await pumpLocalized(tester, const FamilyLinksScreen(), overrides: overrides(FamilyRole.owner));
    expect(find.text('Keluarga Abdul Rahman'), findsOneWidget);
    expect(find.text('Keluarga Saya'), findsOneWidget);
    expect(find.text('Keluarga Anak mahu bersambung'), findsOneWidget);
    expect(
      find.text('Untuk menyambung, anda perlu menjadi ahli keluarga yang satu lagi juga.'),
      findsOneWidget,
      reason: 'the only other family is already in the clan',
    );
    await tester.tap(find.byTooltip('Luluskan'));
    await tester.pumpAndSettle();
    verify(() => repo.respond('r1', approve: true)).called(1);
  });

  testWidgets('members see the clan but no actions', (tester) async {
    await pumpLocalized(tester, const FamilyLinksScreen(), overrides: overrides(FamilyRole.member));
    expect(find.text('Keluarga Abdul Rahman'), findsOneWidget);
    expect(find.byTooltip('Luluskan'), findsNothing);
    expect(find.byTooltip('Putuskan sambungan'), findsNothing);
  });
}
