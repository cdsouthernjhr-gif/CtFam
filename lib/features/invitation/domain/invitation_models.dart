DateTime _date(Object? v) => DateTime.parse(v! as String).toLocal();

/// Returned once by `create_invitation`; [code] is never retrievable again.
class CreatedInvitation {
  const CreatedInvitation({required this.id, required this.code, required this.expiresAt});

  factory CreatedInvitation.fromJson(Map<String, dynamic> json) => CreatedInvitation(
    id: json['invitation_id'] as String,
    code: json['code'] as String,
    expiresAt: _date(json['expires_at']),
  );

  final String id;
  final String code;
  final DateTime expiresAt;
}

enum InvitationState { active, expired, exhausted, revoked }

/// Row of `public.invitations` (visible to owner/admin only).
class Invitation {
  const Invitation({
    required this.id,
    required this.tokenHint,
    required this.maxUses,
    required this.useCount,
    required this.requiresApproval,
    required this.expiresAt,
    required this.createdAt,
    this.note,
    this.revokedAt,
    this.createdByName,
  });

  factory Invitation.fromJson(Map<String, dynamic> json) => Invitation(
    id: json['id'] as String,
    tokenHint: json['token_hint'] as String,
    maxUses: json['max_uses'] as int,
    useCount: json['use_count'] as int,
    requiresApproval: json['requires_approval'] as bool,
    expiresAt: _date(json['expires_at']),
    createdAt: _date(json['created_at']),
    note: json['note'] as String?,
    revokedAt: json['revoked_at'] == null ? null : _date(json['revoked_at']),
  );

  final String id;
  final String tokenHint;
  final int maxUses;
  final int useCount;
  final bool requiresApproval;
  final DateTime expiresAt;
  final DateTime createdAt;
  final String? note;
  final DateTime? revokedAt;
  final String? createdByName;

  InvitationState stateAt(DateTime now) {
    if (revokedAt != null) return InvitationState.revoked;
    if (!expiresAt.isAfter(now)) return InvitationState.expired;
    if (useCount >= maxUses) return InvitationState.exhausted;
    return InvitationState.active;
  }
}

class InvitationPreview {
  const InvitationPreview({
    required this.familyName,
    required this.memberCount,
    required this.requiresApproval,
    required this.expiresAt,
  });

  factory InvitationPreview.fromJson(Map<String, dynamic> json) => InvitationPreview(
    familyName: json['family_name'] as String,
    memberCount: json['member_count'] as int,
    requiresApproval: json['requires_approval'] as bool,
    expiresAt: _date(json['expires_at']),
  );

  final String familyName;
  final int memberCount;
  final bool requiresApproval;
  final DateTime expiresAt;
}

/// Statuses returned by `public.redeem_invitation`.
enum RedeemStatus {
  joined,
  pendingApproval,
  alreadyMember,
  invalid,
  expired,
  exhausted,
  revoked,
  suspended,
  familyFull,
  rateLimited;

  static RedeemStatus parse(String? v) => switch (v) {
    'joined' => joined,
    'pending_approval' => pendingApproval,
    'already_member' => alreadyMember,
    'expired' => expired,
    'exhausted' => exhausted,
    'revoked' => revoked,
    'suspended' => suspended,
    'family_full' => familyFull,
    'rate_limited' => rateLimited,
    _ => invalid,
  };

  bool get isSuccess => this == joined || this == pendingApproval || this == alreadyMember;
}

class RedeemResult {
  const RedeemResult(this.status, this.familyId);

  factory RedeemResult.fromJson(Map<String, dynamic> json) =>
      RedeemResult(RedeemStatus.parse(json['status'] as String?), json['family_id'] as String?);

  final RedeemStatus status;
  final String? familyId;
}
