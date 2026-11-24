import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../domain/tree_layout.dart';
import '../domain/tree_models.dart';

/// What to print.
enum PdfScope {
  /// Everyone (optionally limited to the first generations).
  all,

  /// One person, their spouses and descendants.
  branch,

  /// A cover page with the root couple and their children, then one section
  /// per child's branch.
  branchPerPage,
}

enum PdfStyle { chart, list }

class TreePdfOptions {
  const TreePdfOptions({
    this.scope = PdfScope.all,
    this.style = PdfStyle.chart,
    this.rootId,
    this.maxGenerations,
    this.photos = true,
  });

  final PdfScope scope;
  final PdfStyle style;

  /// Branch root ([PdfScope.branch]) or head of the family
  /// ([PdfScope.branchPerPage]); defaults to the oldest root.
  final String? rootId;

  /// Generations to print, counting the root's row (null = all); with
  /// [PdfScope.branchPerPage] it applies to each child's section.
  final int? maxGenerations;
  final bool photos;
}

/// Localised texts (provided by the caller).
class TreePdfText {
  const TreePdfText({
    required this.title,
    required this.generated,
    required this.legend,
    required this.page,
    required this.pageShort,
    required this.continues,
    required this.overview,
    required this.overviewHint,
    required this.deceased,
    required this.branchOf,
    required this.generationLabel,
  });

  final String title;
  final String generated;
  final String legend;
  final String Function(int page, int total) page;

  /// Short page reference on the overview map, e.g. "hlm. 3".
  final String Function(int page) pageShort;

  /// "continues on page n" next to a cut connector.
  final String Function(int page) continues;
  final String overview;
  final String overviewHint;

  /// Suffix for people who passed away, e.g. "Arwah".
  final String Function(Gender gender) deceased;
  final String Function(String name) branchOf;
  final String Function(int generation) generationLabel;
}

/// Fonts for the PDF: Noto Sans (Latin/Greek/Cyrillic) with Noto Naskh
/// Arabic as fallback for Jawi names.
class TreePdfFonts {
  const TreePdfFonts({required this.regular, required this.bold, this.fallback = const []});

  final pw.Font regular;
  final pw.Font bold;
  final List<pw.Font> fallback;
}

// A4, millimetres -> points. Print geometry: readable 8.5 pt names.
const _margin = 28.0;
const _header = 34.0;
const _footer = 18.0;
const _cardW = 100.0;
const _cardH = 74.0;
const _gapX = 12.0;
const _gapY = 34.0;
const _minScale = 0.7; // never print smaller than this

const _male = PdfColor.fromInt(0xFF3F6FD8);
const _female = PdfColor.fromInt(0xFFD84F8A);
const _line = PdfColor.fromInt(0xFF8A8F98);
const _muted = PdfColor.fromInt(0xFF666666);

