/// Money is kept in sen (cents) as int, to avoid floating point errors.
int sen(Object? v) => v == null ? 0 : ((v as num) * 100).round();

/// Parses "1,234.50", "1234.5" or "RM 20" into sen; null when invalid
/// (not a positive amount with at most 2 decimals, or above RM10 million).
int? parseAmount(String raw) {
  final s = raw.replaceAll(RegExp(r'[RMrm\s,]'), '');
  if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(s)) return null;
  final parts = s.split('.');
  final cents = int.parse(parts[0]) * 100 + (parts.length > 1 ? int.parse(parts[1].padRight(2, '0')) : 0);
  return cents <= 0 || cents > 1000000000 ? null : cents;
}

/// sen → number for the database.
num toAmount(int sen) => sen / 100;

enum CollectionMode {
  open,
  lump,
  perMember;

  String get key => this == perMember ? 'per_member' : name;

  static CollectionMode parse(String? v) => switch (v) {
    'lump' => lump,
    'per_member' => perMember,
    _ => open,
  };
}

enum PaymentStatus {
  pending,
  confirmed,
  rejected;

  static PaymentStatus parse(String? v) =>
      PaymentStatus.values.firstWhere((s) => s.name == v, orElse: () => PaymentStatus.pending);
}

DateTime? _date(Object? v) => v == null ? null : DateTime.parse(v as String).toLocal();
DateTime _day(Object? v) {
  final d = DateTime.parse(v! as String);
  return DateTime(d.year, d.month, d.day);
}

class CollectionSummary {
  const CollectionSummary({
    required this.id,
    required this.familyId,
    required this.title,
    required this.purpose,
    required this.mode,
    required this.closed,
    required this.shareWithClan,
    required this.confirmed,
    required this.pending,
    required this.spent,
    required this.myPaid,
    required this.myPending,
    required this.isTreasurer,
    this.target,
    this.myTarget,
    this.dueDate,
  });

  factory CollectionSummary.fromJson(Map<String, dynamic> j) => CollectionSummary(
    id: j['id'] as String,
    familyId: j['family_id'] as String,
    title: j['title'] as String,
    purpose: j['purpose'] as String,
    mode: CollectionMode.parse(j['mode'] as String?),
    closed: j['status'] == 'closed',
    shareWithClan: (j['share_with_clan'] as bool?) ?? false,
    dueDate: j['due_date'] == null ? null : _day(j['due_date']),
    target: j['target_total'] == null ? null : sen(j['target_total']),
    confirmed: sen(j['confirmed_total']),
    pending: sen(j['pending_total']),
    spent: sen(j['expense_total']),
    myTarget: j['my_target'] == null ? null : sen(j['my_target']),
    myPaid: sen(j['my_paid']),
    myPending: sen(j['my_pending']),
    isTreasurer: (j['is_treasurer'] as bool?) ?? false,
  );

  final String id;
  final String familyId;
  final String title;
  final String purpose;
  final CollectionMode mode;
  final bool closed;
  final bool shareWithClan;
  final DateTime? dueDate;
  final int? target;
  final int confirmed;
  final int pending;
  final int spent;
  final int? myTarget;
  final int myPaid;
  final int myPending;
  final bool isTreasurer;

  int get balance => confirmed - spent;
  double? get progress => target == null || target == 0 ? null : (confirmed / target!).clamp(0, 1).toDouble();
}

class CollectionTarget {
  const CollectionTarget({required this.userId, required this.amount, this.name});

  factory CollectionTarget.fromJson(Map<String, dynamic> j) => CollectionTarget(
    userId: j['user_id'] as String,
    amount: sen(j['amount']),
    name: (j['profiles'] as Map<String, dynamic>?)?['display_name'] as String?,
  );

  final String userId;
  final int amount;
  final String? name;
}

class CollectionPayment {
  const CollectionPayment({
    required this.id,
    required this.amount,
    required this.paidOn,
    required this.status,
    this.payerId,
    this.payerName,
    this.note,
    this.receiptPath,
    this.rejectReason,
    this.recordedBy,
    this.createdAt,
  });

  factory CollectionPayment.fromJson(Map<String, dynamic> j) => CollectionPayment(
    id: j['id'] as String,
    amount: sen(j['amount']),
    paidOn: _day(j['paid_on']),
    status: PaymentStatus.parse(j['status'] as String?),
    payerId: j['payer_id'] as String?,
    payerName: (j['payer'] as Map<String, dynamic>?)?['display_name'] as String?,
    note: j['note'] as String?,
    receiptPath: j['receipt_path'] as String?,
    rejectReason: j['reject_reason'] as String?,
    recordedBy: j['recorded_by'] as String?,
    createdAt: _date(j['created_at']),
  );

  final String id;
  final int amount;
  final DateTime paidOn;
  final PaymentStatus status;
  final String? payerId;
  final String? payerName;
  final String? note;
  final String? receiptPath;
  final String? rejectReason;
  final String? recordedBy;
  final DateTime? createdAt;
}

