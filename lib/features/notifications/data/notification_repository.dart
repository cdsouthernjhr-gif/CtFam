import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_failure.dart';
import '../../../core/offline/offline_store.dart';
import '../../../shared/providers/supabase_providers.dart';
import '../domain/notification_models.dart';

final notificationRepositoryProvider = Provider<NotificationRepository>(
  (ref) => NotificationRepository(ref.watch(supabaseClientProvider), offline: ref.watch(offlineStoreProvider)),
);

class NotificationRepository {
  NotificationRepository(this._client, {this._offline});

  final SupabaseClient _client;
  final OfflineStore? _offline;

  // Offline: last successful responses are served when the network is down.
  Future<List<Map<String, dynamic>>> _cachedRows(String key, Future<List<dynamic>> Function() fetch) {
    final store = _offline;
    if (store == null) return fetch().then((r) => [for (final x in r) Map<String, dynamic>.from(x as Map)]);
    return store.rows(key, fetch);
  }

  Future<Object?> _offlineValue(String key, Future<Object?> Function() fetch) {
    final store = _offline;
    return store == null ? fetch() : store.value(key, fetch);
  }

  String get _uid {
    final id = _client.auth.currentUser?.id;
    if (id == null) throw const AppFailure(FailureKind.forbidden, 'not signed in');
    return id;
  }

  Future<List<AppNotification>> list({int limit = 100}) => _guard(() async {
    final uid = _uid;
    final rows = await _cachedRows(
      'notifications:inbox',
      () => _client
          .from('notifications')
          .select('id, type, title, body, data, read_at, created_at')
          .eq('user_id', uid)
          .order('created_at', ascending: false)
          .limit(limit),
    );
    return rows.map(AppNotification.fromJson).toList();
  });

  Future<int> unreadCount() => _guard(() async {
    final uid = _uid;
    final count = await _offlineValue(
      'notifications:unread',
      () async =>
          (await _client
                  .from('notifications')
                  .select('id')
                  .eq('user_id', uid)
                  .isFilter('read_at', null)
                  .count(CountOption.exact))
              .count,
    );
    return (count as num?)?.toInt() ?? 0;
  });

  Future<void> markRead([List<String>? ids]) =>
      _guard(() => _client.rpc<int>('mark_notifications_read', params: {'p_ids': ids}));

  Future<NotificationPrefs> prefs() => _guard(() async {
    final row = await _client.from('user_preferences').select(NotificationPrefs.columns).eq('user_id', _uid).single();
    return NotificationPrefs.fromJson(row);
  });

  Future<void> updatePrefs(Map<String, dynamic> patch) =>
      _guard(() => _client.from('user_preferences').update(patch).eq('user_id', _uid));

  Future<int> postAnnouncement(String familyId, {required String title, required String body}) => _guard(
    () => _client.rpc<int>(
      'post_announcement',
      params: {'p_family_id': familyId, 'p_title': title.trim(), 'p_body': body.trim()},
    ),
  );

  Future<void> registerDeviceToken(String token, {String? deviceName, String? appVersion}) => _guard(
    () => _client.rpc<void>(
      'register_device_token',
      params: {'p_token': token, 'p_device_name': deviceName, 'p_app_version': appVersion},
    ),
  );

  Future<void> deleteDeviceToken(String token) =>
      _guard(() => _client.from('device_tokens').delete().eq('token', token));

  /// Emits whenever the signed-in user's inbox changes (`notifications:{uid}`).
  Stream<void> watchInbox() {
    late final RealtimeChannel channel;
    final uid = _uid;
    final controller = StreamController<void>.broadcast();
    controller.onListen = () {
      channel = _client
          .channel('notifications:$uid')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'notifications',
            filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'user_id', value: uid),
            callback: (_) => controller.add(null),
          )
          .subscribe((status, _) {
            if (status == RealtimeSubscribeStatus.subscribed) controller.add(null);
          });
    };
    controller.onCancel = () async {
      await _client.removeChannel(channel);
      await controller.close();
    };
    return controller.stream;
  }

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } catch (e) {
      throw AppFailure.from(e);
    }
  }
}
