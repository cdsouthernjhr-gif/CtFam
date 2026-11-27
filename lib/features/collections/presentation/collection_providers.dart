import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/utils/l10n_ext.dart';
import '../../family/presentation/family_providers.dart';
import '../data/collections_repository.dart';
import '../domain/collection_models.dart';

final collectionSummariesProvider = FutureProvider.autoDispose.family<List<CollectionSummary>, String>(
  (ref, familyId) => ref.watch(collectionsRepositoryProvider).summaries(familyId),
);

final _collectionTickProvider = StreamProvider.autoDispose.family<int, String>((ref, id) {
  var n = 0;
  return ref.watch(collectionsRepositoryProvider).watch(id).map((_) => ++n);
});

/// One collection, refreshed on realtime changes.
final collectionProvider = FutureProvider.autoDispose.family<Collection?, String>((ref, id) {
  ref.watch(_collectionTickProvider(id));
  return ref.watch(collectionsRepositoryProvider).collection(id);
});

/// "RM1,234.50"
String formatRM(BuildContext context, int sen) => NumberFormat.currency(
  locale: context.l10n.localeName == 'en' ? 'en_MY' : 'ms_MY',
  symbol: 'RM',
  decimalDigits: 2,
).format(sen / 100);

/// Amount as typed in a field ("1234.50").
String amountText(int sen) => (sen / 100).toStringAsFixed(2);

/// Receipt image from the private bucket.
class ReceiptImage extends ConsumerWidget {
  const ReceiptImage({required this.path, this.fit = BoxFit.cover, super.key});

  final String path;
  final BoxFit fit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.watch(signedUrlProvider((bucket: CollectionsRepository.receiptBucket, path: path)));
    final scheme = Theme.of(context).colorScheme;
    return url.maybeWhen(
      data: (u) => Image.network(
        u,
        fit: fit,
        errorBuilder: (_, _, _) => ColoredBox(
          color: scheme.surfaceContainerHighest,
          child: Icon(Icons.broken_image_outlined, color: scheme.outline),
        ),
      ),
      orElse: () => ColoredBox(color: scheme.surfaceContainerHighest),
    );
  }
}

Future<void> showReceipt(BuildContext context, String path) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (ctx) => Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: Text(ctx.l10n.receipt)),
      body: InteractiveViewer(
        maxScale: 5,
        child: Center(
          child: ReceiptImage(path: path, fit: BoxFit.contain),
        ),
      ),
    ),
  ),
);
