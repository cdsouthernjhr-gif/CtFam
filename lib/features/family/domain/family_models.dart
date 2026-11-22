/// Typed models matching `supabase/migrations/20261122000100_foundation.sql`.
library;

enum FamilyRole {
  owner,
  admin,
  moderator,
  member;

  static FamilyRole parse(String? v) =>
      FamilyRole.values.firstWhere((r) => r.name == v, orElse: () => FamilyRole.member);

  /// Mirrors `private.role_rank`.
  int get rank => switch (this) {
    FamilyRole.owner => 4,
    FamilyRole.admin => 3,
    FamilyRole.moderator => 2,
    FamilyRole.member => 1,
  };
}

enum MemberStatus {
  pending,
  active,
  suspended,
  removed,
  left;

  static MemberStatus parse(String? v) =>
      MemberStatus.values.firstWhere((s) => s.name == v, orElse: () => MemberStatus.removed);
}

DateTime? _date(Object? v) => v == null ? null : DateTime.parse(v as String).toLocal();

class Profile {
  const Profile({
    required this.id,
    required this.displayName,
    this.avatarPath,
    this.phone,
    this.bio,
    this.locale = 'ms',
    this.lastSeenAt,
  });

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
    id: json['id'] as String,
    displayName: (json['display_name'] as String?) ?? '',
    avatarPath: json['avatar_path'] as String?,
    phone: json['phone'] as String?,
    bio: json['bio'] as String?,
    locale: (json['locale'] as String?) ?? 'ms',
    lastSeenAt: _date(json['last_seen_at']),
  );

  final String id;
  final String displayName;
  final String? avatarPath;
  final String? phone;
  final String? bio;
  final String locale;
  final DateTime? lastSeenAt;

  String get initials {
    final parts = displayName.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts[0].substring(0, 1) + parts[1].substring(0, 1)).toUpperCase();
  }
}

class Family {
  const Family({
    required this.id,
    required this.name,
    this.description,
    this.imagePath,
    this.requireInviteApproval = false,
    this.allowAdminInvites = true,
    this.maxMembers = 200,
    this.createdAt,
  });

  factory Family.fromJson(Map<String, dynamic> json) => Family(
    id: json['id'] as String,
    name: json['name'] as String,
    description: json['description'] as String?,
    imagePath: json['image_path'] as String?,
    requireInviteApproval: (json['require_invite_approval'] as bool?) ?? false,
    allowAdminInvites: (json['allow_admin_invites'] as bool?) ?? true,
    maxMembers: (json['max_members'] as int?) ?? 200,
    createdAt: _date(json['created_at']),
  );

  final String id;
  final String name;
  final String? description;
  final String? imagePath;
  final bool requireInviteApproval;
  final bool allowAdminInvites;
  final int maxMembers;
  final DateTime? createdAt;
}

class FamilyMember {
  const FamilyMember({
    required this.id,
    required this.familyId,
    required this.userId,
    required this.role,
    required this.status,
    this.nickname,
    this.joinedAt,
    this.profile,
  });

  factory FamilyMember.fromJson(Map<String, dynamic> json) => FamilyMember(
    id: json['id'] as String,
    familyId: json['family_id'] as String,
    userId: json['user_id'] as String,
    role: FamilyRole.parse(json['role'] as String?),
    status: MemberStatus.parse(json['status'] as String?),
    nickname: json['nickname'] as String?,
    joinedAt: _date(json['joined_at']),
    profile: json['profiles'] is Map<String, dynamic>
        ? Profile.fromJson(json['profiles'] as Map<String, dynamic>)
        : null,
  );

  /// Columns + embedded profile used by every member query.
  static const select =
      'id, family_id, user_id, role, status, nickname, joined_at, '
      'profiles(id, display_name, avatar_path, phone, bio, locale, last_seen_at)';

  final String id;
  final String familyId;
  final String userId;
  final FamilyRole role;
  final MemberStatus status;
  final String? nickname;
  final DateTime? joinedAt;
  final Profile? profile;

  String get displayName {
    final n = nickname?.trim();
    if (n != null && n.isNotEmpty) return n;
    return profile?.displayName ?? '';
  }
}

/// The signed-in user's own membership, with the family row when visible
/// (families are only readable by ACTIVE members, so pending rows have none).
class MyMembership {
  const MyMembership({required this.familyId, required this.role, required this.status, this.family});

  factory MyMembership.fromJson(Map<String, dynamic> json) => MyMembership(
    familyId: json['family_id'] as String,
    role: FamilyRole.parse(json['role'] as String?),
    status: MemberStatus.parse(json['status'] as String?),
    family: json['families'] is Map<String, dynamic> ? Family.fromJson(json['families'] as Map<String, dynamic>) : null,
  );

  final String familyId;
  final FamilyRole role;
  final MemberStatus status;
  final Family? family;

  bool get isActive => status == MemberStatus.active && family != null;
}

class ActivityEntry {
  const ActivityEntry({
    required this.id,
    required this.action,
    required this.createdAt,
    this.actorId,
    this.actorName,
    this.targetId,
    this.details = const {},
  });

  factory ActivityEntry.fromJson(Map<String, dynamic> json) => ActivityEntry(
    id: json['id'] as String,
    action: json['action'] as String,
    createdAt: _date(json['created_at'])!,
    actorId: json['actor_id'] as String?,
    actorName: (json['profiles'] as Map<String, dynamic>?)?['display_name'] as String?,
    targetId: json['target_id'] as String?,
    details: (json['details'] as Map<String, dynamic>?) ?? const {},
  );

  final String id;
  final String action;
  final DateTime createdAt;
  final String? actorId;
  final String? actorName;
  final String? targetId;
  final Map<String, dynamic> details;
}
