import 'tree_models.dart';

/// Positions of the tree cards (top-left corners) and the canvas size, shared
/// by the on-screen chart and the PDF export so both look the same.
class TreeLayout {
  TreeLayout._(this.positions, this.width, this.height, this.cw, this.ch, this.gx);

  // Screen card geometry (the defaults).
  static const cardW = 116.0;
  static const cardH = 108.0;
  static const gapX = 20.0;
  static const gapY = 64.0;
  static const pad = 24.0;

  /// Card and gap sizes of this layout (print uses smaller cards).
  final double cw;
  final double ch;
  final double gx;

  factory TreeLayout.of(
    TreeData tree, {
    double cardW = cardW,
    double cardH = cardH,
    double gapX = gapX,
    double gapY = gapY,
    double pad = pad,
  }) {
    final slots = tree.layoutSlots();
    if (slots.isEmpty) return TreeLayout._(const {}, pad * 2, pad * 2, cardW, cardH, gapX);
    final minCol = slots.values.map((s) => s.col).reduce((a, b) => a < b ? a : b);
    final maxCol = slots.values.map((s) => s.col).reduce((a, b) => a > b ? a : b) - minCol;
    final maxGen = slots.values.map((s) => s.gen).reduce((a, b) => a > b ? a : b);
    final pos = {
      for (final e in slots.entries)
        e.key: (x: pad + (e.value.col - minCol) * (cardW + gapX), y: pad + e.value.gen * (cardH + gapY)),
    };
    return TreeLayout._(
      pos,
      pad * 2 + (maxCol + 1) * cardW + maxCol * gapX,
      pad * 2 + (maxGen + 1) * cardH + maxGen * gapY,
      cardW,
      cardH,
      gapX,
    );
  }

  final Map<String, ({double x, double y})> positions;
  final double width;
  final double height;

  /// Connector polylines. Spouses: a straight line between facing card
  /// edges. Children: one elbow per child, starting from the middle of their
  /// parents' couple when both parents are married and side by side
  /// (classic family-tree style), otherwise from each parent.
  List<({List<({double x, double y})> points, RelationKind kind, bool adoptive})> links(TreeData tree) {
    final out = <({List<({double x, double y})> points, RelationKind kind, bool adoptive})>[];
    final confirmed = tree.relations.where((r) => r.confirmed).toList();
    for (final r in confirmed.where((r) => r.kind == RelationKind.spouse)) {
      final a = positions[r.personA], b = positions[r.personB];
      if (a == null || b == null) continue;
      final left = a.x < b.x ? a : b, right = a.x < b.x ? b : a;
      out.add((
        points: [(x: left.x + cw, y: left.y + ch / 2), (x: right.x, y: right.y + ch / 2)],
        kind: RelationKind.spouse,
        adoptive: false,
      ));
    }
    final byChild = <String, List<TreeRelation>>{};
    for (final r in confirmed.where((r) => r.kind == RelationKind.parent)) {
      byChild.putIfAbsent(r.personB, () => []).add(r);
    }
    ({List<({double x, double y})> points, RelationKind kind, bool adoptive}) elbow(
      double fromX,
      double fromY,
      ({double x, double y}) child,
      bool adoptive,
    ) {
      final midY = fromY + (child.y - fromY) / 2;
      return (
        points: [
          (x: fromX, y: fromY),
          (x: fromX, y: midY),
          (x: child.x + cw / 2, y: midY),
          (x: child.x + cw / 2, y: child.y),
        ],
        kind: RelationKind.parent,
        adoptive: adoptive,
      );
    }

    for (final e in byChild.entries) {
      final child = positions[e.key];
      if (child == null) continue;
      final parents = e.value.where((r) => positions[r.personA] != null).toList();
      if (parents.length == 2) {
        final p1 = positions[parents[0].personA]!, p2 = positions[parents[1].personA]!;
        final married = tree.spousesOf(parents[0].personA).any((s) => s.id == parents[1].personA);
        final adjacent = p1.y == p2.y && ((p1.x - p2.x).abs() - (cw + gx)).abs() < 0.5;
        if (married && adjacent && parents[0].adoptive == parents[1].adoptive) {
          // from the middle of the spouse line
          out.add(elbow((p1.x + p2.x) / 2 + cw / 2, p1.y + ch / 2, child, parents[0].adoptive));
          continue;
        }
      }
      for (final r in parents) {
        final p = positions[r.personA]!;
        out.add(elbow(p.x + cw / 2, p.y + ch, child, r.adoptive));
      }
    }
    return out;
  }
}
