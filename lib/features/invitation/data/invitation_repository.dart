import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/utils/invite_code.dart';
import '../../../shared/providers/supabase_providers.dart';
import '../domain/invitation_models.dart';

final invitationRepositoryProvider = Provider<InvitationRepository>(
  (ref) => InvitationRepository(ref.watch(supabaseClientProvider)),
);

/// All invitation logic is enforced server-side (hashing, expiry, usage,
/// replay, rate limits). This class only transports requests.
class InvitationRepository {
  InvitationRepository(this._client);

  final SupabaseClient _client;

  Future<CreatedInvitation> create({
    required String familyId,
    required int maxUses,
    required int expiresInHours,
    bool? requiresApproval,
    String? note,
  }) => _guard(() async {
    final rows = await _client.rpc<List<dynamic>>(
      'create_invitation',
      params: {
        'p_family_id': familyId,
        'p_max_uses': maxUses,
        'p_expires_in_hours': expiresInHours,
        'p_requires_approval': requiresApproval,
        'p_note': note?.trim(),
      },
    );
    return CreatedInvitation.fromJson(rows.first as Map<String, dynamic>);
  });

  Future<List<Invitation>> list(String familyId) => _guard(() async {
    final rows = await _client
        .from('invitations')
        .select(
          'id, token_hint, max_uses, use_count, requires_approval, expires_at, '
          'created_at, note, revoked_at',
        )
        .eq('family_id', familyId)
        .order('created_at', ascending: false)
        .limit(100);
    return rows.map(Invitation.fromJson).toList();
  });

  Future<void> revoke(String invitationId) =>
      _guard(() => _client.rpc<void>('revoke_invitation', params: {'p_invitation_id': invitationId}));

  /// Returns null when the code is invalid, expired, used up or revoked.
  Future<InvitationPreview?> preview(String code) => _guard(() async {
    final rows = await _client.rpc<List<dynamic>>('preview_invitation', params: {'p_code': InviteCode.normalize(code)});
    if (rows.isEmpty) return null;
    return InvitationPreview.fromJson(rows.first as Map<String, dynamic>);
  });

  Future<RedeemResult> redeem(String code) => _guard(() async {
    final res = await _client.rpc<Map<String, dynamic>>(
      'redeem_invitation',
      params: {'p_code': InviteCode.normalize(code)},
    );
    return RedeemResult.fromJson(res);
  });

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }
}