/// Builds a printable A4 PDF of the family tree.
///
/// Chart style: if the selection fits on one landscape page at ≥ 70 % it is
/// printed on one page; otherwise it is split, at full size, into pages cut in
/// the gaps between cards (never through a card), cut connectors say which
/// page they continue on, and the first page is an overview map numbering
/// every page. List style: an indented outline (portrait), which
/// always fits the width and flows over as many pages as needed.
Future<Uint8List> buildTreePdf(
  TreeData tree, {
  required TreePdfText text,
  required TreePdfFonts fonts,
  TreePdfOptions options = const TreePdfOptions(),
  Map<String, Uint8List> photos = const {},
}) async {
  final doc = pw.Document(
    title: text.title,
    creator: 'FamilySync',
    theme: pw.ThemeData.withFont(base: fonts.regular, bold: fonts.bold, fontFallback: fonts.fallback),
  );
  final images = {
    if (options.photos)
      for (final e in photos.entries) e.key: pw.MemoryImage(e.value),
  };

  final root = options.rootId ?? (tree.roots.isEmpty ? null : tree.roots.first.id);
  // maxGenerations counts printed rows, so "2" = the head and their children.
  final below = options.maxGenerations == null ? null : math.max(1, options.maxGenerations! - 1);
  final sections = <({String? heading, TreeData data})>[];
  switch (options.scope) {
    case PdfScope.all:
      sections.add((heading: null, data: _limitGenerations(tree, options.maxGenerations)));
    case PdfScope.branch:
      sections.add((
        heading: root == null ? null : text.branchOf(tree.persons[root]!.fullName),
        data: root == null ? tree : tree.branch(root, maxGenerations: below),
      ));
    case PdfScope.branchPerPage:
      if (root == null) {
        sections.add((heading: null, data: tree));
      } else {
        sections.add((heading: null, data: tree.branch(root, maxGenerations: 1)));
        final unit = {root, ...tree.spousesOf(root).map((s) => s.id)};
        final children = {for (final m in unit) ...tree.childrenOf(m)}.toList()
          ..sort((a, b) => a.birthDate.compareTo(b.birthDate));
        for (final c in children) {
          sections.add((heading: text.branchOf(c.fullName), data: tree.branch(c.id, maxGenerations: below)));
        }
      }
  }

  if (options.style == PdfStyle.list) {
    _addList(doc, sections, text);
  } else {
    final pages = <_ChartPage>[];
    for (final s in sections) {
      pages.addAll(_chartPages(s.data, s.heading));
    }
    final total = pages.length;
    for (var i = 0; i < pages.length; i++) {
      final pg = pages[i];
      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4.landscape.copyWith(
            marginLeft: _margin,
            marginRight: _margin,
            marginTop: _margin,
            marginBottom: _margin,
          ),
          build: (ctx) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              _headerBlock(text, pg.heading ?? (pg.isOverview ? text.overview : null)),
              pw.Expanded(
                child: pg.isOverview
                    ? _overview(pg, text, pageOffset: i)
                    : _tile(pg, images, text, pageOffset: i - pg.indexInSection),
              ),
              _footerBlock(text.page(i + 1, total), pg.label),
            ],
          ),
        ),
      );
    }
  }
  return doc.save();
}

TreeData _limitGenerations(TreeData tree, int? max) {
  if (max == null) return tree;
  final gen = tree.generations();
  final keep = {
    for (final e in gen.entries)
      if (e.value < max) e.key,
  };
  return TreeData(
    persons: [for (final id in keep) ?tree.persons[id]],
    relations: tree.relations.where((r) => keep.contains(r.personA) && keep.contains(r.personB)).toList(),
    familyNames: tree.familyNames,
  );
}

// ---------------------------------------------------------------- chart

class _ChartPage {
  _ChartPage({
    required this.tree,
    required this.layout,
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
    required this.scale,
    required this.indexInSection,
    this.heading,
    this.label,
    this.isOverview = false,
    this.tiles = const [],
  });

  final TreeData tree;
  final TreeLayout layout;
  final double x0, y0, x1, y1;
  final double scale;
  final String? heading;

  /// e.g. "B2" (row, column) for tiled pages.
  final String? label;
  final bool isOverview;

  /// Position of this page inside its section (0 = first).
  final int indexInSection;

  /// For the overview: the tiles it maps, as (label, x0, y0, x1, y1, pageIndexInSection).
  final List<({String label, double x0, double y0, double x1, double y1, int index})> tiles;

  /// Neighbouring tiles (index in section) per side, for continuation notes.
  int? right, left, below, above;
}

double get _contentW => PdfPageFormat.a4.landscape.width - _margin * 2;
double get _contentH => PdfPageFormat.a4.landscape.height - _margin * 2 - _header - _footer;

