import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart' show AppLifecycleListener;
import 'package:uuid/uuid.dart';

import '../../shared/providers/session_controller.dart';
import '../../shared/providers/supabase_providers.dart';
import '../errors/app_failure.dart';
import 'local_database.dart';
import 'offline_store.dart';

/// Offline-capable writes. Each maps to an idempotent server RPC, so replaying
/// an op whose first attempt had an unknown outcome is safe.
enum OutboxKind {
  todoUpsertItem('todo.upsert_item', 'upsert_todo_item'),
  todoSetStatus('todo.set_status', 'set_todo_item_status'),
  todoDeleteItem('todo.delete_item', 'delete_todo_item'),
  chatSendText('chat.send_text', 'send_message'),
  eventRsvp('calendar.rsvp', 'set_event_rsvp');

  const OutboxKind(this.key, this.rpc);

  final String key;
  final String rpc;

  static OutboxKind? parse(String key) {
    for (final k in values) {
      if (k.key == key) return k;
    }
    return null;
  }
}

/// Runs one RPC (overridable in tests).
typedef RpcRunner = Future<void> Function(String rpc, Map<String, dynamic> params);

final rpcRunnerProvider = Provider<RpcRunner>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return (rpc, params) => client.rpc<dynamic>(rpc, params: params);
});

/// Connectivity changes (true = some network). Overridable in tests.
final connectivityProvider = StreamProvider<bool>((ref) async* {
  final c = Connectivity();
  try {
    yield !(await c.checkConnectivity()).contains(ConnectivityResult.none);
    yield* c.onConnectivityChanged.map((r) => !r.contains(ConnectivityResult.none));
  } catch (_) {
    yield true; // plugin unavailable (tests, unsupported platform)
  }
});

class SyncResult {
  const SyncResult(this.op, {this.failure});

  final OutboxOp op;

  /// null = applied on the server.
  final AppFailure? failure;

  OutboxKind? get kind => OutboxKind.parse(op.kind);
  bool get ok => failure == null;
}

class SyncState {
  const SyncState({this.ops = const [], this.online = true, this.syncing = false, this.lastSyncedAt});

  final List<OutboxOp> ops;
  final bool online;
  final bool syncing;
  final DateTime? lastSyncedAt;

  int get pending => ops.where((o) => o.status == 'pending').length;
  int get failed => ops.where((o) => o.status == 'failed').length;
  bool get hasWork => ops.isNotEmpty;

  bool hasPendingFor(String entityId) => ops.any((o) => o.entityId == entityId);

  SyncState copyWith({List<OutboxOp>? ops, bool? online, bool? syncing, DateTime? lastSyncedAt}) => SyncState(
    ops: ops ?? this.ops,
    online: online ?? this.online,
    syncing: syncing ?? this.syncing,
    lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
  );
}

final syncEngineProvider = NotifierProvider<SyncEngine, SyncState>(SyncEngine.new);

/// Replays the outbox in order when the backend is reachable: after
/// connectivity returns, when the app resumes, every 20 s while work is
/// queued, and right after something is queued.
///
/// * success       -> op removed, [results] emits it (screens refresh)
/// * network error -> op stays pending, replay stops until the next trigger
/// * other error   -> op marked failed (e.g. conflicting edit, lost access);
///                    shown on the sync screen where it can be retried or
///                    discarded. Later ops still run.
class SyncEngine extends Notifier<SyncState> {
  static const _uuid = Uuid();
  static const retryEvery = Duration(seconds: 20);

  final _results = StreamController<SyncResult>.broadcast();
  Timer? _timer;
  Future<void>? _inFlight;

  Stream<SyncResult> get results => _results.stream;

  LocalDatabase get _db => ref.read(localDatabaseProvider);
  String? get _owner => ref.read(currentUserIdProvider);

