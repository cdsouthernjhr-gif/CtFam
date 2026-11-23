import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/offline/offline_store.dart';
import '../../../shared/providers/supabase_providers.dart';
import '../../family/domain/family_models.dart';

final profileRepositoryProvider = Provider<ProfileRepository>(
  (ref) => ProfileRepository(ref.watch(supabaseClientProvider), offline: ref.watch(offlineStoreProvider)),
);

/// Allowed upload types; the bucket enforces the same list and a 5 MB limit.
const allowedImageTypes = {'image/jpeg', 'image/png', 'image/webp'};
const maxImageBytes = 5 * 1024 * 1024;

String? contentTypeForFileName(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.webp')) return 'image/webp';
  return null;
}

class ProfileRepository {
  ProfileRepository(this._client, {this._offline});

  final SupabaseClient _client;
  final OfflineStore? _offline;
  static const _uuid = Uuid();

  String get _uid {
    final id = _client.auth.currentUser?.id;
    if (id == null) throw const AppFailure(FailureKind.forbidden, 'not signed in');
    return id;
  }

  Future<Profile> me() => _guard(() async {
    final uid = _uid;
    Future<Map<String, dynamic>?> fetch() => _client.from('profiles').select().eq('id', uid).single();
    final store = _offline;
    final row = store == null ? await fetch() : await store.row('profile:me', fetch);
    return Profile.fromJson(row!);
  });

  Future<void> update({String? displayName, String? phone, String? bio, String? locale}) => _guard(() async {
    final patch = <String, dynamic>{
      'display_name': ?displayName?.trim(),
      if (phone != null) 'phone': phone.trim().isEmpty ? null : phone.trim(),
      if (bio != null) 'bio': bio.trim().isEmpty ? null : bio.trim(),
      'locale': ?locale,
    };
    if (patch.isEmpty) return;
    await _client.from('profiles').update(patch).eq('id', _uid);
  });

  /// Uploads into `avatars/{uid}/…` (enforced by Storage RLS) and removes the
  /// previous file.
  Future<String> uploadAvatar(Uint8List bytes, String contentType, {String? previousPath}) => _guard(() async {
    if (!allowedImageTypes.contains(contentType)) {
      throw const AppFailure(FailureKind.storageRejected, 'type');
    }
    if (bytes.lengthInBytes > maxImageBytes) {
      throw const AppFailure(FailureKind.storageRejected, 'size');
    }
    final ext = contentType.split('/').last.replaceAll('jpeg', 'jpg');
    final path = '$_uid/${_uuid.v4()}.$ext';
    final bucket = _client.storage.from('avatars');
    await bucket.uploadBinary(path, bytes, fileOptions: FileOptions(contentType: contentType, upsert: false));
    await _client.from('profiles').update({'avatar_path': path}).eq('id', _uid);
    if (previousPath != null && previousPath.startsWith('$_uid/')) {
      await bucket.remove([previousPath]);
    }
    return path;
  });

  /// Short-lived signed URL (1 hour). Storage only signs objects the caller
  /// may read under RLS.
  Future<String> signedUrl(String bucket, String path) =>
      _guard(() => _client.storage.from(bucket).createSignedUrl(path, 3600));

  Future<String> themeMode() => _guard(() async {
    final row = await _client.from('user_preferences').select('theme_mode').eq('user_id', _uid).maybeSingle();
    return (row?['theme_mode'] as String?) ?? 'system';
  });

  Future<void> setThemeMode(String mode) =>
      _guard(() => _client.from('user_preferences').update({'theme_mode': mode}).eq('user_id', _uid));

  Future<List<String>> accountDeletionBlockers() => _guard(() async {
    final rows = await _client.rpc<List<dynamic>>('account_deletion_blockers');
    return rows.map((r) => (r as Map<String, dynamic>)['family_name'] as String).toList();
  });

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }
}