List<_ChartPage> _chartPages(TreeData tree, String? heading) {
  final layout = TreeLayout.of(tree, cardW: _cardW, cardH: _cardH, gapX: _gapX, gapY: _gapY, pad: 0);
  if (layout.positions.isEmpty) return const [];
  final fit = math.min(1.0, math.min(_contentW / layout.width, _contentH / layout.height));
  if (fit >= _minScale) {
    return [
      _ChartPage(
        tree: tree,
        layout: layout,
        x0: 0,
        y0: 0,
        x1: layout.width,
        y1: layout.height,
        scale: fit,
        heading: heading,
        indexInSection: 0,
      ),
    ];
  }
  // Split at full size, only in the gaps between cards.
  final pos = layout.positions.values.toList();
  final xs = treePdfCuts([for (final p in pos) p.x], _cardW, _gapX, layout.width, _contentW);
  final ys = treePdfCuts([for (final p in pos) p.y], _cardH, _gapY, layout.height, _contentH);
  bool hasCards(int r, int c) =>
      pos.any((p) => p.x + _cardW > xs[c].$1 && p.x < xs[c].$2 && p.y + _cardH > ys[r].$1 && p.y < ys[r].$2);
  // Empty tiles (no card) are not printed; page 0 of the section is the overview.
  final index = <(int, int), int>{};
  for (var r = 0; r < ys.length; r++) {
    for (var c = 0; c < xs.length; c++) {
      if (hasCards(r, c)) index[(r, c)] = index.length + 1;
    }
  }
  final tiles = <_ChartPage>[];
  final grid = <({String label, double x0, double y0, double x1, double y1, int index})>[];
  for (final MapEntry(key: (r, c), value: i) in index.entries) {
    final label = '${String.fromCharCode(65 + r % 26)}${c + 1}';
    grid.add((label: label, x0: xs[c].$1, y0: ys[r].$1, x1: xs[c].$2, y1: ys[r].$2, index: i));
    tiles.add(
      _ChartPage(
          tree: tree,
          layout: layout,
          x0: xs[c].$1,
          y0: ys[r].$1,
          x1: xs[c].$2,
          y1: ys[r].$2,
          scale: 1,
          heading: heading,
          label: label,
          indexInSection: i,
        )
        ..left = index[(r, c - 1)]
        ..right = index[(r, c + 1)]
        ..above = index[(r - 1, c)]
        ..below = index[(r + 1, c)],
    );
  }
  final overview = _ChartPage(
    tree: tree,
    layout: layout,
    x0: 0,
    y0: 0,
    x1: layout.width,
    y1: layout.height,
    scale: math.min(_contentW / layout.width, (_contentH - 16) / layout.height),
    heading: heading,
    isOverview: true,
    tiles: grid,
    indexInSection: 0,
  );
  return [overview, ...tiles];
}

/// Page ranges along one axis for cards starting at [starts] (size [card]).
/// Every cut lies in a gap between cards — never through a card — and each
/// range is at most [page] long (a card bigger than a page is the only
/// exception, then it is cut).
@visibleForTesting
List<(double, double)> treePdfCuts(List<double> starts, double card, double gap, double total, double page) {
  final edges = starts.toSet().toList()..sort();
  bool inside(double c) => edges.any((e) => e < c - 0.01 && c < e + card - 0.01);
  final candidates = {
    for (final e in edges) ...[e - gap / 2, e + card + gap / 2],
  }.toList()..sort();
  final out = <(double, double)>[];
  var start = 0.0;
  while (start < total - 0.5) {
    if (start + page >= total) {
      out.add((start, total));
      break;
    }
    final ok = candidates.where((c) => c > start + 1 && c <= start + page && !inside(c));
    final cut = ok.isEmpty ? start + page : ok.reduce(math.max);
    out.add((start, cut));
    start = cut;
  }
  return out;
}

