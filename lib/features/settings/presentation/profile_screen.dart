import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/router/routes.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/dialogs.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/widgets/user_avatar.dart';
import '../../authentication/data/auth_repository.dart';
import '../../family/domain/family_models.dart';
import '../../family/presentation/family_providers.dart';
import '../data/profile_repository.dart';
import 'app_settings.dart';

final _packageInfoProvider = FutureProvider<PackageInfo>((ref) => PackageInfo.fromPlatform());

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.profileTitle)),
      body: AsyncValueView(
        value: ref.watch(myProfileProvider),
        onRetry: () => ref.invalidate(myProfileProvider),
        data: (p) => _ProfileBody(profile: p),
      ),
    );
  }
}

class _ProfileBody extends ConsumerStatefulWidget {
  const _ProfileBody({required this.profile});

  final Profile profile;

  @override
  ConsumerState<_ProfileBody> createState() => _ProfileBodyState();
}

class _ProfileBodyState extends ConsumerState<_ProfileBody> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.profile.displayName);
  late final _phone = TextEditingController(text: widget.profile.phone ?? '');
  late final _bio = TextEditingController(text: widget.profile.bio ?? '');
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _bio.dispose();
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() action, {String? success}) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted && success != null) context.showMessage(success);
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changePhoto() async {
    final l10n = context.l10n;
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 512, imageQuality: 85);
    if (file == null) return;
    final type = contentTypeForFileName(file.name) ?? file.mimeType;
    final bytes = await file.readAsBytes();
    if (type == null || !allowedImageTypes.contains(type) || bytes.lengthInBytes > maxImageBytes) {
      if (mounted) context.showMessage(l10n.errorStorageRejected, error: true);
      return;
    }
    await _guard(() async {
      await ref.read(profileRepositoryProvider).uploadAvatar(bytes, type, previousPath: widget.profile.avatarPath);
      ref.invalidate(myProfileProvider);
    }, success: l10n.saved);
  }

  Future<void> _deleteAccount() async {
    final l10n = context.l10n;
    final blockers = await ref.read(profileRepositoryProvider).accountDeletionBlockers();
    if (!mounted) return;
    if (blockers.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l10n.deleteAccount),
          content: Text(l10n.deleteAccountBlocked(blockers.join(', '))),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.actionClose))],
        ),
      );
      return;
    }
    final typed = await typedConfirmDialog(
      context,
      title: l10n.deleteAccount,
      message: '${l10n.deleteAccountBody}\n\n${l10n.typeToConfirm(l10n.deleteConfirmWord)}',
      expected: l10n.deleteConfirmWord,
      confirmLabel: l10n.actionDelete,
    );
    if (typed == null) return;
    await _guard(() => ref.read(authRepositoryProvider).deleteAccount());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final p = widget.profile;
    final locale = ref.watch(localeProvider);
    final themeMode = ref.watch(themeModeProvider);
    final auth = ref.read(authRepositoryProvider);
    final version = ref.watch(_packageInfoProvider).value;

    return AbsorbPointer(
      absorbing: _busy,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          if (_busy) const LinearProgressIndicator(),
          Center(
            child: StorageAvatar(initials: p.initials, path: p.avatarPath, radius: 44),
          ),
          Center(
            child: TextButton.icon(
              onPressed: _changePhoto,
              icon: const Icon(Icons.photo_camera_outlined),
              label: Text(l10n.changePhoto),
            ),
          ),
          Form(
            key: _form,
            child: Column(
              children: [
                TextFormField(
                  controller: _name,
                  maxLength: 60,
                  decoration: InputDecoration(labelText: l10n.fieldDisplayName),
                  validator: (v) => l10n.validation(Validators.displayName(v)),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextFormField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(labelText: l10n.fieldPhone),
                  validator: (v) => l10n.validation(Validators.optionalPhone(v)),
                ),
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  controller: _bio,
                  maxLength: 280,
                  maxLines: 3,
                  minLines: 1,
                  decoration: InputDecoration(labelText: l10n.fieldBio),
                ),
              ],
            ),
          ),
          FilledButton(
            onPressed: () {
              if (!_form.currentState!.validate()) return;
              _guard(() async {
                await ref
                    .read(profileRepositoryProvider)
                    .update(displayName: _name.text, phone: _phone.text, bio: _bio.text);
                ref.invalidate(myProfileProvider);
              }, success: l10n.saved);
            },
            child: Text(l10n.actionSave),
          ),
          const Divider(height: AppSpacing.xl),
          ListTile(
            leading: const Icon(Icons.translate),
            title: Text(l10n.language),
            trailing: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'ms', label: Text('BM')),
                ButtonSegment(value: 'en', label: Text('EN')),
              ],
              selected: {locale.languageCode},
              onSelectionChanged: (s) => _guard(() => ref.read(localeProvider.notifier).set(Locale(s.first))),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.dark_mode_outlined),
            title: Text(l10n.theme),
            trailing: DropdownButton<ThemeMode>(
              value: themeMode,
              underline: const SizedBox.shrink(),
              items: [
                DropdownMenuItem(value: ThemeMode.system, child: Text(l10n.themeSystem)),
                DropdownMenuItem(value: ThemeMode.light, child: Text(l10n.themeLight)),
                DropdownMenuItem(value: ThemeMode.dark, child: Text(l10n.themeDark)),
              ],
              onChanged: (m) {
                if (m != null) _guard(() => ref.read(themeModeProvider.notifier).set(m));
              },
            ),
          ),
          const Divider(height: AppSpacing.xl),
          ListTile(title: Text(l10n.security, style: Theme.of(context).textTheme.titleSmall)),
          ListTile(
            leading: const Icon(Icons.password),
            title: Text(l10n.changePassword),
            onTap: () => context.push(Routes.changePassword),
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: Text(l10n.signOut),
            onTap: () => _guard(() => auth.signOut()),
          ),
          ListTile(
            leading: const Icon(Icons.devices_other),
            title: Text(l10n.signOutEverywhere),
            onTap: () async {
              final ok = await confirmDialog(context, title: l10n.signOutEverywhere, message: l10n.signOutEverywhere);
              if (ok) await _guard(() => auth.signOut(everywhere: true));
            },
          ),
          ListTile(
            leading: Icon(Icons.delete_forever_outlined, color: Theme.of(context).colorScheme.error),
            title: Text(l10n.deleteAccount, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () => _guard(_deleteAccount),
          ),
          if (version != null)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Text(
                l10n.version('${version.version}+${version.buildNumber}'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}
