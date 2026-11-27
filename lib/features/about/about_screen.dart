import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/l10n_ext.dart';
import 'app_features.dart';

final _infoProvider = FutureProvider<PackageInfo>((ref) => PackageInfo.fromPlatform());

/// App name, version, what is new in this version and every feature so far.
class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final locale = l10n.localeName;
    final info = ref.watch(_infoProvider).value;
    final current = info?.version ?? latestFeatureVersion;
    final latest = [
      for (final a in appFeatureAreas)
        for (final f in a.features)
          if (f.since == current) (a, f),
    ];
    final total = appFeatureAreas.fold<int>(0, (n, a) => n + a.features.length);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.aboutTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xl),
        children: [
          Center(
            child: Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Image.asset(
                    'assets/branding/icon.png',
                    width: 80,
                    height: 80,
                    errorBuilder: (_, _, _) {
                      return CircleAvatar(
                        radius: 40,
                        backgroundColor: theme.colorScheme.primaryContainer,
                        child: Icon(Icons.family_restroom, size: 40, color: theme.colorScheme.onPrimaryContainer),
                      );
                    },
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  info?.appName.isNotEmpty == true ? info!.appName : 'FamilySync',
                  style: theme.textTheme.headlineSmall,
                ),
                Text(
                  key: const Key('about.version'),
                  info == null ? '…' : l10n.version('${info.version}+${info.buildNumber}'),
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(l10n.aboutTagline, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
          if (latest.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.lg),
            Card(
              color: theme.colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.aboutNewInVersion(current),
                      style: theme.textTheme.titleMedium?.copyWith(color: theme.colorScheme.onPrimaryContainer),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    for (final (a, f) in latest)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(a.icon, size: 18, color: theme.colorScheme.onPrimaryContainer),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Text(
                                f.text(locale),
                                style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          Text(l10n.aboutAllFeatures(total), style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          for (final a in appFeatureAreas)
            Card(
              key: ValueKey('about.area.${a.en}'),
              child: ExpansionTile(
                leading: Icon(a.icon, color: theme.colorScheme.primary),
                title: Text(a.title(locale)),
                subtitle: Text(l10n.aboutFeatureCount(a.features.length)),
                childrenPadding: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
                children: [
                  for (final f in [...a.features]..sort((x, y) => compareVersions(x.since, y.since)))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.check, size: 16)),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(child: Text(f.text(locale))),
                          const SizedBox(width: AppSpacing.sm),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: f.since == current
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'v${f.since}',
                              style: TextStyle(
                                fontSize: 11,
                                color: f.since == current ? theme.colorScheme.onPrimary : theme.colorScheme.outline,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