pw.Widget _tile(_ChartPage pg, Map<String, pw.ImageProvider> images, TreePdfText text, {required int pageOffset}) {
  final w = (pg.x1 - pg.x0) * pg.scale;
  final h = (pg.y1 - pg.y0) * pg.scale;
  final links = pg.layout.links(pg.tree);
  String? note(int? neighbour) => neighbour == null ? null : text.continues(pageOffset + neighbour + 1);
  bool crossesX(double x) => links.any((l) => _segments(l.points).any((s) => _crossVertical(s, x, pg.y0, pg.y1)));
  bool crossesY(double y) => links.any((l) => _segments(l.points).any((s) => _crossHorizontal(s, y, pg.x0, pg.x1)));
  final notes = <pw.Widget>[
    if (pg.right != null && crossesX(pg.x1)) pw.Positioned(right: 0, top: 0, child: _noteBox('${note(pg.right)} »')),
    if (pg.left != null && crossesX(pg.x0)) pw.Positioned(left: 0, top: 0, child: _noteBox('« ${note(pg.left)}')),
    if (pg.below != null && crossesY(pg.y1)) pw.Positioned(right: 0, bottom: 0, child: _noteBox('${note(pg.below)} »')),
    if (pg.above != null && crossesY(pg.y0)) pw.Positioned(left: 0, bottom: 0, child: _noteBox('« ${note(pg.above)}')),
  ];
  return pw.Center(
    child: pw.SizedBox(
      width: w,
      height: h,
      child: pw.Stack(
        children: [
          pw.Positioned.fill(
            child: pw.ClipRect(
              child: pw.Stack(
                children: [
                  pw.Positioned.fill(
                    child: pw.CustomPaint(
                      size: PdfPoint(w, h),
                      painter: (canvas, size) {
                        for (final l in links) {
                          canvas
                            ..setStrokeColor(l.kind == RelationKind.spouse ? _male : _line)
                            ..setLineWidth(l.kind == RelationKind.spouse ? 1.4 : 0.9);
                          if (l.adoptive) canvas.setLineDashPattern([3, 2]);
                          final first = l.points.first;
                          canvas.moveTo((first.x - pg.x0) * pg.scale, size.y - (first.y - pg.y0) * pg.scale);
                          for (final p in l.points.skip(1)) {
                            canvas.lineTo((p.x - pg.x0) * pg.scale, size.y - (p.y - pg.y0) * pg.scale);
                          }
                          canvas.strokePath();
                          if (l.adoptive) canvas.setLineDashPattern();
                        }
                      },
                    ),
                  ),
                  for (final e in pg.layout.positions.entries)
                    if (e.value.x + _cardW > pg.x0 &&
                        e.value.x < pg.x1 &&
                        e.value.y + _cardH > pg.y0 &&
                        e.value.y < pg.y1)
                      pw.Positioned(
                        left: (e.value.x - pg.x0) * pg.scale,
                        top: (e.value.y - pg.y0) * pg.scale,
                        child: pw.Transform.scale(
                          scale: pg.scale,
                          alignment: pw.Alignment.topLeft,
                          child: _card(pg.tree.persons[e.key]!, images[e.key], text),
                        ),
                      ),
                ],
              ),
            ),
          ),
          ...notes,
        ],
      ),
    ),
  );
}

pw.Widget _noteBox(String s) => pw.Container(
  padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 2),
  decoration: pw.BoxDecoration(
    color: PdfColors.amber50,
    border: pw.Border.all(color: PdfColors.amber700, width: 0.6),
  ),
  child: pw.Text(s, style: const pw.TextStyle(fontSize: 7.5)),
);

Iterable<(({double x, double y}), ({double x, double y}))> _segments(List<({double x, double y})> pts) sync* {
  for (var i = 0; i < pts.length - 1; i++) {
    yield (pts[i], pts[i + 1]);
  }
}

bool _crossVertical((({double x, double y}), ({double x, double y})) s, double x, double y0, double y1) {
  final (a, b) = s;
  final lo = math.min(a.x, b.x), hi = math.max(a.x, b.x);
  return lo < x && hi > x && math.max(a.y, b.y) >= y0 && math.min(a.y, b.y) <= y1;
}

bool _crossHorizontal((({double x, double y}), ({double x, double y})) s, double y, double x0, double x1) {
  final (a, b) = s;
  final lo = math.min(a.y, b.y), hi = math.max(a.y, b.y);
  return lo < y && hi > y && math.max(a.x, b.x) >= x0 && math.min(a.x, b.x) <= x1;
}

