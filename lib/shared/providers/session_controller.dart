import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/errors/app_failure.dart';
import '../../features/family/data/family_repository.dart';
import '../../features/family/domain/family_models.dart';
import 'supabase_providers.dart';

enum SessionStatus {
  /// App built without Supabase configuration.
  unconfigured,
  initializing,
  signedOut,

  /// User opened a password-recovery link and must choose a new password.
  passwordRecovery,

  /// Signed in, but not an active member of any family yet.
  needsFamily,
  ready,

  /// Signed in but memberships could not be loaded (e.g. offline at start).
  error,
}

class SessionState {
  const SessionState({
    required this.status,
    this.user,
    this.memberships = const [],
    this.activeFamilyId,
    this.pendingInviteCode,
    this.failure,
  });

  final SessionStatus status;
  final User? user;
  final List<MyMembership> memberships;
  final String? activeFamilyId;

  /// Invitation code from a deep link opened while signed out.
  final String? pendingInviteCode;
  final AppFailure? failure;

  List<MyMembership> get activeMemberships => memberships.where((m) => m.isActive).toList();
  List<MyMembership> get pendingMemberships => memberships.where((m) => m.status == MemberStatus.pending).toList();

  MyMembership? get activeMembership {
    for (final m in activeMemberships) {
      if (m.familyId == activeFamilyId) return m;
    }
    return null;
  }

  SessionState copyWith({
    SessionStatus? status,
    User? user,
    List<MyMembership>? memberships,
    String? activeFamilyId,
    String? pendingInviteCode,
    bool clearPendingInvite = false,
    AppFailure? failure,
  }) => SessionState(
    status: status ?? this.status,
    user: user ?? this.user,
    memberships: memberships ?? this.memberships,
    activeFamilyId: activeFamilyId ?? this.activeFamilyId,
    pendingInviteCode: clearPendingInvite ? null : (pendingInviteCode ?? this.pendingInviteCode),
    failure: failure,
  );
}

/// Whether Supabase was initialised (overridden in bootstrap/tests).
final supabaseConfiguredProvider = Provider<bool>((ref) => true);

final sessionControllerProvider = NotifierProvider<SessionController, SessionState>(SessionController.new);

class SessionController extends Notifier<SessionState> {
  StreamSubscription<AuthState>? _sub;
  String? _loadedForUser;

  @override
  SessionState build() {
    if (!ref.watch(supabaseConfiguredProvider)) {
      return const SessionState(status: SessionStatus.unconfigured);
    }
    final client = ref.watch(supabaseClientProvider);
    _sub = client.auth.onAuthStateChange.listen(_onAuthEvent, onError: (_) {});
    ref.onDispose(() => _sub?.cancel());

    final user = client.auth.currentUser;
    if (user == null) return const SessionState(status: SessionStatus.signedOut);
    scheduleMicrotask(refresh);
    return SessionState(status: SessionStatus.initializing, user: user);
  }

  void _onAuthEvent(AuthState event) {
    final user = event.session?.user;
    switch (event.event) {
      case AuthChangeEvent.passwordRecovery:
        state = state.copyWith(status: SessionStatus.passwordRecovery, user: user);
      case AuthChangeEvent.signedOut:
        _loadedForUser = null;
        state = SessionState(status: SessionStatus.signedOut, pendingInviteCode: state.pendingInviteCode);
      case AuthChangeEvent.initialSession:
      case AuthChangeEvent.signedIn:
      case AuthChangeEvent.tokenRefreshed:
      case AuthChangeEvent.userUpdated:
        if (user == null) {
          if (state.status != SessionStatus.signedOut) {
            state = SessionState(status: SessionStatus.signedOut, pendingInviteCode: state.pendingInviteCode);
          }
          return;
        }
        if (state.status == SessionStatus.passwordRecovery && event.event != AuthChangeEvent.userUpdated) {
          return; // stay on the reset screen until a new password is set
        }
        if (_loadedForUser != user.id || state.status == SessionStatus.passwordRecovery) {
          state = state.copyWith(status: SessionStatus.initializing, user: user);
          unawaited(refresh());
        }
      default:
        break;
    }
  }

  /// Reloads memberships and the active family preference from the server.
  Future<void> refresh() async {
    final client = ref.read(supabaseClientProvider);
    final user = client.auth.currentUser;
    if (user == null) {
      state = SessionState(status: SessionStatus.signedOut, pendingInviteCode: state.pendingInviteCode);
      return;
    }
    final repo = ref.read(familyRepositoryProvider);
    try {
      final memberships = await repo.myMemberships();
      final preferred = await repo.activeFamilyPreference();
      final active = memberships.where((m) => m.isActive).toList();
      String? activeId;
      if (active.any((m) => m.familyId == preferred)) {
        activeId = preferred;
      } else if (active.any((m) => m.familyId == state.activeFamilyId)) {
        activeId = state.activeFamilyId;
      } else if (active.isNotEmpty) {
        activeId = active.first.familyId;
      }
      _loadedForUser = user.id;
      state = SessionState(
        status: active.isEmpty ? SessionStatus.needsFamily : SessionStatus.ready,
        user: user,
        memberships: memberships,
        activeFamilyId: activeId,
        pendingInviteCode: state.pendingInviteCode,
      );
    } catch (e) {
      state = state.copyWith(status: SessionStatus.error, user: user, failure: AppFailure.from(e));
    }
  }

  Future<void> switchFamily(String familyId) async {
    state = state.copyWith(activeFamilyId: familyId);
    await ref.read(familyRepositoryProvider).setActiveFamily(familyId);
  }

  void setPendingInvite(String code) => state = state.copyWith(pendingInviteCode: code);
  void clearPendingInvite() => state = state.copyWith(clearPendingInvite: true);
}

/// Convenience: the active family id (null until ready).
final activeFamilyIdProvider = Provider<String?>(
  (ref) => ref.watch(sessionControllerProvider.select((s) => s.activeFamilyId)),
);

final currentUserIdProvider = Provider<String?>(
  (ref) => ref.watch(sessionControllerProvider.select((s) => s.user?.id)),
);
