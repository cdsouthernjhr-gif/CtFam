import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/config/app_config.dart';
import '../../authentication/data/auth_repository.dart';
import '../data/notification_repository.dart';
import '../domain/notification_models.dart';

FirebaseOptions get firebaseOptions => const FirebaseOptions(
  apiKey: AppConfig.firebaseApiKey,
  appId: AppConfig.firebaseAppId,
  messagingSenderId: AppConfig.firebaseMessagingSenderId,
  projectId: AppConfig.firebaseProjectId,
);

/// Background/terminated messages that carry a `notification` block are shown
/// by Android itself; nothing else to do here (no plaintext is stored).
@pragma('vm:entry-point')
Future<void> firebaseBackgroundHandler(RemoteMessage message) async {
  if (Firebase.apps.isEmpty) await Firebase.initializeApp(options: firebaseOptions);
}

/// Android notification channels (ids must match the send-push function).
const pushChannels = [
  AndroidNotificationChannel(
    'familysync_messages',
    'Mesej',
    description: 'Mesej peribadi dan kumpulan',
    importance: Importance.high,
  ),
  AndroidNotificationChannel('familysync_tasks', 'Tugasan', description: 'Tugasan baharu, diberi dan siap'),
  AndroidNotificationChannel(
    'familysync_family',
    'Keluarga',
    description: 'Pengumuman, permintaan menyertai dan acara',
  ),
];

final pushServiceProvider = Provider<PushService>((ref) {
  final service = PushService(ref);
  ref.onDispose(service.dispose);
  return service;
});

/// Wires FCM + local notifications. Inert when Firebase is not configured.
class PushService {
  PushService(this._ref);

  final Ref _ref;
  final _local = FlutterLocalNotificationsPlugin();
  final _subs = <StreamSubscription<Object?>>[];
  final _shown = <String>{};
  bool _started = false;
  String? _token;

  /// Navigates to an in-app route (set by the app; validated routes only).
  void Function(String route)? onOpenRoute;

  /// Returns the route currently on screen (to skip notifying about the
  /// conversation the user is looking at).
  String? Function()? currentRoute;

  bool get enabled => AppConfig.isPushConfigured && !kIsWeb;

  Future<void> start() async {
    if (!enabled || _started) return;
    _started = true;
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp(options: firebaseOptions);
      await _initLocal();
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      await _local
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();

      // FCM registration tokens are what the send-push function targets via
      // the HTTP v1 `message.token` field. firebase_messaging 17 deprecates
      // getToken/onTokenRefresh/deleteToken in favour of Firebase Installation
      // IDs (register/onRegistered); migrating requires a server change and is
      // tracked in docs/STATUS.md.
      // ignore: deprecated_member_use
      _token = await messaging.getToken();
      if (_token != null) await _register(_token!);
      _subs.add(
        // ignore: deprecated_member_use
        messaging.onTokenRefresh.listen((t) {
          _token = t;
          _register(t);
        }),
      );
      _subs.add(FirebaseMessaging.onMessage.listen(_showForeground));
      _subs.add(FirebaseMessaging.onMessageOpenedApp.listen((m) => _open(m.data['route'])));
      final initial = await messaging.getInitialMessage();
      if (initial != null) _open(initial.data['route']);
      final launch = await _local.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) _open(launch!.notificationResponse?.payload);

      AuthRepository.beforeSignOut.add(_unregister);
    } catch (e) {
      if (kDebugMode) debugPrint('Push unavailable: $e');
      _started = false;
    }
  }

  Future<void> _initLocal() async {
    await _local.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('ic_stat_notify')),
      onDidReceiveNotificationResponse: (r) => _open(r.payload),
    );
    final android = _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    for (final c in pushChannels) {
      await android?.createNotificationChannel(c);
    }
  }

  Future<void> _register(String token) async {
    final info = await PackageInfo.fromPlatform();
    await _ref
        .read(notificationRepositoryProvider)
        .registerDeviceToken(token, deviceName: 'Android', appVersion: '${info.version}+${info.buildNumber}')
        .catchError((Object _) {});
  }

  /// Removes this device from the account before sign-out.
  Future<void> _unregister() async {
    final t = _token;
    if (t != null) await _ref.read(notificationRepositoryProvider).deleteDeviceToken(t).catchError((Object _) {});
    // ignore: deprecated_member_use
    await FirebaseMessaging.instance.deleteToken().catchError((Object _) {});
    _token = null;
    _started = false;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    AuthRepository.beforeSignOut.remove(_unregister);
  }

  Future<void> _showForeground(RemoteMessage m) async {
    final id = m.data['notification_id'] as String? ?? m.messageId ?? '';
    if (id.isEmpty || !_shown.add(id)) return; // duplicate delivery
    final route = safeNotificationRoute(m.data['route']);
    if (route != null && route == currentRoute?.call()) return; // already looking at it
    final n = m.notification;
    if (n == null) return;
    final channel = switch (m.data['channel']) {
      'messages' => pushChannels[0],
      'tasks' => pushChannels[1],
      _ => pushChannels[2],
    };
    await _local.show(
      id: id.hashCode & 0x7fffffff,
      title: n.title,
      body: n.body,
      payload: route,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: channel.importance,
          priority: channel.importance == Importance.high ? Priority.high : Priority.defaultPriority,
          tag: m.data['tag'] as String?,
          visibility: NotificationVisibility.private,
        ),
      ),
    );
  }

  void _open(Object? raw) {
    final route = safeNotificationRoute(raw);
    if (route != null) onOpenRoute?.call(route);
  }

  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
  }
}