pw.Widget _overview(_ChartPage pg, TreePdfText text, {required int pageOffset}) {
  // A small map (as wide as the page) plus an index: page, label and the
  // first names on that page, oldest generation first.
  final s = math.min(_contentW / pg.layout.width, 150 / pg.layout.height);
  final w = pg.layout.width * s;
  final h = pg.layout.height * s;
  final gen = pg.tree.generations();
  final cols = math.max(1, math.min(4, (_contentW / 190).floor()));
  final maxEntries = ((_contentH - h - 40) / 13).floor() * cols - 1;
  String names(({String label, double x0, double y0, double x1, double y1, int index}) t) {
    final inside =
        pg.layout.positions.entries
            .where((e) => e.value.x >= t.x0 - 0.5 && e.value.x + _cardW <= t.x1 + 0.5)
            .where((e) => e.value.y >= t.y0 - 0.5 && e.value.y + _cardH <= t.y1 + 0.5)
            .toList()
          ..sort((a, b) {
            final g = (gen[a.key] ?? 0).compareTo(gen[b.key] ?? 0);
            return g != 0 ? g : a.value.x.compareTo(b.value.x);
          });
    final first = inside.take(2).map((e) => pg.tree.persons[e.key]!.fullName).join(', ');
    return inside.length > 2 ? '$first…' : first;
  }

  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(text.overviewHint, style: const pw.TextStyle(fontSize: 8, color: _muted)),
      pw.SizedBox(height: 6),
      pw.Center(
        child: pw.SizedBox(
          width: w,
          height: h,
          child: pw.Stack(
            children: [
              pw.Positioned.fill(
                child: pw.CustomPaint(
                  size: PdfPoint(w, h),
                  painter: (canvas, size) {
                    canvas
                      ..setStrokeColor(_line)
                      ..setLineWidth(0.3);
                    for (final l in pg.layout.links(pg.tree)) {
                      canvas.moveTo(l.points.first.x * s, size.y - l.points.first.y * s);
                      for (final p in l.points.skip(1)) {
                        canvas.lineTo(p.x * s, size.y - p.y * s);
                      }
                      canvas.strokePath();
                    }
                    for (final e in pg.layout.positions.entries) {
                      final male = pg.tree.persons[e.key]!.gender == Gender.male;
                      canvas
                        ..setFillColor(male ? _male : _female)
                        ..drawRect(e.value.x * s, size.y - (e.value.y + _cardH) * s, _cardW * s, _cardH * s)
                        ..fillPath();
                    }
                  },
                ),
              ),
              for (final t in pg.tiles)
                pw.Positioned(
                  left: t.x0 * s,
                  top: t.y0 * s,
                  child: pw.Container(
                    width: (t.x1 - t.x0) * s,
                    height: (t.y1 - t.y0) * s,
                    decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.black, width: 0.6)),
                    alignment: pw.Alignment.topLeft,
                    child: (t.x1 - t.x0) * s < 16
                        ? null
                        : pw.Container(
                            color: PdfColors.white,
                            padding: const pw.EdgeInsets.symmetric(horizontal: 1.5),
                            child: pw.Text(t.label, style: pw.TextStyle(fontSize: 6.5, fontWeight: pw.FontWeight.bold)),
                          ),
                  ),
                ),
            ],
          ),
        ),
      ),
      pw.SizedBox(height: 10),
      pw.Wrap(
        children: [
          for (final t in pg.tiles.take(maxEntries))
            pw.SizedBox(
              width: _contentW / cols,
              height: 13,
              child: pw.RichText(
                maxLines: 1,
                overflow: pw.TextOverflow.clip,
                text: pw.TextSpan(
                  style: const pw.TextStyle(fontSize: 7.5),
                  children: [
                    pw.TextSpan(
                      text: '${t.label} ',
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                    ),
                    pw.TextSpan(
                      text: '${text.pageShort(pageOffset + t.index + 1)}  ',
                      style: const pw.TextStyle(color: _muted),
                    ),
                    pw.TextSpan(text: names(t)),
                  ],
                ),
              ),
            ),
          if (pg.tiles.length > maxEntries) pw.Text('…', style: const pw.TextStyle(fontSize: 7.5)),
        ],
      ),
    ],
  );
}

pw.Widget _card(TreePerson p, pw.ImageProvider? photo, TreePdfText text) {
  final accent = p.gender == Gender.male ? _male : _female;
  final tint = PdfColor(
    accent.red + (1 - accent.red) * 0.85,
    accent.green + (1 - accent.green) * 0.85,
    accent.blue + (1 - accent.blue) * 0.85,
  );
  final years = p.isDeceased
      ? '${p.birthDate.year} – ${p.deathDate!.year} · ${text.deceased(p.gender)}'
      : '${p.birthDate.year}';
  return pw.Container(
    width: _cardW,
    height: _cardH,
    padding: const pw.EdgeInsets.all(4),
    decoration: pw.BoxDecoration(
      color: PdfColors.white,
      border: pw.Border.all(color: accent, width: 0.9),
      borderRadius: pw.BorderRadius.circular(6),
    ),
    child: pw.Column(
      mainAxisAlignment: pw.MainAxisAlignment.center,
      children: [
        pw.Container(
          width: 24,
          height: 24,
          alignment: pw.Alignment.center,
          decoration: pw.BoxDecoration(
            shape: pw.BoxShape.circle,
            color: tint,
            image: photo == null ? null : pw.DecorationImage(image: photo, fit: pw.BoxFit.cover),
          ),
          child: photo == null
              ? pw.Text(
                  p.initials,
                  style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: accent),
                )
              : null,
        ),
        pw.SizedBox(height: 3),
        pw.Text(
          p.fullName,
          maxLines: 2,
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(fontSize: 8.5, fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 1),
        pw.Text(years, style: const pw.TextStyle(fontSize: 7, color: _muted)),
      ],
    ),
  );
}

