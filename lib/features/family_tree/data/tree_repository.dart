import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

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

  /// People, relations and pending merges of the whole clan of [familyId]
  /// (linked families share one tree). Readable offline from the last copy.
  Future<TreeData> load(String familyId) => _guard(() async {
    final clan = await _rows(
      'tree:clan:$familyId',
      () => _client.rpc<List<dynamic>>('linked_families', params: {'p_family_id': familyId}),
    );
    final names = {for (final f in clan) f['family_id'] as String: f['name'] as String};
    final ids = names.isEmpty ? [familyId] : names.keys.toList();
    final results = await Future.wait([
      _rows(
        'tree:persons:$familyId',
        () => _client
            .from('family_persons')
            .select(TreePerson.select)
            .inFilter('family_id', ids)
            .isFilter('deleted_at', null)
            .order('birth_date'),
      ),
      _rows(
        'tree:relations:$familyId',
        () => _client
            .from('family_relations')
            .select(TreeRelation.select)
            .inFilter('family_id', ids)
            .isFilter('deleted_at', null)
            .neq('status', 'rejected'),
      ),
      _rows(
        'tree:merges:$familyId',
        () => _client.from('person_merges').select('id, keep_id, remove_id').eq('status', 'pending'),
      ),
    ]);
    final persons = results[0].map(TreePerson.fromJson).toList();
    final personIds = {for (final p in persons) p.id};
    return TreeData(
      persons: persons,
      relations: results[1].map(TreeRelation.fromJson).toList(),
      familyNames: names,
      merges: results[2]
          .map(PersonMerge.fromJson)
          .where((m) => personIds.contains(m.keepId) && personIds.contains(m.removeId))
          .toList(),
    );
  });

  Future<List<MergeSuggestion>> mergeSuggestions(String familyId) => _guard(() async {
    final rows = await _client.rpc<List<dynamic>>('merge_suggestions', params: {'p_family_id': familyId});
    return rows.map((r) => MergeSuggestion.fromJson(Map<String, dynamic>.from(r as Map))).toList();
  });

  /// 'done' (merged now) or 'pending' (the other family's admin must approve).
  Future<String> mergePersons({required String keepId, required String removeId}) => _guard(
    () async =>
        (await _client.rpc<dynamic>('merge_persons', params: {'p_keep': keepId, 'p_remove': removeId})) as String,
  );

  Future<void> reviewMerge(String mergeId, {required bool approve}) =>
      _guard(() => _client.rpc<dynamic>('review_person_merge', params: {'p_merge_id': mergeId, 'p_approve': approve}));

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

  Future<void> deletePerson(String personId, {String? photoPath}) => _guard(() async {
    await _client.rpc<void>('delete_person', params: {'p_person_id': personId});
    await _removeQuietly(photoPath);
  });

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

  // ---------------------------------------------------------------- photos
  static const photoBucket = 'tree-photos';
  static const _uuid = Uuid();

  static String _ext(String contentType) => switch (contentType) {
    'image/png' => 'png',
    'image/webp' => 'webp',
    _ => 'jpg',
  };

  Future<String> _upload(String folder, Uint8List bytes, String contentType) async {
    final path = '$folder/${_uuid.v4()}.${_ext(contentType)}';
    await _client.storage
        .from(photoBucket)
        .uploadBinary(path, bytes, fileOptions: FileOptions(contentType: contentType));
    return path;
  }

  /// Old files are removed after the new path is saved; a failed removal
  /// only leaves an unreferenced file behind.
  Future<void> _removeQuietly(String? path) async {
    if (path == null) return;
    try {
      await _client.storage.from(photoBucket).remove([path]);
    } catch (_) {}
  }

  /// Uploads a new photo for [person] (admins: anyone; members: themselves).
  Future<void> setPersonPhoto(TreePerson person, Uint8List bytes, String contentType) => _guard(() async {
    final path = await _upload('${person.familyId}/${person.id}', bytes, contentType);
    try {
      await _client.rpc<Map<String, dynamic>>('set_person_photo', params: {'p_person_id': person.id, 'p_path': path});
    } catch (_) {
      await _removeQuietly(path);
      rethrow;
    }
    await _removeQuietly(person.photoPath);
  });

  Future<void> removePersonPhoto(TreePerson person) => _guard(() async {
    await _client.rpc<Map<String, dynamic>>('set_person_photo', params: {'p_person_id': person.id, 'p_path': null});
    await _removeQuietly(person.photoPath);
  });

  /// Tree cover photo (owner/admin).
  Future<void> setTreePhoto(String familyId, Uint8List bytes, String contentType, {String? previousPath}) =>
      _guard(() async {
        final path = await _upload('$familyId/cover', bytes, contentType);
        try {
          await _client.rpc<dynamic>('set_tree_photo', params: {'p_family_id': familyId, 'p_path': path});
        } catch (_) {
          await _removeQuietly(path);
          rethrow;
        }
        await _removeQuietly(previousPath);
      });

  Future<void> removeTreePhoto(String familyId, String? previousPath) => _guard(() async {
    await _client.rpc<dynamic>('set_tree_photo', params: {'p_family_id': familyId, 'p_path': null});
    await _removeQuietly(previousPath);
  });

  /// Tree changes anywhere in the clan (channel `tree:{familyId}`). Rows are
  /// filtered by RLS to the families the user may see; extra refreshes from
  /// another clan of the user are harmless. Emits after (re)subscribing too.
  Stream<void> watch(String familyId) {
    late final RealtimeChannel channel;
    final controller = StreamController<void>.broadcast();
    controller.onListen = () {
      channel = _client.channel('tree:$familyId');
      for (final table in ['family_persons', 'family_relations', 'person_merges']) {
        channel.onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: table,
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
