import 'package:familysync/features/family_links/domain/link_models.dart';
import 'package:flutter_test/flutter_test.dart';

LinkedFamily f(String id, int depth, String? parent, {LinkRelation r = LinkRelation.clan}) =>
    LinkedFamily(familyId: id, name: id, memberCount: 1, depth: depth, parentFamilyId: parent, relation: r);

void main() {
  test('clan outline: root first, branches under their parent, alphabetical', () {
    final out = clanOutline([
      f('Cucu', 2, 'Sulung'),
      f('Bongsu', 1, 'Induk'),
      f('Induk', 0, null, r: LinkRelation.parent),
      f('Sulung', 1, 'Induk', r: LinkRelation.self),
    ]);
    expect(out.map((e) => e.name), ['Induk', 'Bongsu', 'Sulung', 'Cucu']);
  });

  test('JSON parsing', () {
    final l = LinkedFamily.fromJson({
      'family_id': 'a',
      'name': 'Keluarga A',
      'member_count': 4,
      'depth': 1,
      'parent_family_id': 'p',
      'relation': 'child',
    });
    expect(l.relation, LinkRelation.child);
    expect(
      LinkRequest.fromJson({
        'id': 'x',
        'parent_family_id': 'p',
        'child_family_id': 'c',
        'other_family_name': 'P',
        'incoming': true,
      }).incoming,
      isTrue,
    );
  });
}
