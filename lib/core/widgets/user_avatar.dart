import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../features/family/presentation/family_providers.dart';

/// Circular avatar loading a private Storage object through a signed URL,
/// falling back to initials.
class StorageAvatar extends ConsumerWidget {
  const StorageAvatar({
    required this.initials,
    this.bucket = 'avatars',
    this.path,
    this.radius = 22,
    this.icon,
    super.key,
  });

  final String initials;
  final String bucket;
  final String? path;
  final double radius;
  final IconData? icon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = CircleAvatar(
      radius: radius,
      backgroundColor: scheme.primaryContainer,
      foregroundColor: scheme.onPrimaryContainer,
      child: icon != null
          ? Icon(icon, size: radius)
          : Text(
              initials,
              style: TextStyle(fontSize: radius * 0.75, fontWeight: FontWeight.w600),
            ),
    );
    final p = path;
    if (p == null) return fallback;
    final url = ref.watch(signedUrlProvider((bucket: bucket, path: p)));
    return url.maybeWhen(
      data: (u) => CircleAvatar(
        radius: radius,
        backgroundColor: scheme.primaryContainer,
        backgroundImage: NetworkImage(u),
        onBackgroundImageError: (_, _) {},
      ),
      orElse: () => fallback,
    );
  }
}