pw.Widget _headerBlock(TreePdfText text, String? heading) => pw.SizedBox(
  height: _header,
  child: pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(
        heading == null ? text.title : '${text.title} — $heading',
        style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold),
        maxLines: 1,
      ),
      pw.Text('${text.generated} · ${text.legend}', style: const pw.TextStyle(fontSize: 7.5, color: _muted)),
    ],
  ),
);

pw.Widget _footerBlock(String page, String? label) => pw.SizedBox(
  height: _footer,
  child: pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
    crossAxisAlignment: pw.CrossAxisAlignment.end,
    children: [
      pw.Text(label ?? '', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
      pw.Text(page, style: const pw.TextStyle(fontSize: 8, color: _muted)),
    ],
  ),
);

// ---------------------------------------------------------------- list

void _addList(pw.Document doc, List<({String? heading, TreeData data})> sections, TreePdfText text) {
  final lines = <pw.Widget>[];
  for (final s in sections) {
    if (s.heading != null) {
      lines.add(
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 10, bottom: 4),
          child: pw.Text(s.heading!, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
        ),
      );
    }
    final t = s.data;
    final placed = <String>{};
    String who(TreePerson p) {
      final years = p.isDeceased
          ? '${p.birthDate.year}–${p.deathDate!.year}, ${text.deceased(p.gender)}'
          : '${p.birthDate.year}';
      return '${p.fullName} ($years)';
    }

    void walk(TreePerson p, int depth) {
      if (!placed.add(p.id)) return;
      final spouses = t.spousesOf(p.id).where((x) => t.parentsOf(x.id).isEmpty && placed.add(x.id)).toList();
      lines.add(
        pw.Container(
          margin: pw.EdgeInsets.only(left: depth * 14.0, top: 1.5, bottom: 1.5),
          padding: const pw.EdgeInsets.only(left: 6),
          decoration: pw.BoxDecoration(
            border: pw.Border(left: pw.BorderSide(color: p.gender == Gender.male ? _male : _female, width: 1.6)),
          ),
          child: pw.RichText(
            text: pw.TextSpan(
              children: [
                pw.TextSpan(
                  text: '${text.generationLabel(depth)}  ',
                  style: const pw.TextStyle(fontSize: 7, color: _muted),
                ),
                pw.TextSpan(
                  text: who(p),
                  style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold),
                ),
                if (spouses.isNotEmpty)
                  pw.TextSpan(text: '  &  ${spouses.map(who).join('  &  ')}', style: const pw.TextStyle(fontSize: 9)),
              ],
            ),
          ),
        ),
      );
      final kids =
          {p.id, ...spouses.map((x) => x.id)}.expand(t.childrenOf).where((c) => !placed.contains(c.id)).toSet().toList()
            ..sort((a, b) => a.birthDate.compareTo(b.birthDate));
      for (final k in kids) {
        walk(k, depth + 1);
      }
    }

    for (final r in t.roots) {
      walk(r, 0);
    }
    for (final p in t.persons.values.toList()..sort((a, b) => a.birthDate.compareTo(b.birthDate))) {
      walk(p, 0); // anyone not reachable from a root
    }
  }

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4.copyWith(
        marginLeft: _margin,
        marginRight: _margin,
        marginTop: _margin,
        marginBottom: _margin,
      ),
      header: (ctx) => _headerBlock(text, null),
      footer: (ctx) => _footerBlock(text.page(ctx.pageNumber, ctx.pagesCount), null),
      build: (ctx) => lines,
    ),
  );
}
