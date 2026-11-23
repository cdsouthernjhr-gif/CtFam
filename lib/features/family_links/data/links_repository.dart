import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_failure.dart';
import '../../../shared/providers/supabase_providers.dart';
import '../domain/link_models.dart';

final linksRepositoryProvider = Provider<LinksRepository>((ref) => LinksRepository(ref.watch(supabaseClientProvider)));

class LinksRepository {
  LinksRepository(this._client);

  final SupabaseClient _client;

  Future<List<LinkedFamily>> clan(String familyId) => _guard(() async {
    final rows = await _client.rpc<List<dynamic>>('linked_families', params: {'p_family_id': familyId});
    return rows.map((r) => LinkedFamily.fromJson(Map<String, dynamic>.from(r as Map))).toList();
  });

  Future<List<LinkRequest>> requests(String familyId) => _guard(() async {
    final rows = await _client.rpc<List<dynamic>>('family_link_requests', params: {'p_family_id': familyId});
    return rows.map((r) => LinkRequest.fromJson(Map<String, dynamic>.from(r as Map))).toList();
  });

  /// [childFamilyId] becomes a branch of [parentFamilyId].
  Future<bool> request({required String parentFamilyId, required String childFamilyId}) => _guard(() async {
    final row = await _client.rpc<Map<String, dynamic>>(
      'request_family_link',
      params: {'p_parent_family_id': parentFamilyId, 'p_child_family_id': childFamilyId},
    );
    return row['status'] == 'active';
  });

  Future<void> respond(String linkId, {required bool approve}) => _guard(
    () => _client.rpc<Map<String, dynamic>>('respond_family_link', params: {'p_link_id': linkId, 'p_approve': approve}),
  );

  /// Removes an active link or withdraws a pending request.
  Future<void> remove(String linkId) =>
      _guard(() => _client.rpc<void>('remove_family_link', params: {'p_link_id': linkId}));

  /// Id of the link row that makes [childFamilyId] a branch (if any).
  Future<String?> linkIdForChild(String childFamilyId) => _guard(() async {
    final row = await _client.from('family_links').select('id').eq('child_family_id', childFamilyId).maybeSingle();
    return row?['id'] as String?;
  });

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }
}
