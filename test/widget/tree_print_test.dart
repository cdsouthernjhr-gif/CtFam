import 'package:familysync/features/family_tree/domain/tree_models.dart';
import 'package:familysync/features/family_tree/presentation/tree_pdf.dart';
import 'package:familysync/features/family_tree/presentation/tree_print_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/pump_app.dart';

TreePerson p(String id, int year, {Gender g = Gender.male}) =>
    TreePerson(id: id, familyId: 'F', fullName: id, gender: g, birthDate: DateTime(year));

void main() {
  final tree = TreeData(
    persons: [
      p('Atok', 1930),
      p('Opah', 1932, g: Gender.female),
      p('Ali', 1960),
    ],
    relations: [
      TreeRelation(
        id: 'r1',
        familyId: 'F',
        kind: RelationKind.parent,
        personA: 'Atok',
        personB: 'Ali',
        status: RelationStatus.confirmed,
      ),
    ],
  );

  testWidgets('print options: branch + 3 generations + list style', (tester) async {
    TreePdfOptions? picked;
    await pumpLocalized(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => picked = await showModalBottomSheet<TreePdfOptions>(
              context: context,
              isScrollControlled: true,
              builder: (_) => TreePrintOptionsSheet(tree: tree),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Cetak salasilah'), findsOneWidget);
    expect(find.byKey(const ValueKey('print.root')), findsNothing, reason: 'whole tree needs no root');

    await tester.tap(find.byKey(const ValueKey('print.scope.branch')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('print.root')), findsOneWidget);
    await tester.tap(find.text('3'));
    await tester.tap(find.text('Senarai'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('print.preview')));
    await tester.tap(find.byKey(const ValueKey('print.preview')));
    await tester.pumpAndSettle();

    expect(picked, isNotNull);
    expect(picked!.scope, PdfScope.branch);
    expect(picked!.rootId, 'Atok', reason: 'defaults to the oldest root');
    expect(picked!.maxGenerations, 3);
    expect(picked!.style, PdfStyle.list);
    expect(picked!.photos, isFalse, reason: 'no photos in the tree');
  });
}
