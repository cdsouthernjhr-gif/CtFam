import 'package:familysync/features/family/domain/family_models.dart';
import 'package:familysync/features/family/domain/family_permissions.dart';
import 'package:flutter_test/flutter_test.dart';

FamilyMember _m(String id, FamilyRole role) =>
    FamilyMember(id: id, familyId: 'f', userId: id, role: role, status: MemberStatus.active);

void main() {
  const family = Family(id: 'f', name: 'F', allowAdminInvites: true);
  const noAdminInvites = Family(id: 'f', name: 'F', allowAdminInvites: false);

  test('UI mirror of server role hierarchy', () {
    expect(FamilyPermissions.canManage(FamilyRole.owner, _m('b', FamilyRole.admin), myUserId: 'a'), isTrue);
    expect(FamilyPermissions.canManage(FamilyRole.admin, _m('b', FamilyRole.admin), myUserId: 'a'), isFalse);
    expect(FamilyPermissions.canManage(FamilyRole.admin, _m('b', FamilyRole.owner), myUserId: 'a'), isFalse);
    expect(FamilyPermissions.canManage(FamilyRole.admin, _m('b', FamilyRole.moderator), myUserId: 'a'), isTrue);
    expect(FamilyPermissions.canManage(FamilyRole.moderator, _m('b', FamilyRole.member), myUserId: 'a'), isFalse);
    expect(
      FamilyPermissions.canManage(FamilyRole.owner, _m('a', FamilyRole.owner), myUserId: 'a'),
      isFalse,
      reason: 'nobody manages themselves',
    );
  });

  test('assignable roles never include owner or own level', () {
    expect(FamilyPermissions.assignableRoles(FamilyRole.owner), [
      FamilyRole.admin,
      FamilyRole.moderator,
      FamilyRole.member,
    ]);
    expect(FamilyPermissions.assignableRoles(FamilyRole.admin), [FamilyRole.moderator, FamilyRole.member]);
    expect(FamilyPermissions.assignableRoles(FamilyRole.member), isEmpty);
  });

  test('invitation rights', () {
    expect(FamilyPermissions.canInvite(FamilyRole.owner, noAdminInvites), isTrue);
    expect(FamilyPermissions.canInvite(FamilyRole.admin, family), isTrue);
    expect(FamilyPermissions.canInvite(FamilyRole.admin, noAdminInvites), isFalse);
    expect(FamilyPermissions.canInvite(FamilyRole.moderator, family), isFalse);
  });

  test('role parsing is defensive', () {
    expect(FamilyRole.parse('owner'), FamilyRole.owner);
    expect(FamilyRole.parse('superuser'), FamilyRole.member);
    expect(MemberStatus.parse('weird'), MemberStatus.removed);
  });
}
