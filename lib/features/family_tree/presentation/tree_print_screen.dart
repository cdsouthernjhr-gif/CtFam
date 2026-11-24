import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../data/tree_repository.dart';
import '../domain/tree_models.dart';
import 'tree_pdf.dart';

/// Asks what to print, then opens the print preview.
Future<void> printFamilyTree(BuildContext context, TreeData tree, String familyName) async {
  final options = await showModalBottomSheet<TreePdfOptions>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => TreePrintOptionsSheet(tree: tree),
  );
  if (options == null || !context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => TreePrintPreviewScreen(tree: tree, familyName: familyName, options: options),
    ),
  );
}

class TreePrintOptionsSheet extends StatefulWidget {
  const TreePrintOptionsSheet({required this.tree, super.key});

  final TreeData tree;

  @override
  State<TreePrintOptionsSheet> createState() => _TreePrintOptionsSheetState();
}

class _TreePrintOptionsSheetState extends State<TreePrintOptionsSheet> {
  var _scope = PdfScope.all;
  var _style = PdfStyle.chart;
  var _generations = 0; // 0 = all
  var _photos = true;
  String? _rootId;

  @override
  void initState() {
    super.initState();
    _rootId = widget.tree.roots.isEmpty ? null : widget.tree.roots.first.id;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final people = widget.tree.persons.values.toList()..sort((a, b) => a.fullName.compareTo(b.fullName));
    final hasPhotos = widget.tree.persons.values.any((p) => p.photoPath != null);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.treePdfOptionsTitle, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: AppSpacing.md),
            Text(l.treePdfScope, style: Theme.of(context).textTheme.titleSmall),
            RadioGroup<PdfScope>(
              groupValue: _scope,
              onChanged: (v) => setState(() => _scope = v ?? _scope),
              child: Column(
                children: [
                  for (final (s, label) in [
                    (PdfScope.all, l.treePdfScopeAll),
                    (PdfScope.branch, l.treePdfScopeBranch),
                    (PdfScope.branchPerPage, l.treePdfScopeBranchPerPage),
                  ])
                    RadioListTile<PdfScope>(
                      key: ValueKey('print.scope.${s.name}'),
                      value: s,
                      title: Text(label),
                      contentPadding: EdgeInsets.zero,
                    ),
                ],
              ),
            ),
            if (_scope != PdfScope.all && people.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              DropdownMenu<String>(
                key: const ValueKey('print.root'),
                expandedInsets: EdgeInsets.zero,
                initialSelection: _rootId,
                enableFilter: true,
                requestFocusOnTap: true,
                label: Text(l.treePdfRoot),
                menuHeight: 320,
                onSelected: (v) => setState(() => _rootId = v ?? _rootId),
                dropdownMenuEntries: [
                  for (final p in people)
                    DropdownMenuEntry(
                      value: p.id,
                      label: p.fullName,
                      labelWidget: Text('${p.fullName} (${p.birthDate.year})'),
                    ),
                ],
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            Text(l.treePdfGenerations, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            SegmentedButton<int>(
              segments: [
                ButtonSegment(value: 0, label: Text(l.treePdfGenAll)),
                for (final n in [2, 3, 4]) ButtonSegment(value: n, label: Text('$n')),
              ],
              selected: {_generations},
              onSelectionChanged: (v) => setState(() => _generations = v.first),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(l.treePdfStyle, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: AppSpacing.xs),
            SegmentedButton<PdfStyle>(
              segments: [
                ButtonSegment(
                  value: PdfStyle.chart,
                  icon: const Icon(Icons.account_tree),
                  label: Text(l.treePdfStyleChart),
                ),
                ButtonSegment(
                  value: PdfStyle.list,
                  icon: const Icon(Icons.format_list_bulleted),
                  label: Text(l.treePdfStyleList),
                ),
              ],
              selected: {_style},
              onSelectionChanged: (v) => setState(() => _style = v.first),
            ),
            if (hasPhotos && _style == PdfStyle.chart)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l.treePdfPhotos),
                value: _photos,
                onChanged: (v) => setState(() => _photos = v),
              ),
            const SizedBox(height: AppSpacing.sm),
            Text(l.treePdfFontNote, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: AppSpacing.md),
            FilledButton.icon(
              key: const ValueKey('print.preview'),
              icon: const Icon(Icons.print),
              label: Text(l.treePdfPreview),
              onPressed: () => Navigator.of(context).pop(
                TreePdfOptions(
                  scope: _scope,
                  style: _style,
                  rootId: _scope == PdfScope.all ? null : _rootId,
                  maxGenerations: _generations == 0 ? null : _generations,
                  photos: _photos && hasPhotos && _style == PdfStyle.chart,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Loads the bundled Noto fonts (Latin + Jawi).
Future<TreePdfFonts> loadTreePdfFonts() async {
  Future<pw.Font> font(String name) async => pw.Font.ttf(await rootBundle.load('assets/fonts/$name'));
  return TreePdfFonts(
    regular: await font('NotoSans-Regular.ttf'),
    bold: await font('NotoSans-Bold.ttf'),
    fallback: [await font('NotoNaskhArabic-Regular.ttf')],
  );
}

TreePdfText treePdfText(AppLocalizations l, String familyName, DateTime now) => TreePdfText(
  title: l.treePdfTitle(familyName),
  generated: l.treePdfGenerated(DateFormat.yMMMd(l.localeName).format(now)),
  legend: l.treePdfLegend,
  page: l.treePdfPage,
  pageShort: l.treePdfPageShort,
  continues: l.treePdfContinues,
  overview: l.treePdfOverview,
  overviewHint: l.treePdfOverviewHint,
  deceased: (g) => g == Gender.female ? l.treeLateFemale : l.treeLateMale,
  branchOf: l.treePdfBranchOf,
  generationLabel: (n) => l.treePdfGeneration(n + 1),
);

/// Print preview with print and share buttons (A4).
class TreePrintPreviewScreen extends ConsumerStatefulWidget {
  const TreePrintPreviewScreen({required this.tree, required this.familyName, required this.options, super.key});

  final TreeData tree;
  final String familyName;
  final TreePdfOptions options;

  @override
  ConsumerState<TreePrintPreviewScreen> createState() => _TreePrintPreviewScreenState();
}

class _TreePrintPreviewScreenState extends ConsumerState<TreePrintPreviewScreen> {
  Future<Uint8List>? _pdf;

  Future<Uint8List> _build(AppLocalizations l) async {
    final photos = <String, Uint8List>{};
    if (widget.options.photos) {
      final repo = ref.read(treeRepositoryProvider);
      final withPhotos = widget.tree.persons.values.where((p) => p.photoPath != null).take(200).toList();
      for (var i = 0; i < withPhotos.length; i += 6) {
        final batch = withPhotos.skip(i).take(6).toList();
        final bytes = await Future.wait(batch.map((p) => repo.downloadPhoto(p.photoPath!)));
        for (var j = 0; j < batch.length; j++) {
          if (bytes[j] != null) photos[batch[j].id] = bytes[j]!;
        }
      }
    }
    return buildTreePdf(
      widget.tree,
      text: treePdfText(l, widget.familyName, DateTime.now()),
      fonts: await loadTreePdfFonts(),
      options: widget.options,
      photos: photos,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    _pdf ??= _build(l); // built once; PdfPreview asks again on resize
    final now = DateTime.now();
    final safeName = widget.familyName.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    return Scaffold(
      appBar: AppBar(title: Text(l.treePdfTitle(widget.familyName))),
      body: PdfPreview(
        build: (_) => _pdf!,
        allowPrinting: true,
        allowSharing: true,
        canChangePageFormat: false,
        canChangeOrientation: false,
        canDebug: false,
        pdfFileName: 'Salasilah_${safeName}_${now.year}${now.month}${now.day}.pdf',
        onError: (context, error) => Center(child: Text(context.errorText(error))),
      ),
    );
  }
}