class CollectionExpense {
  const CollectionExpense({
    required this.id,
    required this.amount,
    required this.spentOn,
    required this.description,
    this.receiptPath,
  });

  factory CollectionExpense.fromJson(Map<String, dynamic> j) => CollectionExpense(
    id: j['id'] as String,
    amount: sen(j['amount']),
    spentOn: _day(j['spent_on']),
    description: j['description'] as String,
    receiptPath: j['receipt_path'] as String?,
  );

  final String id;
  final int amount;
  final DateTime spentOn;
  final String description;
  final String? receiptPath;
}

/// One collection with everything shown on its page.
class Collection {
  const Collection({
    required this.id,
    required this.familyId,
    required this.title,
    required this.purpose,
    required this.mode,
    required this.closed,
    required this.shareWithClan,
    required this.revision,
    this.lumpTarget,
    this.dueDate,
    this.createdBy,
    this.treasurerIds = const [],
    this.targets = const [],
    this.payments = const [],
    this.expenses = const [],
  });

  factory Collection.fromJson(Map<String, dynamic> j) => Collection(
    id: j['id'] as String,
    familyId: j['family_id'] as String,
    title: j['title'] as String,
    purpose: j['purpose'] as String,
    mode: CollectionMode.parse(j['mode'] as String?),
    closed: j['status'] == 'closed',
    shareWithClan: (j['share_with_clan'] as bool?) ?? false,
    revision: (j['revision'] as int?) ?? 1,
    lumpTarget: j['target_amount'] == null ? null : sen(j['target_amount']),
    dueDate: j['due_date'] == null ? null : _day(j['due_date']),
    createdBy: j['created_by'] as String?,
    treasurerIds: [
      for (final t in (j['collection_treasurers'] as List?) ?? const [])
        (t as Map<String, dynamic>)['user_id'] as String,
    ],
    targets: [
      for (final t in (j['collection_targets'] as List?) ?? const [])
        CollectionTarget.fromJson(t as Map<String, dynamic>),
    ]..sort((a, b) => (a.name ?? '').compareTo(b.name ?? '')),
    payments: [
      for (final p in (j['collection_payments'] as List?) ?? const [])
        CollectionPayment.fromJson(p as Map<String, dynamic>),
    ]..sort((a, b) => b.paidOn.compareTo(a.paidOn)),
    expenses: [
      for (final e in (j['collection_expenses'] as List?) ?? const [])
        CollectionExpense.fromJson(e as Map<String, dynamic>),
    ]..sort((a, b) => b.spentOn.compareTo(a.spentOn)),
  );

  static const select =
      'id, family_id, title, purpose, mode, target_amount, due_date, share_with_clan, status, created_by, revision, '
      'collection_treasurers(user_id), '
      'collection_targets(user_id, amount, profiles(display_name)), '
      'collection_payments(id, payer_id, amount, paid_on, note, receipt_path, status, reject_reason, recorded_by, '
      'created_at, payer:profiles!collection_payments_payer_id_fkey(display_name)), '
      'collection_expenses(id, amount, spent_on, description, receipt_path)';

  final String id;
  final String familyId;
  final String title;
  final String purpose;
  final CollectionMode mode;
  final bool closed;
  final bool shareWithClan;
  final int revision;
  final int? lumpTarget;
  final DateTime? dueDate;
  final String? createdBy;
  final List<String> treasurerIds;
  final List<CollectionTarget> targets;
  final List<CollectionPayment> payments;
  final List<CollectionExpense> expenses;

  int? get target => switch (mode) {
    CollectionMode.lump => lumpTarget,
    CollectionMode.perMember => targets.fold<int>(0, (s, t) => s + t.amount),
    CollectionMode.open => null,
  };

  int _sum(Iterable<CollectionPayment> ps) => ps.fold(0, (s, p) => s + p.amount);
  int get confirmed => _sum(payments.where((p) => p.status == PaymentStatus.confirmed));
  int get pending => _sum(payments.where((p) => p.status == PaymentStatus.pending));
  int get spent => expenses.fold(0, (s, e) => s + e.amount);
  int get balance => confirmed - spent;

  /// Confirmed total per payer.
  int paidBy(String userId) => _sum(payments.where((p) => p.payerId == userId && p.status == PaymentStatus.confirmed));
  int pendingBy(String userId) => _sum(payments.where((p) => p.payerId == userId && p.status == PaymentStatus.pending));

  List<CollectionPayment> get pendingPayments => [
    for (final p in payments)
      if (p.status == PaymentStatus.pending) p,
  ];

  /// Creator, named treasurers, or the home family's owner/admin.
  bool isTreasurer(String? userId, {required bool familyAdmin}) =>
      userId != null && (familyAdmin || createdBy == userId || treasurerIds.contains(userId));
}
