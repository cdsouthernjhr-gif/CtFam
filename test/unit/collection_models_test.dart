import 'package:familysync/features/collections/domain/collection_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parseAmount accepts ringgit and sen, rejects bad input', () {
    expect(parseAmount('150'), 15000);
    expect(parseAmount('150.5'), 15050);
    expect(parseAmount('RM 1,234.50'), 123450);
    expect(parseAmount('0'), isNull);
    expect(parseAmount('1.234'), isNull, reason: 'at most 2 decimals');
    expect(parseAmount('-5'), isNull);
    expect(parseAmount('abc'), isNull);
    expect(parseAmount('10000001'), isNull, reason: 'above RM10 million');
  });

  test('sen() avoids floating point drift', () {
    expect(sen(0.1 + 0.2), 30);
    expect(sen(1234.56), 123456);
  });

  test('totals count only confirmed payments; balance subtracts expenses', () {
    final c = Collection.fromJson({
      'id': 'k',
      'family_id': 'F',
      'title': 'Kenduri',
      'purpose': 'Tahlil',
      'mode': 'per_member',
      'status': 'open',
      'revision': 1,
      'created_by': 'u1',
      'collection_treasurers': [
        {'user_id': 'u2'},
      ],
      'collection_targets': [
        {
          'user_id': 'a',
          'amount': 500,
          'profiles': {'display_name': 'Ali'},
        },
        {
          'user_id': 'b',
          'amount': 300.5,
          'profiles': {'display_name': 'Abu'},
        },
      ],
      'collection_payments': [
        {'id': 'p1', 'payer_id': 'a', 'amount': 200, 'paid_on': '2026-11-01', 'status': 'confirmed'},
        {'id': 'p2', 'payer_id': 'a', 'amount': 300, 'paid_on': '2026-11-02', 'status': 'pending'},
        {'id': 'p3', 'payer_id': 'b', 'amount': 100, 'paid_on': '2026-11-03', 'status': 'rejected'},
      ],
      'collection_expenses': [
        {'id': 'e1', 'amount': 50.25, 'spent_on': '2026-11-04', 'description': 'Beras'},
      ],
    });
    expect(c.mode, CollectionMode.perMember);
    expect(c.target, 80050);
    expect(c.confirmed, 20000);
    expect(c.pending, 30000);
    expect(c.spent, 5025);
    expect(c.balance, 14975);
    expect(c.paidBy('a'), 20000);
    expect(c.pendingBy('a'), 30000);
    expect(c.paidBy('b'), 0, reason: 'rejected does not count');
    expect(c.pendingPayments.map((p) => p.id), ['p2']);
    expect(c.payments.first.id, 'p3', reason: 'newest first');
    expect(c.isTreasurer('u1', familyAdmin: false), isTrue, reason: 'creator');
    expect(c.isTreasurer('u2', familyAdmin: false), isTrue, reason: 'named');
    expect(c.isTreasurer('a', familyAdmin: false), isFalse);
    expect(c.isTreasurer('a', familyAdmin: true), isTrue, reason: 'family owner/admin');
  });
}
