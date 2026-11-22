import 'package:familysync/features/invitation/domain/invitation_models.dart';
import 'package:flutter_test/flutter_test.dart';

Invitation _inv({int used = 0, int max = 1, DateTime? expires, DateTime? revoked}) => Invitation(
  id: 'i',
  tokenHint: 'ABCD',
  maxUses: max,
  useCount: used,
  requiresApproval: false,
  expiresAt: expires ?? DateTime(2030),
  createdAt: DateTime(2026),
  revokedAt: revoked,
);

void main() {
  final now = DateTime(2026, 11, 22);

  test('state precedence: revoked > expired > exhausted > active', () {
    expect(_inv().stateAt(now), InvitationState.active);
    expect(_inv(used: 1).stateAt(now), InvitationState.exhausted);
    expect(_inv(expires: now).stateAt(now), InvitationState.expired);
    expect(_inv(used: 1, revoked: now).stateAt(now), InvitationState.revoked);
  });

  test('redeem status parsing covers every server status', () {
    const server = {
      'joined': RedeemStatus.joined,
      'pending_approval': RedeemStatus.pendingApproval,
      'already_member': RedeemStatus.alreadyMember,
      'invalid': RedeemStatus.invalid,
      'expired': RedeemStatus.expired,
      'exhausted': RedeemStatus.exhausted,
      'revoked': RedeemStatus.revoked,
      'suspended': RedeemStatus.suspended,
      'family_full': RedeemStatus.familyFull,
      'rate_limited': RedeemStatus.rateLimited,
    };
    server.forEach((k, v) => expect(RedeemStatus.parse(k), v, reason: k));
    expect(RedeemStatus.parse('something_new'), RedeemStatus.invalid);
    expect(RedeemStatus.joined.isSuccess, isTrue);
    expect(RedeemStatus.exhausted.isSuccess, isFalse);
  });

  test('RedeemResult.fromJson', () {
    final r = RedeemResult.fromJson({'status': 'joined', 'family_id': 'f1'});
    expect(r.status, RedeemStatus.joined);
    expect(r.familyId, 'f1');
  });
}
