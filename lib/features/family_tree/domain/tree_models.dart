/// Family tree (salasilah). Only parent→child and spouse links are stored;
/// named relationships are computed on the server (relationship_between).
library;

enum Gender {
  male,
  female;

  static Gender parse(String? v) => v == 'female' ? female : male;
}

enum RelationKind {
  parent,
  spouse;

  static RelationKind parse(String? v) => v == 'spouse' ? spouse : parent;
}

enum RelationStatus {
  pending,
  confirmed,
  rejected;

  static RelationStatus parse(String? v) => values.firstWhere((s) => s.name == v, orElse: () => pending);
}

DateTime _day(String s) {
  final d = DateTime.parse(s);
  return DateTime(d.year, d.month, d.day);
}

class TreePerson {
  const TreePerson({
    required this.id,
    required this.familyId,
    required this.fullName,
    required this.gender,
    required this.birthDate,
    this.userId,
    this.deathDate,
    this.notes,
    this.photoPath,
    this.revision = 1,
  });

  factory TreePerson.fromJson(Map<String, dynamic> j) => TreePerson(
    id: j['id'] as String,
    familyId: j['family_id'] as String,
    userId: j['user_id'] as String?,
    fullName: j['full_name'] as String,
    gender: Gender.parse(j['gender'] as String?),
    birthDate: _day(j['birth_date'] as String),
    deathDate: j['death_date'] == null ? null : _day(j['death_date'] as String),
    notes: j['notes'] as String?,
    photoPath: j['photo_path'] as String?,
    revision: (j['revision'] as num?)?.toInt() ?? 1,
  );

  static const select =
      'id, family_id, user_id, full_name, gender, birth_date, death_date, notes, photo_path, revision';

  final String id;
  final String familyId;
  final String? userId;
  final String fullName;
  final Gender gender;
  final DateTime birthDate;
  final DateTime? deathDate;
  final String? notes;

  /// Photo in the private bucket `tree-photos` ({family}/{person}/{file}).
  final String? photoPath;
  final int revision;

  bool get isDeceased => deathDate != null;
  bool get hasAccount => userId != null;

  /// Age in whole years on [on] (or at death).
  int ageOn(DateTime on) {
    final end = deathDate != null && deathDate!.isBefore(on) ? deathDate! : on;
    var age = end.year - birthDate.year;
    if (end.month < birthDate.month || (end.month == birthDate.month && end.day < birthDate.day)) age--;
    return age;
  }

  String get initials {
    final parts = fullName.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    return String.fromCharCode(parts.first.runes.first).toUpperCase();
  }
}

class TreeRelation {
  const TreeRelation({
    required this.id,
    required this.familyId,
    required this.kind,
    required this.personA,
    required this.personB,
    required this.status,
    this.adoptive = false,
    this.proposedBy,
    this.otherFamilyId,
    this.familyOk = true,
    this.otherOk = true,
  });

  factory TreeRelation.fromJson(Map<String, dynamic> j) => TreeRelation(
    id: j['id'] as String,
    familyId: j['family_id'] as String,
    kind: RelationKind.parse(j['kind'] as String?),
    personA: j['person_a'] as String,
    personB: j['person_b'] as String,
    status: RelationStatus.parse(j['status'] as String?),
    adoptive: j['parent_type'] == 'adoptive',
    proposedBy: j['proposed_by'] as String?,
    otherFamilyId: j['other_family_id'] as String?,
    familyOk: (j['family_ok'] as bool?) ?? true,
    otherOk: (j['other_ok'] as bool?) ?? true,
  );

  static const select =
      'id, family_id, other_family_id, kind, person_a, person_b, parent_type, status, proposed_by, family_ok, other_ok';

  final String id;
  final String familyId;
  final RelationKind kind;

  /// For [RelationKind.parent]: [personA] is the parent of [personB].
  final String personA;
  final String personB;
  final RelationStatus status;
  final bool adoptive;
  final String? proposedBy;

  /// Second family when the two people belong to different families; such a
  /// relation needs an owner/admin of both ([familyOk] and [otherOk]).
  final String? otherFamilyId;
  final bool familyOk;
  final bool otherOk;

  bool get confirmed => status == RelationStatus.confirmed;

