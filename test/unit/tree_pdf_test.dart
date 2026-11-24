import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:familysync/features/family_tree/domain/tree_layout.dart';
import 'package:familysync/features/family_tree/domain/tree_models.dart';
import 'package:familysync/features/family_tree/presentation/tree_pdf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;

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

  group('print PDF', () {
    late TreePdfFonts fonts;
    setUpAll(() {
      pw.Font font(String n) => pw.Font.ttf(ByteData.sublistView(File('assets/fonts/$n').readAsBytesSync()));
      fonts = TreePdfFonts(
        regular: font('NotoSans-Regular.ttf'),
        bold: font('NotoSans-Bold.ttf'),
        fallback: [font('NotoNaskhArabic-Regular.ttf')],
      );
    });

    final text = TreePdfText(
      title: 'Salasilah Keluarga',
      generated: 'Dijana',
      legend: 'Petunjuk',
      page: (p, t) => 'Halaman $p / $t',
      pageShort: (p) => 'hlm. $p',
      continues: (p) => 'sambungan di halaman $p',
      overview: 'Peta halaman',
      overviewHint: 'Susun mengikut label',
      deceased: (g) => g == Gender.female ? 'Allahyarhamah' : 'Allahyarham',
      branchOf: (n) => 'Cabang $n',
      generationLabel: (n) => 'G${n + 1}',
    );

    int pages(Uint8List pdf) => RegExp(r'/Type\s*/Page[^s]').allMatches(latin1.decode(pdf)).length;

    Future<Uint8List> build(TreeData t, TreePdfOptions o) async {
      final bytes = await buildTreePdf(t, text: text, fonts: fonts, options: o);
      final out = Platform.environment['TREE_PDF_OUT'];
      if (out != null) {
        File('$out/${o.scope.name}_${o.style.name}_${t.persons.length}_g${o.maxGenerations ?? 0}.pdf')
            .writeAsBytesSync(bytes);
      }
      return bytes;
    }

    test('a small tree (also Jawi and non-Latin names) fits on one A4 page', () async {
      final t = TreeData(
        persons: [
          ...tree.persons.values,
          p('jawi', 1985, name: 'محمد علي'),
        ],
        relations: [...tree.relations, rel('ayah', 'jawi', RelationKind.parent)],
      );
      final bytes = await build(t, const TreePdfOptions());
      expect(ascii.decode(bytes.sublist(0, 5)), '%PDF-');
      expect(pages(bytes), 1);
    });

    test('a big tree is split into readable pages plus a page map', () async {
      final big = bigTree(); // 4 generations, 5 children per couple
      final bytes = await build(big, const TreePdfOptions());
      expect(pages(bytes), greaterThan(3));
      // Limiting to 2 generations fits on one page again.
      expect(pages(await build(big, const TreePdfOptions(maxGenerations: 2))), 1);
    });

    test('branch, branch-per-page and list styles', () async {
      final big = bigTree();
      final branch = await build(big, const TreePdfOptions(scope: PdfScope.branch, rootId: 'c1_1'));
      expect(pages(branch), 1, reason: 'a grandchild\'s branch (couple + 5 children) fits');
      final perPage = await build(big, const TreePdfOptions(scope: PdfScope.branchPerPage, rootId: 'root'));
      expect(pages(perPage), greaterThanOrEqualTo(6), reason: 'cover + one section per child');
      final list = await build(big, const TreePdfOptions(style: PdfStyle.list));
      expect(pages(list), greaterThan(1));
    });

    test('pages are cut only between cards and never wider than the page', () {
      const card = 100.0, gap = 12.0, page = 786.0;
      final starts = [for (var i = 0; i < 40; i++) i * (card + gap) + (i.isOdd ? 30.0 : 0)];
      final total = starts.last + card;
      final cuts = treePdfCuts(starts, card, gap, total, page);
      expect(cuts.first.$1, 0);
      expect(cuts.last.$2, total);
      for (final (a, b) in cuts) {
        expect(b - a, lessThanOrEqualTo(page));
        for (final s in starts) {
          expect(b > s && b < s + card && b != total, isFalse, reason: 'cut at $b goes through card at $s');
        }
      }
    });
  });
}

/// root ∞ wife, 5 children (each married), 5 grandchildren each, 5 great-
/// grandchildren each: 1+1 + 5*2 + 25*2 + 125 = 187 people.
TreeData bigTree() {
  final persons = <TreePerson>[p('root', 1930), p('wife', 1932, g: Gender.female)];
  final relations = <TreeRelation>[rel('root', 'wife', RelationKind.spouse)];
  void kids(String father, String mother, int year, int depth, String prefix) {
    for (var i = 1; i <= 5; i++) {
      final id = '$prefix$i';
      persons.add(p(id, year + i, name: 'Anak $id bin $father'));
      relations
        ..add(rel(father, id, RelationKind.parent))
        ..add(rel(mother, id, RelationKind.parent));
      if (depth < 3) {
        final sp = '${id}w';
        persons.add(p(sp, year + i + 1, g: Gender.female, name: 'Isteri $id'));
        relations.add(rel(id, sp, RelationKind.spouse));
        kids(id, sp, year + 25, depth + 1, '${id}_');
      }
    }
  }

  kids('root', 'wife', 1955, 1, 'c');
  return TreeData(persons: persons, relations: relations);
}