  @override
  SyncState build() {
    final owner = ref.watch(currentUserIdProvider);
    final db = ref.watch(localDatabaseProvider);
    StreamSubscription<List<OutboxOp>>? sub;
    if (owner != null) {
      sub = db.watchOutbox(owner).listen((ops) {
        state = state.copyWith(ops: ops);
        _schedule();
      }, onError: (Object _) {});
    }
    ref.listen<bool>(networkStatusProvider, (prev, reachable) {
      state = state.copyWith(online: reachable);
      if (reachable && prev == false) unawaited(flush());
    });
    ref.listen<AsyncValue<bool>>(connectivityProvider, (prev, next) {
      final connected = next.value ?? true;
      if (connected && prev?.value == false) {
        ref.read(networkStatusProvider.notifier).report(reachable: true);
        unawaited(flush());
      } else if (!connected) {
        ref.read(networkStatusProvider.notifier).report(reachable: false);
      }
    });
    AppLifecycleListener? lifecycle;
    try {
      lifecycle = AppLifecycleListener(onResume: () => unawaited(flush()));
    } catch (_) {
      // No widgets binding (pure Dart tests): resume trigger not needed.
    }
    ref.onDispose(() {
      sub?.cancel();
      _timer?.cancel();
      lifecycle?.dispose();
    });
    return SyncState(online: ref.read(networkStatusProvider));
  }

  void _schedule() {
    _timer?.cancel();
    if (state.pending == 0) return;
    _timer = Timer(state.online ? const Duration(milliseconds: 200) : retryEvery, () => unawaited(flush()));
  }

  /// Queues a write. Call when a direct request failed for lack of network,
  /// or when earlier writes to the same entity are still queued (order).
  Future<void> enqueue({
    required OutboxKind kind,
    required String entityId,
    required String scope,
    required Map<String, dynamic> params,
  }) async {
    final owner = _owner;
    if (owner == null) throw const AppFailure(FailureKind.forbidden);
    await _db.enqueue(
      OutboxOpsCompanion.insert(
        id: _uuid.v4(),
        owner: owner,
        kind: kind.key,
        entityId: entityId,
        scope: scope,
        payload: jsonEncode(params),
        createdAt: DateTime.now(),
      ),
    );
    // Update immediately (the table watcher is asynchronous) so a following
    // write to the same entity is queued behind this one.
    state = state.copyWith(ops: await _db.allOps(owner));
    _schedule();
  }

  /// Replays pending ops in order. Safe to call any time; a call while a
  /// replay is running waits for that replay.
  Future<void> flush() => _inFlight ??= _flush().whenComplete(() => _inFlight = null);

  Future<void> _flush() async {
    final owner = _owner;
    if (owner == null) return;
    state = state.copyWith(syncing: true);
    final run = ref.read(rpcRunnerProvider);
    try {
      for (final op in await _db.pendingOps(owner)) {
        final kind = OutboxKind.parse(op.kind);
        if (kind == null) {
          await _db.markAttempt(op.id, failed: true, error: 'unknown_kind');
          continue;
        }
        try {
          await run(kind.rpc, Map<String, dynamic>.from(jsonDecode(op.payload) as Map));
          await _db.removeOp(op.id);
          ref.read(networkStatusProvider.notifier).report(reachable: true);
          _results.add(SyncResult(op));
        } catch (e) {
          final failure = AppFailure.from(e);
          if (failure.kind == FailureKind.network) {
            await _db.markAttempt(op.id, failed: false, error: failure.kind.name);
            ref.read(networkStatusProvider.notifier).report(reachable: false);
            break; // keep order: stop until the next trigger
          }
          await _db.markAttempt(op.id, failed: true, error: failure.kind.name);
          _results.add(SyncResult(op, failure: failure));
        }
      }
      state = state.copyWith(lastSyncedAt: DateTime.now(), ops: await _db.allOps(owner));
    } finally {
      state = state.copyWith(syncing: false);
      _schedule();
    }
  }

  /// Puts failed ops back in the queue and replays them.
  Future<void> retryFailed() async {
    final owner = _owner;
    if (owner == null) return;
    await _db.resetFailed(owner);
    await flush();
  }

  Future<void> discard(String opId) async {
    await _db.removeOp(opId);
    final owner = _owner;
    if (owner != null) state = state.copyWith(ops: await _db.allOps(owner));
  }

  /// Ops waiting for [scope] (a list, conversation or event).
  Future<List<OutboxOp>> opsFor(String scope) async {
    final owner = _owner;
    return owner == null ? const [] : _db.opsForScope(owner, scope);
  }
}

/// Decoded payload of an op.
Map<String, dynamic> opParams(OutboxOp op) => Map<String, dynamic>.from(jsonDecode(op.payload) as Map);
