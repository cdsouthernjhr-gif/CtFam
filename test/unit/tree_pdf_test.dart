import 'dart:convert';

import 'package:familysync/features/family_tree/domain/tree_layout.dart';
import 'package:familysync/features/family_tree/domain/tree_models.dart';
import 'package:familysync/features/family_tree/presentation/tree_pdf.dart';
import 'package:flutter_test/flutter_test.dart';

TreePerson p(String id, int year, {Gender g = Gender.male, String? name, DateTime? died}) =>
    TreePerson(id: id, familyId: 'F', fullName: name ?? id, gender: g, birthDate: DateTime(year), deathDate: died);

TreeRelation rel(String a, String b, RelationKind k, {bool adoptive = false}) => TreeRelation(
  id: '$a$b',
  familyId: 'F',
  kind: k,
  personA: a,
  personB: b,
  status: RelationStatus.confirmed,
  adoptive: adoptive,
);

final tree = TreeData(
  persons: [
    p('ayah', 1950),
    p('ibu', 1955, g: Gender.female),
    p('anak', 1980),
    p('angkat', 1990, g: Gender.female, name: 'Siti Nur Ain'),
    p('tok', 1920, died: DateTime(1990), name: 'Tök 王'), // non Latin-1 characters
  ],
  relations: [
    rel('tok', 'ayah', RelationKind.parent),
    rel('ayah', 'ibu', RelationKind.spouse),
    rel('ayah', 'anak', RelationKind.parent),
    rel('ayah', 'angkat', RelationKind.parent, adoptive: true),
  ],
);

void main() {
  test('layout: one card per person, rows by generation, links between cards', () {
    final l = TreeLayout.of(tree);
    expect(l.positions.keys.toSet(), tree.persons.keys.toSet());
    expect(l.positions['tok']!.y < l.positions['ayah']!.y, isTrue);
    expect(l.positions['ayah']!.y, l.positions['ibu']!.y, reason: 'spouses share a row');
    final links = l.links(tree);
    expect(links, hasLength(4), reason: 'tok->ayah, spouse, ayah->anak, ayah->angkat');
    final spouse = links.singleWhere((x) => x.kind == RelationKind.spouse);
    expect(spouse.points, hasLength(2));
    expect(links.where((x) => x.adoptive), hasLength(1));
    expect(l.width >= TreeLayout.cardW * 2, isTrue);
  });

  test('children of a married couple get ONE line from the middle of the couple', () {
    final t = TreeData(
      persons: [
        p('ayah', 1950),
        p('ibu', 1952, g: Gender.female),
        p('a', 1980),
        p('b', 1982),
      ],
      relations: [
        rel('ayah', 'ibu', RelationKind.spouse),
        rel('ayah', 'a', RelationKind.parent),
        rel('ibu', 'a', RelationKind.parent),
        rel('ayah', 'b', RelationKind.parent),
        rel('ibu', 'b', RelationKind.parent),
      ],
    );
    final l = TreeLayout.of(t);
    final kids = l.links(t).where((x) => x.kind == RelationKind.parent).toList();
    expect(kids, hasLength(2), reason: 'one per child, not one per parent');
    final ayah = l.positions['ayah']!, ibu = l.positions['ibu']!;
    final mid = (ayah.x + ibu.x) / 2 + TreeLayout.cardW / 2;
    expect(kids.every((k) => k.points.first.x == mid), isTrue, reason: 'starts between the parents');
  });

  test('relationBetween finds confirmed links in either direction', () {
    expect(tree.relationBetween('anak', 'ayah')!.kind, RelationKind.parent);
    expect(tree.relationBetween('ibu', 'ayah')!.kind, RelationKind.spouse);
    expect(tree.relationBetween('anak', 'ibu'), isNull);
  });

  test('PDF export renders the whole chart (also with non-Latin names)', () async {
    final bytes = await buildTreePdf(
      tree,
      labels: const TreePdfLabels(title: 'Salasilah Keluarga', generated: 'Dijana', legend: 'Petunjuk'),
    );
    expect(ascii.decode(bytes.sublist(0, 5)), '%PDF-');
    expect(bytes.length, greaterThan(2000));
  });
}
