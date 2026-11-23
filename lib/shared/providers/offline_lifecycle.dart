import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/offline/offline_store.dart';
import '../../core/offline/sync_engine.dart';
import '../../features/authentication/data/auth_repository.dart';
import 'session_controller.dart';

/// Keeps the sync engine running while signed in and protects on-device data:
/// * another account's cache/outbox on this device is removed when a user
///   signs in (shared phones);
/// * before sign-out / account deletion, queued writes get one last chance to
///   sync, then everything stored locally is wiped.
final offlineLifecycleProvider = Provider<void>((ref) {
  final db = ref.watch(localDatabaseProvider);
  final uid = ref.watch(currentUserIdProvider);
  if (uid != null) {
    ref.watch(syncEngineProvider);
    unawaited(db.wipe(keepOwner: uid).catchError((Object _) {}));
  }

  Future<void> beforeSignOut() async {
    try {
      await ref.read(syncEngineProvider.notifier).flush().timeout(const Duration(seconds: 3));
    } catch (_) {}
    await db.wipe();
  }

  AuthRepository.beforeSignOut.add(beforeSignOut);
  ref.onDispose(() => AuthRepository.beforeSignOut.remove(beforeSignOut));
});
