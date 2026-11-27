import 'package:familysync/features/collections/data/collections_repository.dart';
import 'package:familysync/features/collections/domain/collection_models.dart';
import 'package:familysync/features/collections/presentation/collections_screen.dart';
import 'package:familysync/features/family/data/family_repository.dart';
import 'package:familysync/features/family/domain/family_models.dart';
import 'package:familysync/shared/providers/session_controller.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/pump_app.dart';

class _MockRepo extends Mock implements CollectionsRepository {}

class _MockFamily extends Mock implements FamilyRepository {}

Collection _collection({String createdBy = 'u9'}) => Collection.fromJson({
  'id': 'k1',
  'family_id': 'F1',
  'title': 'Kenduri',
  'purpose': 'Kenduri tahlil arwah Atok',
  'mode': 'lump',
  'target_amount': 3000,
  'status': 'open',
  'revision': 1,
  'created_by': createdBy,
  'collection_payments': [
    {
      'id': 'p1',
      'payer_id': 'u2',
      'amount': 1000,
      'paid_on': '2026-11-01',
      'status': 'confirmed',
      'payer': {'display_name': 'Badrul'},
    },
    {
      'id': 'p2',
      'payer_id': 'u3',
      'amount': 500,
      'paid_on': '2026-11-02',
      'status': 'pending',
      'payer': {'display_name': 'Chong'},
    },
  ],
  'collection_expenses': [
    {'id': 'e1', 'amount': 200, 'spent_on': '2026-11-03', 'description': 'Beras'},
  ],
});

void main() {
  late _MockRepo repo;
  late _MockFamily family;

  setUpAll(() {
    registerFallbackValue(_collection());
    registerFallbackValue(DateTime(2026));
  });

  setUp(() {
    repo = _MockRepo();
    family = _MockFamily();
    when(() => repo.watch(any())).thenAnswer((_) => const Stream.empty());
    when(() => family.members('F1')).thenAnswer((_) async => const []);
    when(() => family.watchFamily(any())).thenAnswer((_) => const Stream.empty());
  });

  List<Override> overrides(FamilyRole role) => [
    collectionsRepositoryProvider.overrideWithValue(repo),
    familyRepositoryProvider.overrideWithValue(family),
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

  testWidgets('member sees totals, statuses and can say they paid; no treasurer tools', (tester) async {
    when(() => repo.collection('k1')).thenAnswer((_) async => _collection());
    await pumpLocalized(tester, const CollectionScreen(collectionId: 'k1'), overrides: overrides(FamilyRole.member));
    expect(find.text('Kenduri tahlil arwah Atok'), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(const Key('stat.collected')), matching: find.textContaining('1,000.00')),
      findsOneWidget,
      reason: 'only confirmed counts',
    );
    expect(
      find.descendant(of: find.byKey(const Key('stat.balance')), matching: find.textContaining('800.00')),
      findsOneWidget,
    );
    expect(find.text('Saya sudah bayar'), findsOneWidget);
    expect(find.byKey(const Key('collection.menu')), findsNothing);
    expect(find.byKey(const ValueKey('confirm-p2')), findsNothing, reason: 'members cannot confirm');
  });

  testWidgets('treasurer (family owner) confirms a pending payment', (tester) async {
    when(() => repo.collection('k1')).thenAnswer((_) async => _collection());
    when(() => repo.reviewPayment('p2', approve: true)).thenAnswer((_) async {});
    await pumpLocalized(tester, const CollectionScreen(collectionId: 'k1'), overrides: overrides(FamilyRole.owner));
    expect(find.text('Menunggu pengesahan (1)'), findsOneWidget);
    expect(find.text('Rekod bayaran'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-p2')));
    await tester.pumpAndSettle();
    verify(() => repo.reviewPayment('p2', approve: true)).called(1);
  });

  testWidgets('a member records a payment: amount validated, then pending', (tester) async {
    when(() => repo.collection('k1')).thenAnswer((_) async => _collection());
    when(
      () => repo.recordPayment(
        collection: any(named: 'collection'),
        amount: any(named: 'amount'),
        paidOn: any(named: 'paidOn'),
        note: any(named: 'note'),
        payerId: any(named: 'payerId'),
        receipt: any(named: 'receipt'),
      ),
    ).thenAnswer((_) async {});
    await pumpLocalized(tester, const CollectionScreen(collectionId: 'k1'), overrides: overrides(FamilyRole.member));
    await tester.tap(find.text('Saya sudah bayar'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('money.amount')), '12.345');
    await tester.tap(find.byKey(const Key('money.save')));
    await tester.pumpAndSettle();
    expect(find.text('Masukkan jumlah yang sah (contoh 150 atau 150.50)'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('money.amount')), '250');
    await tester.tap(find.byKey(const Key('money.save')));
    await tester.pumpAndSettle();
    final call = verify(
      () => repo.recordPayment(
        collection: any(named: 'collection'),
        amount: captureAny(named: 'amount'),
        paidOn: any(named: 'paidOn'),
        note: any(named: 'note'),
        payerId: captureAny(named: 'payerId'),
        receipt: any(named: 'receipt'),
      ),
    )..called(1);
    expect(call.captured, [25000, null], reason: 'RM250 in sen, paid by me');
    expect(find.text('Bayaran direkod · menunggu pengesahan bendahari'), findsOneWidget);
  });

  testWidgets('overview lists collections with progress and my part', (tester) async {
    when(() => repo.summaries('F1')).thenAnswer(
      (_) async => [
        CollectionSummary.fromJson({
          'id': 'k2',
          'family_id': 'F1',
          'title': 'Hadiah Mak',
          'purpose': 'Hari jadi',
          'mode': 'per_member',
          'status': 'open',
          'share_with_clan': true,
          'target_total': 1000,
          'confirmed_total': 400,
          'pending_total': 0,
          'expense_total': 0,
          'my_target': 300,
          'my_paid': 300,
          'my_pending': 0,
          'is_treasurer': false,
        }),
      ],
    );
    await pumpLocalized(tester, const CollectionsScreen(), overrides: overrides(FamilyRole.member));
    expect(find.text('Hadiah Mak'), findsOneWidget);
    expect(find.textContaining('Anda: RM300.00 / RM300.00'), findsOneWidget);
    expect(find.text('Kutipan baharu'), findsOneWidget);
  });
}
