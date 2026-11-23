import 'package:familysync/features/family_tree/domain/tree_models.dart';
import 'package:familysync/features/notifications/domain/notification_models.dart';
import 'package:flutter_test/flutter_test.dart';

TreePerson p(String id, int year, {Gender g = Gender.male, DateTime? died, int month = 1, int day = 1}) =>
    TreePerson(id: id, familyId: 'F', fullName: id, gender: g, birthDate: DateTime(year, month, day), deathDate: died);

TreeRelation parent(String a, String b, {bool adoptive = false, RelationStatus s = RelationStatus.confirmed}) =>
    TreeRelation(
      id: '$a>$b',
      familyId: 'F',
      kind: RelationKind.parent,
      personA: a,
      personB: b,
      status: s,
      adoptive: adoptive,
    );

TreeRelation spouse(String a, String b) => TreeRelation(
  id: '$a=$b',
  familyId: 'F',
  kind: RelationKind.spouse,
  personA: a,
  personB: b,
  status: RelationStatus.confirmed,
);

void main() {
  // Tok → Ayah (+Ibu) → Hasan, Saya(+Salmah), Siti → Faris (Hasan's)
  final tree = TreeData(
    persons: [
      p('tok', 1920, died: DateTime(1995)),
      p('ayah', 1950),
      p('ibu', 1955, g: Gender.female),
      p('hasan', 1980),
      p('saya', 1985),
      p('siti', 1982, g: Gender.female),
      p('salmah', 1987, g: Gender.female),
      p('faris', 2010),
      p('angkat', 2015, g: Gender.female),
    ],
    relations: [
      parent('tok', 'ayah'),
      spouse('ayah', 'ibu'),
      for (final c in ['hasan', 'saya', 'siti']) ...[parent('ayah', c), parent('ibu', c)],
      spouse('saya', 'salmah'),
      parent('hasan', 'faris'),
      parent('saya', 'angkat', adoptive: true),
      parent('salmah', 'faris', s: RelationStatus.pending), // pending: ignored
    ],
  );

  test('lookups use confirmed links only, sorted by birth', () {
    expect(tree.parentsOf('saya').map((x) => x.id), ['ayah', 'ibu']);
    expect(tree.siblingsOf('saya').map((x) => x.id), ['hasan', 'siti']);
    expect(tree.childrenOf('ayah').map((x) => x.id), ['hasan', 'siti', 'saya']);
    expect(tree.spousesOf('salmah').map((x) => x.id), ['saya']);
    expect(tree.parentsOf('faris').map((x) => x.id), ['hasan'], reason: 'pending proposal ignored');
    expect(tree.pending, hasLength(1));
    expect(tree.isAdoptiveChild('saya', 'angkat'), isTrue);
  });

  test('generations: children below parents, in-married spouse beside partner', () {
    final g = tree.generations();
    expect(g['tok'], 0);
    expect(g['ayah'], 1);
    expect(g['ibu'], 1, reason: 'spouse shares the row');
    expect(g['saya'], 2);
    expect(g['salmah'], 2);
    expect(g['faris'], 3);
  });

  test('layout rows keep spouses adjacent and siblings by birth', () {
    final rows = tree.layoutRows();
    expect(rows, hasLength(4));
    expect(rows[1], ['ayah', 'ibu']);
    final row2 = rows[2];
    expect(row2.indexOf('salmah'), row2.indexOf('saya') + 1);
    expect(row2.indexOf('hasan') < row2.indexOf('siti'), isTrue);
  });

  test('age and birthdays (29 Feb on 28 Feb in common years); deceased skipped', () {
    final leap = p('leap', 2000, month: 2, day: 29);
    expect(birthdayIn(leap.birthDate, 2027), DateTime(2027, 2, 28));
    expect(birthdayIn(leap.birthDate, 2028), DateTime(2028, 2, 29));
    expect(p('x', 2000, month: 6, day: 15).ageOn(DateTime(2026, 6, 14)), 25);
    expect(p('x', 2000, month: 6, day: 15).ageOn(DateTime(2026, 6, 15)), 26);
    expect(p('tok2', 1920, died: DateTime(1995, 6, 1)).ageOn(DateTime(2026)), 75, reason: 'age at death');

    final t = TreeData(
      persons: [
        leap,
        p('soon', 1990, month: 3, day: 10),
        p('gone', 1940, month: 3, day: 1, died: DateTime(2000)),
        p('later', 1990, month: 9, day: 1),
      ],
      relations: const [],
    );
    final up = t.upcomingBirthdays(DateTime(2027, 2, 20));
    expect(up.map((e) => e.$1.id), ['leap', 'soon']);
    expect(up.first.$2, DateTime(2027, 2, 28));
    // wraps into next year
    expect(t.upcomingBirthdays(DateTime(2026, 12, 20), days: 80).map((e) => e.$1.id), ['leap', 'soon']);
  });

  test('person JSON includes the photo path', () {
    final x = TreePerson.fromJson({
      'id': 'a',
      'family_id': 'F',
      'full_name': 'Ali',
      'gender': 'male',
      'birth_date': '1990-01-02',
      'photo_path': 'F/a/x.jpg',
    });
    expect(x.photoPath, 'F/a/x.jpg');
    expect(x.birthDate, DateTime(1990, 1, 2));
  });

  test('relationship JSON and locale label', () {
    final r = Relationship.fromJson({
      'kind': 'blood',
      'ms': 'anak saudara',
      'en': 'nephew',
      'up': 1,
      'down': 2,
      'via': 'h',
    });
    expect(r.label('ms'), 'anak saudara');
    expect(r.label('en'), 'nephew');
    expect(r.via, 'h');
  });

  test('cross-family relations list the families whose approval is missing', () {
    const r = TreeRelation(
      id: 'x',
      familyId: 'P',
      otherFamilyId: 'C',
      kind: RelationKind.parent,
      personA: 'a',
      personB: 'b',
      status: RelationStatus.pending,
      familyOk: false,
    );
    expect(r.awaitingFamilies, ['P']);
    final j = TreeRelation.fromJson({
      'id': 'y',
      'family_id': 'P',
      'other_family_id': 'C',
      'kind': 'spouse',
      'person_a': 'a',
      'person_b': 'b',
      'status': 'pending',
      'family_ok': true,
      'other_ok': false,
    });
    expect(j.awaitingFamilies, ['C']);
  });

  test('notification taps may open the tree', () {
    const id = '0b9f3c9e-3f5e-4f0b-9d55-3c1c2b8d7e11';
    expect(safeNotificationRoute('/family-tree'), '/family-tree');
    expect(safeNotificationRoute('/family-tree/$id'), '/family-tree/$id');
    expect(safeNotificationRoute('/family-tree/x'), isNull);
  });
}
