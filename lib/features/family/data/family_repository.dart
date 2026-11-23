import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/offline/offline_store.dart';
import '../../../shared/providers/supabase_providers.dart';
import '../domain/family_models.dart';

final familyRepositoryProvider = Provider<FamilyRepository>(
  (ref) => FamilyRepository(ref.watch(supabaseClientProvider), offline: ref.watch(offlineStoreProvider)),
);

class FamilyRepository {
  FamilyRepository(this._client, {this._offline});

  final SupabaseClient _client;
  final OfflineStore? _offline;

  // Offline: last successful responses are served when the network is down.
  Future<List<Map<String, dynamic>>> _cachedRows(String key, Future<List<dynamic>> Function() fetch) {
    final store = _offline;
    if (store == null) return fetch().then((r) => [for (final x in r) Map<String, dynamic>.from(x as Map)]);
    return store.rows(key, fetch);
  }

  Future<Map<String, dynamic>?> _cachedRow(String key, Future<Map<String, dynamic>?> Function() fetch) {
    final store = _offline;
    return store == null ? fetch() : store.row(key, fetch);
  }

  static const _uuid = Uuid();

  String get _uid {
    final id = _client.auth.currentUser?.id;
    if (id == null) throw const AppFailure(FailureKind.forbidden, 'not signed in');
    return id;
  }

  Future<List<MyMembership>> myMemberships() => _guard(() async {
    final uid = _uid;
    final rows = await _cachedRows(
      'family:memberships',
      () => _client
          .from('family_members')
          .select(
            'family_id, role, status, '
            'families(id, name, description, image_path, require_invite_approval, '
            'allow_admin_invites, max_members, created_at)',
          )
          .eq('user_id', uid)
          .inFilter('status', ['active', 'pending']),
    );
    return rows.map(MyMembership.fromJson).toList();
  });

  Future<String?> activeFamilyPreference() => _guard(() async {
    final uid = _uid;
    final row = await _cachedRow(
      'family:active',
      () => _client.from('user_preferences').select('active_family_id').eq('user_id', uid).maybeSingle(),
    );
    return row?['active_family_id'] as String?;
  });

  Future<void> setActiveFamily(String familyId) =>
      _guard(() => _client.from('user_preferences').update({'active_family_id': familyId}).eq('user_id', _uid));

  Future<String> createFamily({required String name, String? description}) => _guard(() async {
    final id = await _client.rpc<String>(
      'create_family',
      params: {'p_name': name.trim(), 'p_description': description?.trim()},
    );
    return id;
  });

  Future<Family> family(String familyId) => _guard(() async {
    final row = await _cachedRow(
      'family:$familyId',
      () => _client.from('families').select().eq('id', familyId).single(),
    );
    return Family.fromJson(row!);
  });

  Future<void> updateFamily(
    String familyId, {
    String? name,
    String? description,
    bool? requireInviteApproval,
    bool? allowAdminInvites,
    String? imagePath,
  }) => _guard(() async {
    final patch = <String, dynamic>{
      'name': ?name?.trim(),
      'description': ?description?.trim(),
      'require_invite_approval': ?requireInviteApproval,
      'allow_admin_invites': ?allowAdminInvites,
      'image_path': ?imagePath,
    };
    if (patch.isEmpty) return;
    await _client.from('families').update(patch).eq('id', familyId);
  });

  Future<String> uploadFamilyImage(String familyId, Uint8List bytes, String contentType) => _guard(() async {
    final ext = _extensionFor(contentType);
    final path = '$familyId/${_uuid.v4()}.$ext';
    await _client.storage
        .from('family-media')
        .uploadBinary(path, bytes, fileOptions: FileOptions(contentType: contentType, upsert: false));
    await updateFamily(familyId, imagePath: path);
    return path;
  });

  Future<List<FamilyMember>> members(String familyId) => _guard(() async {
    final rows = await _cachedRows(
      'family:members:$familyId',
      () => _client.from('family_members').select(FamilyMember.select).eq('family_id', familyId).inFilter('status', [
        'active',
        'pending',
        'suspended',
      ]),
    );
    final list = rows.map(FamilyMember.fromJson).toList()
      ..sort((a, b) {
        final byRole = b.role.rank.compareTo(a.role.rank);
        if (byRole != 0) return byRole;
        return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
      });
    return list;
  });

  Future<List<ActivityEntry>> activity(String familyId, {int limit = 50}) => _guard(() async {
    final rows = await _cachedRows(
      'family:activity:$familyId',
      () => _client
          .from('audit_logs')
          .select('id, action, created_at, actor_id, target_id, details, profiles(display_name)')
          .eq('family_id', familyId)
          .order('created_at', ascending: false)
          .limit(limit),
    );
    return rows.map(ActivityEntry.fromJson).toList();
  });

  Future<void> reviewMembership(String familyId, String userId, {required bool approve}) =>
      _rpc('review_membership', {'p_family_id': familyId, 'p_user_id': userId, 'p_approve': approve});

  Future<void> setRole(String familyId, String userId, FamilyRole role) =>
      _rpc('set_member_role', {'p_family_id': familyId, 'p_user_id': userId, 'p_role': role.name});

  Future<void> setStatus(String familyId, String userId, MemberStatus status) =>
      _rpc('set_member_status', {'p_family_id': familyId, 'p_user_id': userId, 'p_status': status.name});

  Future<void> transferOwnership(String familyId, String newOwnerId) =>
      _rpc('transfer_ownership', {'p_family_id': familyId, 'p_new_owner': newOwnerId});

  Future<void> leaveFamily(String familyId) => _rpc('leave_family', {'p_family_id': familyId});

  Future<void> deleteFamily(String familyId, String confirmName) =>
      _rpc('delete_family', {'p_family_id': familyId, 'p_confirm_name': confirmName});

  Future<void> updateNickname(String familyId, String? nickname) => _guard(
    () => _client
        .from('family_members')
        .update({'nickname': (nickname?.trim().isEmpty ?? true) ? null : nickname!.trim()})
        .eq('family_id', familyId)
        .eq('user_id', _uid),
  );

  /// Emits whenever membership or family rows of [familyId] change.
  /// Channel: `family:{familyId}`. Postgres Changes are filtered by RLS.
  Stream<void> watchFamily(String familyId) {
    late final RealtimeChannel channel;
    final controller = StreamController<void>.broadcast();
    controller.onListen = () {
      channel = _client
          .channel('family:$familyId')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'family_members',
            filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'family_id', value: familyId),
            callback: (_) => controller.add(null),
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'families',
            filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'id', value: familyId),
            callback: (_) => controller.add(null),
          )
          .subscribe((status, _) {
            // After a reconnect, reconcile with the database.
            if (status == RealtimeSubscribeStatus.subscribed) controller.add(null);
          });
    };
    controller.onCancel = () async {
      await _client.removeChannel(channel);
      await controller.close();
    };
    return controller.stream;
  }

  Future<void> _rpc(String fn, Map<String, dynamic> params) => _guard(() => _client.rpc<void>(fn, params: params));

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }
}

String _extensionFor(String contentType) => switch (contentType) {
  'image/png' => 'png',
  'image/webp' => 'webp',
  _ => 'jpg',
};
