/// A family in the same rumpun (clan), relative to the active family.
enum LinkRelation {
  self,
  parent,
  child,
  clan;

  static LinkRelation parse(String? v) => values.firstWhere((r) => r.name == v, orElse: () => clan);
}

class LinkedFamily {
  const LinkedFamily({
    required this.familyId,
    required this.name,
    required this.memberCount,
    required this.depth,
    required this.relation,
    this.parentFamilyId,
  });

  factory LinkedFamily.fromJson(Map<String, dynamic> j) => LinkedFamily(
    familyId: j['family_id'] as String,
    name: j['name'] as String,
    memberCount: (j['member_count'] as num?)?.toInt() ?? 0,
    depth: (j['depth'] as num?)?.toInt() ?? 0,
    parentFamilyId: j['parent_family_id'] as String?,
    relation: LinkRelation.parse(j['relation'] as String?),
  );

  final String familyId;
  final String name;
  final int memberCount;

  /// Generations below the clan's root family.
  final int depth;
  final String? parentFamilyId;
  final LinkRelation relation;
}

class LinkRequest {
  const LinkRequest({
    required this.id,
    required this.parentFamilyId,
    required this.childFamilyId,
    required this.otherFamilyName,
    required this.incoming,
    this.requestedByName,
  });

  factory LinkRequest.fromJson(Map<String, dynamic> j) => LinkRequest(
    id: j['id'] as String,
    parentFamilyId: j['parent_family_id'] as String,
    childFamilyId: j['child_family_id'] as String,
    otherFamilyName: (j['other_family_name'] as String?) ?? '?',
    incoming: (j['incoming'] as bool?) ?? false,
    requestedByName: j['requested_by_name'] as String?,
  );

  final String id;
  final String parentFamilyId;
  final String childFamilyId;
  final String otherFamilyName;

  /// Waiting for this family's approval.
  final bool incoming;
  final String? requestedByName;
}

/// Orders clan families as an indented outline (root first, branches below
/// their parent, alphabetical among siblings).
List<LinkedFamily> clanOutline(List<LinkedFamily> all) {
  final byParent = <String?, List<LinkedFamily>>{};
  final ids = {for (final f in all) f.familyId};
  for (final f in all) {
    final parent = ids.contains(f.parentFamilyId) ? f.parentFamilyId : null;
    byParent.putIfAbsent(parent, () => []).add(f);
  }
  for (final l in byParent.values) {
    l.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }
  final out = <LinkedFamily>[];
  void walk(String? parent) {
    for (final f in byParent[parent] ?? const <LinkedFamily>[]) {
      out.add(f);
      walk(f.familyId);
    }
  }

  walk(null);
  return out;
}
