import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/providers/supabase_providers.dart';
import '../errors/app_failure.dart';
import 'local_database.dart';

/// The on-device database (one per app process).
final localDatabaseProvider = Provider<LocalDatabase>((ref) {
  final db = LocalDatabase();
  ref.onDispose(db.close);
  return db;
});

/// Whether the backend was reachable on the last request (or after the
/// device regained connectivity). Starts optimistic.
final networkStatusProvider = NotifierProvider<NetworkStatus, bool>(NetworkStatus.new);

class NetworkStatus extends Notifier<bool> {
  @override
  bool build() => true;

  void report({required bool reachable}) {
    if (state != reachable) state = reachable;
  }
}

final offlineStoreProvider = Provider<OfflineStore>(
  (ref) => OfflineStore(
    ref.watch(localDatabaseProvider),
    currentUserId: () => ref.read(supabaseClientProvider).auth.currentUser?.id,
    onReachability: (ok) => ref.read(networkStatusProvider.notifier).report(reachable: ok),
  ),
);

/// Network-first reads with an on-device fallback.
///
/// Every successful response is stored (raw JSON, per user). When a request
/// fails because the network is unavailable, the last stored copy is returned
/// instead; other errors (permissions, validation) are never masked.
class OfflineStore {
  OfflineStore(this._db, {required this.currentUserId, this.onReachability});

  final LocalDatabase _db;

  /// The signed-in user; cached data is stored per user.
  final String? Function() currentUserId;

  /// Told whether each request reached the backend.
  final void Function(bool)? onReachability;

  LocalDatabase get db => _db;
  String? get owner => currentUserId();

  /// List of rows (PostgREST select or a set-returning RPC).
  Future<List<Map<String, dynamic>>> rows(String key, Future<List<dynamic>> Function() fetch) async {
    final value = await _read(key, fetch);
    return [for (final r in value as List) Map<String, dynamic>.from(r as Map)];
  }

  /// A single row or null.
  Future<Map<String, dynamic>?> row(String key, Future<Map<String, dynamic>?> Function() fetch) async {
    final value = await _read(key, fetch);
    return value == null ? null : Map<String, dynamic>.from(value as Map);
  }

  /// Any JSON-encodable value (numbers, strings, nested maps/lists).
  Future<Object?> value(String key, Future<Object?> Function() fetch) => _read(key, fetch);

  Future<Object?> _read(String key, Future<Object?> Function() fetch) async {
    final owner = currentUserId();
    try {
      final result = await fetch();
      onReachability?.call(true);
      if (owner != null) {
        unawaited(_db.writeCache(owner, key, jsonEncode(result)).catchError((Object _) {}));
      }
      return result;
    } catch (e) {
      final failure = AppFailure.from(e);
      if (failure.kind != FailureKind.network || owner == null) rethrow;
      onReachability?.call(false);
      final cached = await _db.readCache(owner, key).catchError((Object _) => null);
      if (cached == null) throw failure;
      return jsonDecode(cached);
    }
  }
}