  /// Families whose approval is still missing.
  List<String> get awaitingFamilies => [
    if (status == RelationStatus.pending && !familyOk) familyId,
    if (status == RelationStatus.pending && !otherOk && otherFamilyId != null) otherFamilyId!,
  ];
}

/// A request to merge a duplicate record into another family's record.
class PersonMerge {
  const PersonMerge({required this.id, required this.keepId, required this.removeId});

  factory PersonMerge.fromJson(Map<String, dynamic> j) =>
      PersonMerge(id: j['id'] as String, keepId: j['keep_id'] as String, removeId: j['remove_id'] as String);

  final String id;
  final String keepId;
  final String removeId;
}

class MergeSuggestion {
  const MergeSuggestion({
    required this.keepId,
    required this.keepName,
    required this.keepFamily,
    required this.removeId,
    required this.removeName,
    required this.removeFamily,
  });

  factory MergeSuggestion.fromJson(Map<String, dynamic> j) => MergeSuggestion(
    keepId: j['keep_id'] as String,
    keepName: j['keep_name'] as String,
    keepFamily: j['keep_family'] as String,
    removeId: j['remove_id'] as String,
    removeName: j['remove_name'] as String,
    removeFamily: j['remove_family'] as String,
  );

  final String keepId;
  final String keepName;
  final String keepFamily;
  final String removeId;
  final String removeName;
  final String removeFamily;
}

/// Computed relationship between "me" and another person.
class Relationship {
  const Relationship({required this.kind, this.ms, this.en, this.up, this.down, this.via});

  factory Relationship.fromJson(Map<String, dynamic> j) => Relationship(
    kind: j['kind'] as String? ?? 'none',
    ms: j['ms'] as String?,
    en: j['en'] as String?,
    up: (j['up'] as num?)?.toInt(),
    down: (j['down'] as num?)?.toInt(),
    via: j['via'] as String?,
  );

  /// self | blood | marriage | none | no_profile
  final String kind;
  final String? ms;
  final String? en;
  final int? up;
  final int? down;

  /// The person that explains the link (target's parent on the path, or the
  /// spouse for in-laws).
  final String? via;

  String? label(String localeName) => localeName.startsWith('en') ? en : ms;
}

/// Everything in one family's tree with lookup helpers (confirmed links only
/// unless stated).
class TreeData {
  TreeData({
    required List<TreePerson> persons,
    required this.relations,
    this.familyNames = const {},
    this.merges = const [],
  }) : persons = {for (final p in persons) p.id: p};

  final Map<String, TreePerson> persons;
  final List<TreeRelation> relations;

  /// Names of the families in the clan (id → name); people of other families
  /// are labelled with these.
  final Map<String, String> familyNames;

  /// Pending cross-family merge requests.
  final List<PersonMerge> merges;

  Iterable<TreeRelation> get _confirmed => relations.where((r) => r.confirmed);
  List<TreeRelation> get pending => relations.where((r) => r.status == RelationStatus.pending).toList();

  List<TreePerson> _sorted(Iterable<String> ids) =>
      ids.map((id) => persons[id]).whereType<TreePerson>().toList()..sort((a, b) => a.birthDate.compareTo(b.birthDate));

  List<TreePerson> parentsOf(String id) =>
      _sorted(_confirmed.where((r) => r.kind == RelationKind.parent && r.personB == id).map((r) => r.personA));

  List<TreePerson> childrenOf(String id) =>
      _sorted(_confirmed.where((r) => r.kind == RelationKind.parent && r.personA == id).map((r) => r.personB));

  List<TreePerson> spousesOf(String id) => _sorted(
    _confirmed
        .where((r) => r.kind == RelationKind.spouse && (r.personA == id || r.personB == id))
        .map((r) => r.personA == id ? r.personB : r.personA),
  );

  /// People sharing at least one confirmed parent.
  List<TreePerson> siblingsOf(String id) {
    final parents = parentsOf(id).map((p) => p.id).toSet();
    final ids = <String>{for (final p in parents) ...childrenOf(p).map((c) => c.id)}..remove(id);
    return _sorted(ids);
  }

  bool isAdoptiveChild(String parentId, String childId) => _confirmed.any(
    (r) => r.kind == RelationKind.parent && r.personA == parentId && r.personB == childId && r.adoptive,
  );

