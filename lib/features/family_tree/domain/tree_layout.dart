import 'tree_models.dart';

/// Positions of the tree cards (top-left corners) and the canvas size, shared
/// by the on-screen chart and the PDF export so both look the same.
class TreeLayout {
  TreeLayout._(this.positions, this.width, this.height);

  static const cardW = 116.0;
  static const cardH = 108.0;
  static const gapX = 20.0;
  static const gapY = 64.0;
  static const pad = 24.0;

  factory TreeLayout.of(TreeData tree) {
    final rows = tree.layoutRows();
    final widest = rows.fold<int>(0, (m, r) => r.length > m ? r.length : m);
    final width = pad * 2 + widest * cardW + (widest > 0 ? widest - 1 : 0) * gapX;
    final height = pad * 2 + rows.length * cardH + (rows.isNotEmpty ? rows.length - 1 : 0) * gapY;
    final pos = <String, ({double x, double y})>{};
    for (var g = 0; g < rows.length; g++) {
      final rowW = rows[g].length * cardW + (rows[g].length - 1) * gapX;
      final startX = (width - rowW) / 2;
      for (var i = 0; i < rows[g].length; i++) {
        pos[rows[g][i]] = (x: startX + i * (cardW + gapX), y: pad + g * (cardH + gapY));
      }
    }
    return TreeLayout._(pos, width, height);
  }

  final Map<String, ({double x, double y})> positions;
  final double width;
  final double height;

  /// Connector polylines: parent→child as an elbow (4 points), spouses as a
  /// straight line (2 points) between facing card edges.
  List<({List<({double x, double y})> points, RelationKind kind, bool adoptive})> links(TreeData tree) => [
    for (final r in tree.relations.where((r) => r.confirmed))
      if (positions[r.personA] case final a?)
        if (positions[r.personB] case final b?)
          if (r.kind == RelationKind.spouse)
            (
              points: [
                (x: (a.x < b.x ? a.x : b.x) + cardW, y: a.y + cardH / 2),
                (x: a.x < b.x ? b.x : a.x, y: b.y + cardH / 2),
              ],
              kind: r.kind,
              adoptive: false,
            )
          else
            (
              points: [
                (x: a.x + cardW / 2, y: a.y + cardH),
                (x: a.x + cardW / 2, y: a.y + cardH + (b.y - a.y - cardH) / 2),
                (x: b.x + cardW / 2, y: a.y + cardH + (b.y - a.y - cardH) / 2),
                (x: b.x + cardW / 2, y: b.y),
              ],
              kind: r.kind,
              adoptive: r.adoptive,
            ),
  ];
}
