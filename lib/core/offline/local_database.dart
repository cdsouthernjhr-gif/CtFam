import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'local_database.g.dart';

/// Last known server responses (raw JSON rows), per signed-in user.
/// Used to show data when the device is offline.
class CacheEntries extends Table {
  TextColumn get owner => text()();
  TextColumn get key => text()();
  TextColumn get json => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {owner, key};
}

/// Writes made while offline, replayed in order when the connection returns.
/// Every replayed RPC is idempotent on the server (client-generated ids,
/// "set" semantics), so a retry after an unknown outcome is safe.
class OutboxOps extends Table {
  /// Insertion order (timestamps can tie); ops replay strictly in this order.
  IntColumn get seq => integer().autoIncrement()();
  TextColumn get id => text().unique()();
  TextColumn get owner => text()();
  TextColumn get kind => text()();

  /// Entity the op changes (todo item, message, event).
  TextColumn get entityId => text()();

  /// Container for UI grouping (list, conversation, event).
  TextColumn get scope => text()();
  TextColumn get payload => text()();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();

  /// pending | failed
  TextColumn get status => text().withDefault(const Constant('pending'))();
  TextColumn get lastError => text().nullable()();
}

@DriftDatabase(tables: [CacheEntries, OutboxOps])
class LocalDatabase extends _$LocalDatabase {
  LocalDatabase([QueryExecutor? executor]) : super(executor ?? driftDatabase(name: 'familysync_offline'));

  @override
  int get schemaVersion => 1;

  // ------------------------------------------------------------------ cache
  Future<String?> readCache(String owner, String key) async {
    final row = await (select(cacheEntries)..where((t) => t.owner.equals(owner) & t.key.equals(key))).getSingleOrNull();
    return row?.json;
  }

  Future<void> writeCache(String owner, String key, String json) => into(
    cacheEntries,
  ).insertOnConflictUpdate(CacheEntriesCompanion.insert(owner: owner, key: key, json: json, updatedAt: DateTime.now()));

  // ------------------------------------------------------------------ outbox
  Future<void> enqueue(OutboxOpsCompanion op) => into(outboxOps).insert(op);

  Stream<List<OutboxOp>> watchOutbox(String owner) =>
      (select(outboxOps)
            ..where((t) => t.owner.equals(owner))
            ..orderBy([(t) => OrderingTerm.asc(t.seq)]))
          .watch();

  Future<List<OutboxOp>> allOps(String owner) =>
      (select(outboxOps)
            ..where((t) => t.owner.equals(owner))
            ..orderBy([(t) => OrderingTerm.asc(t.seq)]))
          .get();

  Future<List<OutboxOp>> pendingOps(String owner) =>
      (select(outboxOps)
            ..where((t) => t.owner.equals(owner) & t.status.equals('pending'))
            ..orderBy([(t) => OrderingTerm.asc(t.seq)]))
          .get();

  Future<List<OutboxOp>> opsForScope(String owner, String scope) =>
      (select(outboxOps)
            ..where((t) => t.owner.equals(owner) & t.scope.equals(scope))
            ..orderBy([(t) => OrderingTerm.asc(t.seq)]))
          .get();

  Future<void> removeOp(String id) => (delete(outboxOps)..where((t) => t.id.equals(id))).go();

  Future<void> markAttempt(String id, {required bool failed, String? error}) =>
      (update(outboxOps)..where((t) => t.id.equals(id))).write(
        OutboxOpsCompanion.custom(
          attempts: outboxOps.attempts + const Constant(1),
          status: Constant(failed ? 'failed' : 'pending'),
          lastError: Constant(error),
        ),
      );

  Future<void> resetFailed(String owner) =>
      (update(outboxOps)..where((t) => t.owner.equals(owner) & t.status.equals('failed'))).write(
        const OutboxOpsCompanion(status: Value('pending'), lastError: Value(null)),
      );

  /// Removes everything stored for other accounts (shared device) or, with
  /// [owner] null, everything (sign-out).
  Future<void> wipe({String? keepOwner}) => transaction(() async {
    if (keepOwner == null) {
      await delete(cacheEntries).go();
      await delete(outboxOps).go();
    } else {
      await (delete(cacheEntries)..where((t) => t.owner.equals(keepOwner).not())).go();
      await (delete(outboxOps)..where((t) => t.owner.equals(keepOwner).not())).go();
    }
  });
}
