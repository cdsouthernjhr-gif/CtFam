import 'package:familysync/features/family/data/family_repository.dart';
import 'package:familysync/features/family/domain/family_models.dart';
import 'package:familysync/features/family_tree/data/tree_repository.dart';
import 'package:familysync/features/family_tree/domain/tree_models.dart';
import 'package:familysync/features/family_tree/presentation/family_tree_screen.dart';
import 'package:familysync/features/family_tree/presentation/person_screen.dart';
import 'package:familysync/features/settings/data/profile_repository.dart';
import 'package:familysync/shared/providers/session_controller.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/pump_app.dart';

class _MockTree extends Mock implements TreeRepository {}

class _MockFamily extends Mock implements FamilyRepository {}

class _MockProfile extends Mock implements ProfileRepository {}

void main() {
  late _MockTree repo;
  late _MockFamily family;
  late _MockProfile profile;

  final data = TreeData(
    persons: [
      TreePerson(id: 'ayah', familyId: 'F1', fullName: 'Ayah', gender: Gender.male, birthDate: DateTime(1950)),
      TreePerson(id: 'hasan', familyId: 'F1', fullName: 'Hasan', gender: Gender.male, birthDate: DateTime(1980)),
      TreePerson(
        id: 'saya',
        familyId: 'F1',
        fullName: 'Amir',
        gender: Gender.male,
        birthDate: DateTime(1985),
        userId: 'u1',
      ),
      TreePerson(id: 'faris', familyId: 'F1', fullName: 'Faris', gender: Gender.male, birthDate: DateTime(2010)),
    ],
    relations: const [
      TreeRelation(
        id: 'r1',
        familyId: 'F1',
        kind: RelationKind.parent,
        personA: 'ayah',
        personB: 'hasan',
        status: RelationStatus.confirmed,
      ),
      TreeRelation(
        id: 'r2',
        familyId: 'F1',
        kind: RelationKind.parent,
        personA: 'ayah',
        personB: 'saya',
        status: RelationStatus.confirmed,
      ),
      TreeRelation(
        id: 'r3',
        familyId: 'F1',
        kind: RelationKind.parent,
        personA: 'hasan',
        personB: 'faris',
        status: RelationStatus.confirmed,
      ),
      TreeRelation(
        id: 'r4',
        familyId: 'F1',
        kind: RelationKind.spouse,
        personA: 'hasan',
        personB: 'saya',
        status: RelationStatus.pending,
        proposedBy: 'u2',
        familyOk: false, // waiting for this family's admin
      ),
    ],
  );

  setUp(() {
    repo = _MockTree();
    family = _MockFamily();
    profile = _MockProfile();
    when(() => repo.watch(any())).thenAnswer((_) => const Stream.empty());
    when(() => repo.load('F1')).thenAnswer((_) async => data);
    when(() => family.watchFamily(any())).thenAnswer((_) => const Stream.empty());
    when(() => family.members('F1')).thenAnswer((_) async => const []);
    when(() => family.family('F1')).thenAnswer((_) async => const Family(id: 'F1', name: 'Keluarga'));
  });

  List<Override> overrides(FamilyRole role, {String user = 'u1'}) => [
    treeRepositoryProvider.overrideWithValue(repo),
    familyRepositoryProvider.overrideWithValue(family),
    profileRepositoryProvider.overrideWithValue(profile),
    sessionControllerProvider.overrideWith(
      () => FixedSession(
        SessionState(
          status: SessionStatus.ready,
          user: fakeUser(user),
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

  testWidgets('tree shows everyone; admins can add and review proposals', (tester) async {
    await pumpLocalized(tester, const FamilyTreeScreen(), overrides: overrides(FamilyRole.owner));
    for (final n in ['Ayah', 'Hasan', 'Amir', 'Faris']) {
      expect(find.text(n), findsOneWidget);
    }
    expect(find.text('Tambah orang'), findsOneWidget, reason: 'admin FAB');
    expect(find.byTooltip('Cadangan menunggu pengesahan'), findsOneWidget);
    expect(find.text('Anda belum ada dalam salasilah'), findsNothing, reason: 'own record exists');
    expect(find.text('Tambah gambar salasilah'), findsOneWidget, reason: 'admins can add a cover photo');
  });

  testWidgets('member without a record is asked to add themselves; no admin tools', (tester) async {
    await pumpLocalized(tester, const FamilyTreeScreen(), overrides: overrides(FamilyRole.member, user: 'u9'));
    expect(find.text('Anda belum ada dalam salasilah'), findsOneWidget);
    expect(find.text('Tambah orang'), findsNothing);
    expect(find.byTooltip('Cadangan menunggu pengesahan'), findsNothing, reason: 'not their proposal');
    expect(find.text('Tambah gambar salasilah'), findsNothing, reason: 'members cannot change the cover');
  });

  testWidgets('person screen explains the relationship (anak saudara · anak kepada Hasan)', (tester) async {
    when(() => repo.relationship('F1', 'faris')).thenAnswer(
      (_) async => const Relationship(kind: 'blood', ms: 'anak saudara', en: 'nephew', up: 1, down: 2, via: 'hasan'),
    );
    await pumpLocalized(tester, const PersonScreen(personId: 'faris'), overrides: overrides(FamilyRole.member));
    expect(find.text('anak saudara anda · anak kepada Hasan'), findsOneWidget);
    expect(find.text('Hasan'), findsOneWidget, reason: 'parent chip');
    expect(find.byTooltip('Edit maklumat'), findsNothing, reason: 'members edit only their own record');
    expect(find.byKey(const Key('tree.photo')), findsNothing, reason: 'no photo editing for others');
    expect(find.text('Cadangkan hubungan'), findsOneWidget);
  });

  testWidgets('own record: "Ini anda" and editable', (tester) async {
    await pumpLocalized(tester, const PersonScreen(personId: 'saya'), overrides: overrides(FamilyRole.member));
    expect(find.text('Ini anda'), findsOneWidget);
    expect(find.byTooltip('Edit maklumat'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tree.photo')));
    await tester.pumpAndSettle();
    expect(find.text('Pilih dari galeri'), findsOneWidget);
    expect(find.text('Padam gambar'), findsNothing, reason: 'no photo yet');
  });

  testWidgets('owner: long-press a card opens the editing menu; zoom buttons work', (tester) async {
    await pumpLocalized(tester, const FamilyTreeScreen(), overrides: overrides(FamilyRole.owner));
    expect(find.byTooltip('Muat turun PDF'), findsOneWidget);

    final viewer = tester.widget<InteractiveViewer>(find.byKey(const Key('tree.viewer')));
    final before = viewer.transformationController!.value.storage[0];
    await tester.tap(find.byTooltip('Zum masuk'));
    await tester.pump();
    expect(viewer.transformationController!.value.storage[0], greaterThan(before));
    await tester.tap(find.byTooltip('Zum keluar'));
    await tester.pump();
    await tester.tap(find.byTooltip('Zum keluar'));
    await tester.pump();
    expect(viewer.transformationController!.value.storage[0], lessThan(before));

    await tester.tap(find.byTooltip('Muat skrin'));
    await tester.pump();
    await tester.longPress(find.byKey(const ValueKey('tree-card-faris')));
    await tester.pumpAndSettle();
    for (final label in [
      'Lihat butiran',
      'Edit maklumat',
      'Tambah ibu/bapa',
      'Tambah anak',
      'Tambah pasangan',
      'Buang daripada salasilah',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });

  testWidgets('members: long-press does nothing (no editing menu)', (tester) async {
    await pumpLocalized(tester, const FamilyTreeScreen(), overrides: overrides(FamilyRole.member));
    final card = tester.widget<InkWell>(find.byKey(const ValueKey('tree-card-faris')));
    expect(card.onLongPress, isNull, reason: 'no editing menu for plain members');
  });

  testWidgets('owner removes a relation from the person page', (tester) async {
    when(() => repo.relationship('F1', 'faris')).thenAnswer((_) async => const Relationship(kind: 'none'));
    when(() => repo.deleteRelation('r3')).thenAnswer((_) async {});
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpLocalized(tester, const PersonScreen(personId: 'faris'), overrides: overrides(FamilyRole.owner));
    await tester.tap(find.byTooltip('Buang hubungan'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Padam'));
    await tester.pumpAndSettle();
    verify(() => repo.deleteRelation('r3')).called(1);
  });
}
