import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/offline/offline_store.dart';
import '../../../shared/providers/supabase_providers.dart';
import '../domain/tree_models.dart';

final treeRepositoryProvider = Provider<TreeRepository>(
  (ref) => TreeRepository(ref.watch(supabaseClientProvider), offline: ref.watch(offlineStoreProvider)),
);

String _date(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class TreeRepository {
  TreeRepository(this._client, {this._offline});

  final SupabaseClient _client;
  final OfflineStore? _offline;

  Future<List<Map<String, dynamic>>> _rows(String key, Future<List<dynamic>> Function() fetch) {
    final store = _offline;
    if (store == null) return fetch().then((r) => [for (final x in r) Map<String, dynamic>.from(x as Map)]);
    return store.rows(key, fetch);
  }

  /// People and relations (confirmed and pending) of one family; readable
  /// offline from the last copy.
  Future<TreeData> load(String familyId) => _guard(() async {
    final results = await Future.wait([
      _rows(
        'tree:persons:$familyId',
        () => _client
            .from('family_persons')
            .select(TreePerson.select)
            .eq('family_id', familyId)
            .isFilter('deleted_at', null)
            .order('birth_date'),
      ),
      _rows(
        'tree:relations:$familyId',
        () => _client
            .from('family_relations')
            .select(TreeRelation.select)
            .eq('family_id', familyId)
            .isFilter('deleted_at', null)
            .neq('status', 'rejected'),
      ),
    ]);
    return TreeData(
      persons: results[0].map(TreePerson.fromJson).toList(),
      relations: results[1].map(TreeRelation.fromJson).toList(),
    );
  });

  /// How [targetId] is related to [fromId] (default: the signed-in user).
  Future<Relationship> relationship(String familyId, String targetId, {String? fromId}) => _guard(() async {
    final res = await _client.rpc<dynamic>(
      'relationship_between',
      params: {'p_family_id': familyId, 'p_target': targetId, 'p_from': fromId},
    );
    return Relationship.fromJson(Map<String, dynamic>.from(res as Map));
  });

  /// Admins: anyone. Members: only their own record ([linkSelf] on create).
  Future<TreePerson> upsertPerson({
    required String id,
    required String familyId,
    required String fullName,
    required Gender gender,
    required DateTime birthDate,
    DateTime? deathDate,
    String? notes,
    bool linkSelf = false,
    int? expectedRevision,
  }) => _guard(() async {
    final row = await _client.rpc<Map<String, dynamic>>(
      'upsert_person',
      params: {
        'p_id': id,
        'p_family_id': familyId,
        'p_full_name': fullName.trim(),
        'p_gender': gender.name,
        'p_birth_date': _date(birthDate),
        'p_death_date': deathDate == null ? null : _date(deathDate),
        'p_notes': notes?.trim(),
        'p_link_self': linkSelf,
        'p_expected_revision': expectedRevision,
      },
    );
    return TreePerson.fromJson(row);
  });

  Future<void> linkAccount(String personId, String? userId) => _guard(
    () => _client.rpc<Map<String, dynamic>>(
      'link_person_account',
      params: {'p_person_id': personId, 'p_user_id': userId},
    ),
  );

  Future<void> deletePerson(String personId) =>
      _guard(() => _client.rpc<void>('delete_person', params: {'p_person_id': personId}));

  /// [RelationKind.parent]: [personA] is the parent of [personB].
  Future<TreeRelation> proposeRelation({
    required String id,
    required String familyId,
    required RelationKind kind,
    required String personA,
    required String personB,
    bool adoptive = false,
  }) => _guard(() async {
    final row = await _client.rpc<Map<String, dynamic>>(
      'propose_relation',
      params: {
        'p_id': id,
        'p_family_id': familyId,
        'p_kind': kind.name,
        'p_person_a': personA,
        'p_person_b': personB,
        'p_parent_type': adoptive ? 'adoptive' : 'biological',
      },
    );
    return TreeRelation.fromJson(row);
  });

  Future<void> reviewRelation(String id, {required bool approve}) =>
      _guard(() => _client.rpc<Map<String, dynamic>>('review_relation', params: {'p_id': id, 'p_approve': approve}));

  Future<void> deleteRelation(String id) => _guard(() => _client.rpc<void>('delete_relation', params: {'p_id': id}));

  /// Tree changes on channel `tree:{familyId}` (RLS-filtered). Emits after
  /// each change and after (re)subscribing.
  Stream<void> watch(String familyId) {
    late final RealtimeChannel channel;
    final controller = StreamController<void>.broadcast();
    controller.onListen = () {
      channel = _client.channel('tree:$familyId');
      for (final table in ['family_persons', 'family_relations']) {
        channel.onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: table,
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'family_id', value: familyId),
          callback: (_) => controller.add(null),
        );
      }
      channel.subscribe((status, _) {
        if (status == RealtimeSubscribeStatus.subscribed) controller.add(null);
      });
    };
    controller.onCancel = () async {
      await _client.removeChannel(channel);
      await controller.close();
    };
    return controller.stream;
  }

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }
}