  TreePerson? personForUser(String? userId) {
    if (userId == null) return null;
    for (final p in persons.values) {
      if (p.userId == userId) return p;
    }
    return null;
  }

  /// Generation per person: children are one below their lowest parent,
  /// spouses share a row. Stable for any order of input.
  Map<String, int> generations() {
    final gen = {for (final id in persons.keys) id: 0};
    final parentLinks = _confirmed.where((r) => r.kind == RelationKind.parent).toList();
    final spouseLinks = _confirmed.where((r) => r.kind == RelationKind.spouse).toList();
    for (var i = 0; i < persons.length + 2; i++) {
      var changed = false;
      for (final r in parentLinks) {
        final g = (gen[r.personA] ?? 0) + 1;
        if ((gen[r.personB] ?? 0) < g && gen.containsKey(r.personB)) {
          gen[r.personB] = g;
          changed = true;
        }
      }
      for (final r in spouseLinks) {
        final a = gen[r.personA], b = gen[r.personB];
        if (a == null || b == null || a == b) continue;
        final m = a > b ? a : b;
        gen[r.personA] = m;
        gen[r.personB] = m;
        changed = true;
      }
      if (!changed) break;
    }
    // Shift so the top row is generation 0.
    final minGen = gen.values.isEmpty ? 0 : gen.values.reduce((a, b) => a < b ? a : b);
    return {for (final e in gen.entries) e.key: e.value - minGen};
  }

  /// Rows of person ids, top generation first; siblings ordered by birth,
  /// grouped under their parents; spouses placed next to each other.
  List<List<String>> layoutRows() {
    final gen = generations();
    if (gen.isEmpty) return const [];
    final maxGen = gen.values.reduce((a, b) => a > b ? a : b);
    final rows = <List<String>>[];
    for (var g = 0; g <= maxGen; g++) {
      final ids = gen.entries.where((e) => e.value == g).map((e) => e.key).toList();
      double anchor(String id) {
        // Position of the parents in the row above (or of a spouse's parents).
        if (rows.isEmpty) return 0;
        final above = rows.last;
        final candidates = [
          ...parentsOf(id).map((p) => above.indexOf(p.id)),
          for (final s in spousesOf(id)) ...parentsOf(s.id).map((p) => above.indexOf(p.id)),
        ].where((i) => i >= 0).toList();
        if (candidates.isEmpty) return double.infinity;
        return candidates.reduce((a, b) => a < b ? a : b).toDouble();
      }

      ids.sort((a, b) {
        final c = anchor(a).compareTo(anchor(b));
        if (c != 0) return c;
        return persons[a]!.birthDate.compareTo(persons[b]!.birthDate);
      });
      // Keep spouses adjacent: place each in-married spouse right after their partner.
      final ordered = <String>[];
      for (final id in ids) {
        if (ordered.contains(id)) continue;
        ordered.add(id);
        for (final s in spousesOf(id)) {
          if (gen[s.id] == g && !ordered.contains(s.id) && parentsOf(s.id).isEmpty) ordered.add(s.id);
        }
      }
      rows.add(ordered);
    }
    return rows;
  }

  /// Living people whose birthday falls within [days] days from [today]
  /// (Feb 29 birthdays count on Feb 28 in common years), soonest first.
  List<(TreePerson, DateTime)> upcomingBirthdays(DateTime today, {int days = 30}) {
    final start = DateTime(today.year, today.month, today.day);
    final out = <(TreePerson, DateTime)>[];
    for (final p in persons.values) {
      if (p.isDeceased) continue;
      for (final year in [start.year, start.year + 1]) {
        final next = birthdayIn(p.birthDate, year);
        final diff = next.difference(start).inDays;
        if (diff >= 0 && diff <= days) {
          out.add((p, next));
          break;
        }
      }
    }
    out.sort((a, b) => a.$2.compareTo(b.$2));
    return out;
  }
}

bool isLeapYear(int y) => (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;

/// The date of the birthday in [year] (29 Feb → 28 Feb in common years).
DateTime birthdayIn(DateTime birth, int year) {
  if (birth.month == 2 && birth.day == 29 && !isLeapYear(year)) return DateTime(year, 2, 28);
  return DateTime(year, birth.month, birth.day);
}
