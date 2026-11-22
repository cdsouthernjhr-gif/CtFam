import 'family_models.dart';

/// UI-only mirror of the server rules in the foundation migration.
///
/// These decide which buttons to SHOW. They are not a security boundary: every
/// action is re-checked by the database (RLS + SECURITY DEFINER RPCs).
abstract final class FamilyPermissions {
  static bool canEditFamily(FamilyRole me) => me == FamilyRole.owner || me == FamilyRole.admin;

  static bool canInvite(FamilyRole me, Family family) =>
      me == FamilyRole.owner || (me == FamilyRole.admin && family.allowAdminInvites);

  static bool canViewInvitations(FamilyRole me) => canEditFamily(me);

  /// Owner manages everyone below them; admin manages moderators and members.
  static bool canManage(FamilyRole me, FamilyMember target, {required String myUserId}) {
    if (target.userId == myUserId) return false;
    if (!(me == FamilyRole.owner || me == FamilyRole.admin)) return false;
    return me.rank > target.role.rank;
  }

  /// Roles the caller may assign to someone they can manage.
  static List<FamilyRole> assignableRoles(FamilyRole me) =>
      FamilyRole.values.where((r) => r != FamilyRole.owner && r.rank < me.rank).toList();

  static bool canTransferOwnership(FamilyRole me) => me == FamilyRole.owner;
  static bool canDeleteFamily(FamilyRole me) => me == FamilyRole.owner;
}
