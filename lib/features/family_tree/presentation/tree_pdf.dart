import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../domain/tree_layout.dart';
import '../domain/tree_models.dart';

/// Labels for the PDF (localised by the caller).
class TreePdfLabels {
  const TreePdfLabels({required this.title, required this.generated, required this.legend});

  final String title;
  final String generated;
  final String legend;
}

/// Builds a one-page PDF of the whole chart with the same layout as the
/// screen. The page is sized to the tree (PDF viewers zoom); [photos] are
/// optional JPEG/PNG bytes per person id.
Future<Uint8List> buildTreePdf(
  TreeData tree, {
  required TreePdfLabels labels,
  Map<String, Uint8List> photos = const {},
}) async {
  final layout = TreeLayout.of(tree);
  const header = 56.0;
  const margin = 24.0;
  final width = (layout.width + margin * 2).clamp(420.0, 14400.0);
  final height = (layout.height + header + margin * 2).clamp(300.0, 14400.0);
  final doc = pw.Document(title: labels.title, creator: 'FamilySync');
  const male = PdfColor.fromInt(0xFF3F6FD8);
  const female = PdfColor.fromInt(0xFFD84F8A);
  const lineColor = PdfColor.fromInt(0xFF8A8F98);

  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat(width, height, marginAll: margin),
      build: (ctx) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(labels.title, style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
          pw.Text('${labels.generated} · ${labels.legend}', style: const pw.TextStyle(fontSize: 9, color: lineColor)),
          pw.SizedBox(height: 12),
          pw.SizedBox(
            width: layout.width,
            height: layout.height,
            child: pw.Stack(
              children: [
                pw.Positioned.fill(
                  child: pw.CustomPaint(
                    size: PdfPoint(layout.width, layout.height),
                    painter: (canvas, size) {
                      // PDF y grows upwards: flip against the layout height.
                      for (final l in layout.links(tree)) {
                        canvas
                          ..setStrokeColor(l.kind == RelationKind.spouse ? male : lineColor)
                          ..setLineWidth(l.kind == RelationKind.spouse ? 1.6 : 1.0);
                        if (l.adoptive) canvas.setLineDashPattern([3, 2]);
                        final first = l.points.first;
                        canvas.moveTo(first.x, size.y - first.y);
                        for (final p in l.points.skip(1)) {
                          canvas.lineTo(p.x, size.y - p.y);
                        }
                        canvas.strokePath();
                        if (l.adoptive) canvas.setLineDashPattern();
                      }
                    },
                  ),
                ),
                for (final e in layout.positions.entries)
                  pw.Positioned(
                    left: e.value.x,
                    top: e.value.y,
                    child: _card(tree.persons[e.key]!, photos[e.key], male, female),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  return doc.save();
}

pw.Widget _card(TreePerson p, Uint8List? photo, PdfColor male, PdfColor female) {
  final accent = p.gender == Gender.male ? male : female;
  final years = p.isDeceased ? '${p.birthDate.year} - ${p.deathDate!.year} (Arwah)' : '${p.birthDate.year}';
  return pw.Container(
    width: TreeLayout.cardW,
    height: TreeLayout.cardH,
    padding: const pw.EdgeInsets.all(5),
    decoration: pw.BoxDecoration(
      color: PdfColors.white,
      border: pw.Border.all(color: accent, width: 1),
      borderRadius: pw.BorderRadius.circular(8),
    ),
    child: pw.Column(
      mainAxisAlignment: pw.MainAxisAlignment.center,
      children: [
        pw.Container(
          width: 34,
          height: 34,
          decoration: pw.BoxDecoration(
            shape: pw.BoxShape.circle,
            color: PdfColor(accent.red, accent.green, accent.blue, 0.15),
            image: photo == null ? null : pw.DecorationImage(image: pw.MemoryImage(photo), fit: pw.BoxFit.cover),
          ),
          alignment: pw.Alignment.center,
          child: photo == null
              ? pw.Text(
                  _safe(p.initials),
                  style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold, color: accent),
                )
              : null,
        ),
        pw.SizedBox(height: 4),
        pw.Text(
          _safe(p.fullName),
          maxLines: 2,
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 2),
        pw.Text(years, style: const pw.TextStyle(fontSize: 7.5, color: PdfColor.fromInt(0xFF666666))),
      ],
    ),
  );
}

/// The built-in PDF font covers Latin-1; anything else becomes '?' instead of
/// failing to render.
String _safe(String s) => String.fromCharCodes(s.runes.map((r) => r <= 0xFF ? r : 0x3F));

/// Writes the PDF to the app's temporary folder and returns the file.
Future<File> saveTreePdf(Uint8List bytes, String fileName) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/$fileName');
  await file.writeAsBytes(bytes, flush: true);
  return file;
}
