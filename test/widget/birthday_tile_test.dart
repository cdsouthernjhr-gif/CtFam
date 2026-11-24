import 'package:familysync/features/family_tree/domain/tree_models.dart';
import 'package:familysync/features/family_tree/presentation/birthday_tile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/pump_app.dart';

void main() {
  final today = DateTime(2026, 11, 24);
  TreePerson person(String id) =>
      TreePerson(id: id, familyId: 'F', fullName: id, gender: Gender.male, birthDate: DateTime(1990, 12, 1));

  Future<void> pump(WidgetTester tester, DateTime birthday, {bool reduceMotion = false}) async {
    await tester.pumpWidget(Container()); // reset
    await pumpLocalizedNoSettle(
      tester,
      MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(
          body: BirthdayTile(person: person('Ali'), birthday: birthday, today: today),
        ),
      ),
    );
  }

  testWidgets('blinks from 7 days before, with a countdown', (tester) async {
    await pump(tester, DateTime(2026, 12, 1)); // 7 days
    expect(find.byType(BirthdayBlink), findsOneWidget);
    expect(find.textContaining('7 hari lagi'), findsOneWidget);
    // it animates: the highlight changes between frames
    final before = tester
        .widget<DecoratedBox>(
          find.descendant(of: find.byType(BirthdayBlink), matching: find.byType(DecoratedBox)).first,
        )
        .decoration;
    await tester.pump(const Duration(milliseconds: 500));
    final after = tester
        .widget<DecoratedBox>(
          find.descendant(of: find.byType(BirthdayBlink), matching: find.byType(DecoratedBox)).first,
        )
        .decoration;
    expect(after, isNot(before));
  });

  testWidgets('tomorrow and today', (tester) async {
    await pump(tester, DateTime(2026, 11, 25));
    expect(find.textContaining('Esok'), findsOneWidget);
    await pump(tester, today);
    expect(find.textContaining('Hari ini'), findsOneWidget);
    expect(find.byType(BirthdayBlink), findsOneWidget);
  });

  testWidgets('more than 7 days away: no blinking, plain date', (tester) async {
    await pump(tester, DateTime(2026, 12, 2)); // 8 days
    expect(find.byType(BirthdayBlink), findsNothing);
    expect(find.textContaining('hari lagi'), findsNothing);
  });

  testWidgets('"reduce motion": highlighted but still', (tester) async {
    await pump(tester, DateTime(2026, 11, 27), reduceMotion: true);
    final a = tester
        .widget<DecoratedBox>(
          find.descendant(of: find.byType(BirthdayBlink), matching: find.byType(DecoratedBox)).first,
        )
        .decoration;
    await tester.pump(const Duration(milliseconds: 500));
    final b = tester
        .widget<DecoratedBox>(
          find.descendant(of: find.byType(BirthdayBlink), matching: find.byType(DecoratedBox)).first,
        )
        .decoration;
    expect(b, a);
  });

  test('daysUntil counts calendar days', () {
    expect(daysUntil(DateTime(2026, 11, 24, 23, 59), DateTime(2026, 11, 25)), 1);
    expect(daysUntil(DateTime(2026, 12, 31), DateTime(2027, 1, 7)), 7);
  });
}
