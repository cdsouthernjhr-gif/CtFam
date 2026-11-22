import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/session_controller.dart';
import '../../invitation/data/invitation_repository.dart';
import '../../invitation/domain/invitation_models.dart';
import '../../settings/data/profile_repository.dart';
import '../data/family_repository.dart';
import '../domain/family_models.dart';

/// Ticks on every realtime change of the family. Subscribed only while a
/// screen watches it (autoDispose removes the channel on dispose).
final familyChangesProvider = StreamProvider.autoDispose.family<int, String>((ref, familyId) {
  var tick = 0;
  return ref.watch(familyRepositoryProvider).watchFamily(familyId).map((_) => ++tick);
});

final familyProvider = FutureProvider.autoDispose.family<Family, String>((ref, familyId) {
  ref.watch(familyChangesProvider(familyId));
  return ref.watch(familyRepositoryProvider).family(familyId);
});

final familyMembersProvider = FutureProvider.autoDispose.family<List<FamilyMember>, String>((ref, familyId) {
  ref.watch(familyChangesProvider(familyId));
  return ref.watch(familyRepositoryProvider).members(familyId);
});

final familyActivityProvider = FutureProvider.autoDispose.family<List<ActivityEntry>, String>((ref, familyId) {
  ref.watch(familyChangesProvider(familyId));
  return ref.watch(familyRepositoryProvider).activity(familyId);
});

final invitationsProvider = FutureProvider.autoDispose.family<List<Invitation>, String>((ref, familyId) {
  return ref.watch(invitationRepositoryProvider).list(familyId);
});

/// My role in the active family, from the session.
final myRoleProvider = Provider<FamilyRole?>((ref) {
  return ref.watch(sessionControllerProvider.select((s) => s.activeMembership?.role));
});

typedef StorageRef = ({String bucket, String path});

/// Signed URL cache: kept for 50 minutes (URLs are valid for 60).
final signedUrlProvider = FutureProvider.autoDispose.family<String, StorageRef>((ref, obj) async {
  final link = ref.keepAlive();
  final timer = Timer(const Duration(minutes: 50), link.close);
  ref.onDispose(timer.cancel);
  return ref.watch(profileRepositoryProvider).signedUrl(obj.bucket, obj.path);
});

final myProfileProvider = FutureProvider.autoDispose<Profile>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(profileRepositoryProvider).me();
});
