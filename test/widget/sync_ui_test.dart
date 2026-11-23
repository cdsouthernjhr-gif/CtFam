import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:familysync/core/offline/local_database.dart';
import 'package:familysync/core/offline/offline_store.dart';
import 'package:familysync/core/offline/sync_engine.dart';
import 'package:familysync/features/sync/presentation/sync_widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/pump_app.dart';

void main() {
  testWidgets('banner shows offline + queued count; sync screen lists and discards', (tester) async {
    final db = LocalDatabase(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await db.enqueue(
      OutboxOpsCompanion.insert(
        id: 'op1',
        owner: 'u1',
        kind: OutboxKind.chatSendText.key,
        entityId: 'm1',
        scope: 'C1',
        payload: '{"p_id":"m1","p_body":"Jumpa esok"}',
        createdAt: DateTime(2026, 11, 23, 10),
      ),
    );
    final overrides = [...offlineOverrides(userId: 'u1', db: db), networkStatusProvider.overrideWith(_Offline.new)];
    await pumpLocalized(tester, const Scaffold(body: SyncStatusBanner()), overrides: overrides, defaultOffline: false);
    expect(find.textContaining('Luar talian · 1 perubahan'), findsOneWidget);

    await pumpLocalized(tester, const SyncScreen(), overrides: overrides, defaultOffline: false);
    expect(find.text('Mesej: Jumpa esok'), findsOneWidget);
    await tester.tap(find.byTooltip('Buang perubahan'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Buang perubahan'));
    await tester.pumpAndSettle();
    expect(find.text('Semua perubahan sudah disegerakkan.'), findsOneWidget);
    expect(await db.allOps('u1'), isEmpty);
    await db.close();
  });
}

class _Offline extends NetworkStatus {
  @override
  bool build() => false;
}
