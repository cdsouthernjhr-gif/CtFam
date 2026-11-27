import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/errors/app_failure.dart';
import '../../../shared/providers/supabase_providers.dart';
import '../domain/collection_models.dart';

final collectionsRepositoryProvider = Provider<CollectionsRepository>(
  (ref) => CollectionsRepository(ref.watch(supabaseClientProvider)),
);

/// Money collections. Records money; it never moves it.
class CollectionsRepository {
  CollectionsRepository(this._client);

  final SupabaseClient _client;
  static const receiptBucket = 'collection-receipts';
  static const _uuid = Uuid();

  static String newId() => _uuid.v4();

  Future<List<CollectionSummary>> summaries(String familyId) => _guard(() async {
    final rows = await _client.rpc<List<dynamic>>('collection_summaries', params: {'p_family_id': familyId});
    return rows.map((r) => CollectionSummary.fromJson(Map<String, dynamic>.from(r as Map))).toList();
  });

  Future<Collection?> collection(String id) => _guard(() async {
    final row = await _client
        .from('collections')
        .select(Collection.select)
        .eq('id', id)
        .isFilter('deleted_at', null)
        .maybeSingle();
    return row == null ? null : Collection.fromJson(row);
  });

  /// Create (client id) or edit. [memberTargets] in sen, by user id.
  Future<void> upsert({
    required String id,
    required String familyId,
    required String title,
    required String purpose,
    required CollectionMode mode,
    int? lumpTarget,
    DateTime? dueDate,
    bool shareWithClan = false,
    List<String>? treasurerIds,
    Map<String, int>? memberTargets,
    int? expectedRevision,
  }) => _guard(
    () => _client.rpc<Map<String, dynamic>>(
      'upsert_collection',
      params: {
        'p_id': id,
        'p_family_id': familyId,
        'p_title': title.trim(),
        'p_purpose': purpose.trim(),
        'p_mode': mode.key,
        'p_target_amount': mode == CollectionMode.lump && lumpTarget != null ? toAmount(lumpTarget) : null,
        'p_due_date': dueDate == null ? null : _dateOnly(dueDate),
        'p_share_with_clan': shareWithClan,
        'p_treasurer_ids': treasurerIds,
        'p_member_targets': mode == CollectionMode.perMember && memberTargets != null
            ? [
                for (final e in memberTargets.entries) {'user_id': e.key, 'amount': toAmount(e.value)},
              ]
            : null,
        'p_expected_revision': expectedRevision,
      },
    ),
  );

  Future<void> setClosed(String id, {required bool closed}) => _guard(
    () => _client.rpc<Map<String, dynamic>>('set_collection_status', params: {'p_id': id, 'p_closed': closed}),
  );

  Future<void> delete(String id) => _guard(() => _client.rpc<void>('delete_collection', params: {'p_id': id}));

  /// Records a payment (own: pending; treasurer for someone: confirmed).
  /// An optional receipt photo is uploaded first (needs a connection).
  Future<void> recordPayment({
    required Collection collection,
    required int amount,
    required DateTime paidOn,
    String? note,
    String? payerId,
    (Uint8List, String)? receipt,
  }) => _guard(() async {
    final path = receipt == null ? null : await _upload(collection, receipt.$1, receipt.$2);
    try {
      await _client.rpc<Map<String, dynamic>>(
        'record_collection_payment',
        params: {
          'p_id': newId(),
          'p_collection_id': collection.id,
          'p_amount': toAmount(amount),
          'p_paid_on': _dateOnly(paidOn),
          'p_note': note?.trim(),
          'p_receipt_path': path,
          'p_payer_id': payerId,
        },
      );
    } catch (_) {
      await _removeQuietly(path);
      rethrow;
    }
  });

  Future<void> reviewPayment(String paymentId, {required bool approve, String? reason}) => _guard(
    () => _client.rpc<Map<String, dynamic>>(
      'review_collection_payment',
      params: {'p_id': paymentId, 'p_approve': approve, 'p_reason': reason?.trim()},
    ),
  );

  Future<void> deletePayment(String paymentId) => _guard(() async {
    final path = await _client.rpc<String?>('delete_collection_payment', params: {'p_id': paymentId});
    await _removeQuietly(path);
  });

  Future<void> recordExpense({
    required Collection collection,
    required int amount,
    required String description,
    required DateTime spentOn,
    (Uint8List, String)? receipt,
  }) => _guard(() async {
    final path = receipt == null ? null : await _upload(collection, receipt.$1, receipt.$2);
    try {
      await _client.rpc<Map<String, dynamic>>(
        'record_collection_expense',
        params: {
          'p_id': newId(),
          'p_collection_id': collection.id,
          'p_amount': toAmount(amount),
          'p_description': description.trim(),
          'p_spent_on': _dateOnly(spentOn),
          'p_receipt_path': path,
        },
      );
    } catch (_) {
      await _removeQuietly(path);
      rethrow;
    }
  });

  Future<void> deleteExpense(String expenseId) => _guard(() async {
    final path = await _client.rpc<String?>('delete_collection_expense', params: {'p_id': expenseId});
    await _removeQuietly(path);
  });

  /// Reminds everyone who still owes; returns how many were notified.
  Future<int> remind(String id) => _guard(() async {
    final n = await _client.rpc<int>('remind_collection', params: {'p_id': id});
    return n;
  });

  /// Changes to one collection (its row, payments, expenses).
  Stream<void> watch(String id) {
    late final RealtimeChannel channel;
    final controller = StreamController<void>.broadcast();
    controller.onListen = () {
      channel = _client.channel('collection:$id');
      for (final (table, column) in [
        ('collections', 'id'),
        ('collection_payments', 'collection_id'),
        ('collection_expenses', 'collection_id'),
      ]) {
        channel.onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: table,
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: column, value: id),
          callback: (_) => controller.add(null),
        );
      }
      channel.subscribe();
    };
    controller.onCancel = () async {
      await _client.removeChannel(channel);
      await controller.close();
    };
    return controller.stream;
  }

  Future<String> _upload(Collection c, Uint8List bytes, String contentType) async {
    final ext = switch (contentType) {
      'image/png' => 'png',
      'image/webp' => 'webp',
      _ => 'jpg',
    };
    final path = '${c.familyId}/${c.id}/${_uuid.v4()}.$ext';
    await _client.storage
        .from(receiptBucket)
        .uploadBinary(path, bytes, fileOptions: FileOptions(contentType: contentType));
    return path;
  }

  Future<void> _removeQuietly(String? path) async {
    if (path == null) return;
    try {
      await _client.storage.from(receiptBucket).remove([path]);
    } catch (_) {}
  }

  static String _dateOnly(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }
}
