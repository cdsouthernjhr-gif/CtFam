import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/router/routes.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/dialogs.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/widgets/user_avatar.dart';
import '../../../shared/providers/session_controller.dart';
import '../../settings/data/profile_repository.dart';
import '../data/family_repository.dart';
import '../domain/family_models.dart';
import '../domain/family_permissions.dart';
import 'family_providers.dart';

class FamilySettingsScreen extends ConsumerWidget {
  const FamilySettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final familyId = ref.watch(activeFamilyIdProvider);
    final role = ref.watch(myRoleProvider) ?? FamilyRole.member;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.familySettingsTitle)),
      body: familyId == null
          ? const LoadingView()
          : AsyncValueView(
              value: ref.watch(familyProvider(familyId)),
              onRetry: () => ref.invalidate(familyProvider(familyId)),
              data: (family) => _SettingsBody(family: family, role: role),
            ),
    );
  }
}

class _SettingsBody extends ConsumerStatefulWidget {
  const _SettingsBody({required this.family, required this.role});

  final Family family;
  final FamilyRole role;

  @override
  ConsumerState<_SettingsBody> createState() => _SettingsBodyState();
}

class _SettingsBodyState extends ConsumerState<_SettingsBody> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.family.name);
  late final _description = TextEditingController(text: widget.family.description ?? '');
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() action, {String? success}) async {
    setState(() => _busy = true);
    try {
      await action();
      ref.invalidate(familyProvider(widget.family.id));
      if (mounted && success != null) context.showMessage(success);
    } catch (e) {
      if (mounted) context.showError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickImage() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1024, imageQuality: 85);
    if (file == null) return;
    final type = contentTypeForFileName(file.name) ?? file.mimeType;
    final bytes = await file.readAsBytes();
    if (type == null || !allowedImageTypes.contains(type) || bytes.lengthInBytes > maxImageBytes) {
      if (mounted) context.showMessage(context.l10n.errorStorageRejected, error: true);
      return;
    }
    await _guard(
      () => ref.read(familyRepositoryProvider).uploadFamilyImage(widget.family.id, bytes, type),
      success: mounted ? context.l10n.saved : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final repo = ref.read(familyRepositoryProvider);
    final family = widget.family;
    final canEdit = FamilyPermissions.canEditFamily(widget.role);
    final isOwner = widget.role == FamilyRole.owner;

    return AbsorbPointer(
      absorbing: _busy,
      child: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          if (_busy) const LinearProgressIndicator(),
          Center(
            child: StorageAvatar(
              bucket: 'family-media',
              path: family.imagePath,
              initials: family.name.substring(0, 1).toUpperCase(),
              icon: family.imagePath == null ? Icons.family_restroom_rounded : null,
              radius: 44,
            ),
          ),
          if (canEdit)
            Center(
              child: TextButton.icon(
                onPressed: _pickImage,
                icon: const Icon(Icons.photo_camera_outlined),
                label: Text(l10n.changeFamilyPhoto),
              ),
            ),
          const SizedBox(height: AppSpacing.md),
          Form(
            key: _form,
            child: Column(
              children: [
                TextFormField(
                  controller: _name,
                  enabled: canEdit,
                  maxLength: 80,
                  decoration: InputDecoration(labelText: l10n.fieldFamilyName),
                  validator: (v) => l10n.validation(Validators.familyName(v)),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextFormField(
                  controller: _description,
                  enabled: canEdit,
                  maxLength: 500,
                  maxLines: 3,
                  minLines: 1,
                  decoration: InputDecoration(labelText: l10n.fieldDescription),
                ),
              ],
            ),
          ),
          if (canEdit) ...[
            FilledButton(
              onPressed: () {
                if (!_form.currentState!.validate()) return;
                _guard(
                  () => repo.updateFamily(family.id, name: _name.text, description: _description.text),
                  success: l10n.saved,
                );
              },
              child: Text(l10n.actionSave),
            ),
            const SizedBox(height: AppSpacing.md),
            SwitchListTile(
              title: Text(l10n.requireApprovalSetting),
              value: family.requireInviteApproval,
              onChanged: (v) => _guard(() => repo.updateFamily(family.id, requireInviteApproval: v)),
            ),
            if (isOwner)
              SwitchListTile(
                title: Text(l10n.allowAdminInvitesSetting),
                value: family.allowAdminInvites,
                onChanged: (v) => _guard(() => repo.updateFamily(family.id, allowAdminInvites: v)),
              ),
          ],
          const Divider(height: AppSpacing.xl),
          ListTile(
            leading: const Icon(Icons.logout),
            title: Text(l10n.leaveFamily),
            onTap: () async {
              final ok = await confirmDialog(
                context,
                title: l10n.confirmLeaveTitle,
                message: l10n.confirmLeaveBody,
                destructive: true,
              );
              if (!ok || !context.mounted) return;
              final router = GoRouter.of(context);
              await _guard(() async {
                await repo.leaveFamily(family.id);
                await ref.read(sessionControllerProvider.notifier).refresh();
                router.go(Routes.home);
              });
            },
          ),
          if (FamilyPermissions.canDeleteFamily(widget.role))
            ListTile(
              leading: Icon(Icons.delete_forever_outlined, color: Theme.of(context).colorScheme.error),
              title: Text(l10n.deleteFamily, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () async {
                final typed = await typedConfirmDialog(
                  context,
                  title: l10n.deleteFamily,
                  message: l10n.deleteFamilyBody,
                  expected: family.name,
                  confirmLabel: l10n.actionDelete,
                );
                if (typed == null || !context.mounted) return;
                final router = GoRouter.of(context);
                await _guard(() async {
                  await repo.deleteFamily(family.id, typed);
                  await ref.read(sessionControllerProvider.notifier).refresh();
                  router.go(Routes.home);
                });
              },
            ),
        ],
      ),
    );
  }
}
