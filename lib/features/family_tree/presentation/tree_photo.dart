import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/utils/l10n_ext.dart';
import '../../family/presentation/family_providers.dart';
import '../../settings/data/profile_repository.dart';
import '../data/tree_repository.dart';

enum PhotoAction { gallery, camera, remove }

/// Gallery / camera / remove. Returns null when cancelled.
Future<PhotoAction?> choosePhotoAction(BuildContext context, {required bool hasPhoto}) {
  final l10n = context.l10n;
  return showModalBottomSheet<PhotoAction>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(l10n.photoFromGallery),
            onTap: () => Navigator.of(ctx).pop(PhotoAction.gallery),
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: Text(l10n.photoFromCamera),
            onTap: () => Navigator.of(ctx).pop(PhotoAction.camera),
          ),
          if (hasPhoto)
            ListTile(
              leading: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error),
              title: Text(l10n.photoRemove, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              onTap: () => Navigator.of(ctx).pop(PhotoAction.remove),
            ),
        ],
      ),
    ),
  );
}

/// Picks and checks an image (JPEG/PNG/WebP, ≤ 5 MB after resizing).
Future<(Uint8List, String)?> pickTreeImage(BuildContext context, PhotoAction action, {double maxWidth = 1024}) async {
  final file = await ImagePicker().pickImage(
    source: action == PhotoAction.camera ? ImageSource.camera : ImageSource.gallery,
    maxWidth: maxWidth,
    imageQuality: 85,
  );
  if (file == null) return null;
  final type = contentTypeForFileName(file.name) ?? file.mimeType;
  final bytes = await file.readAsBytes();
  if (type == null || !allowedImageTypes.contains(type) || bytes.lengthInBytes > maxImageBytes) {
    if (context.mounted) context.showMessage(context.l10n.errorStorageRejected, error: true);
    return null;
  }
  return (bytes, type);
}

/// Rectangular image from the private tree bucket (signed URL).
class TreeImage extends ConsumerWidget {
  const TreeImage({required this.path, this.fit = BoxFit.cover, super.key});

  final String path;
  final BoxFit fit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = ref.watch(signedUrlProvider((bucket: TreeRepository.photoBucket, path: path)));
    final scheme = Theme.of(context).colorScheme;
    return url.maybeWhen(
      data: (u) => Image.network(
        u,
        fit: fit,
        errorBuilder: (_, _, _) => ColoredBox(color: scheme.surfaceContainerHighest),
      ),
      orElse: () => ColoredBox(color: scheme.surfaceContainerHighest),
    );
  }
}
