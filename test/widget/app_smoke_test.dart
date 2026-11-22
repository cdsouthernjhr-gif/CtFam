import 'package:familysync/app.dart';
import 'package:familysync/shared/providers/session_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a build without Supabase configuration shows the config screen', (tester) async {
    await tester.pumpWidget(
      ProviderScope(overrides: [supabaseConfiguredProvider.overrideWithValue(false)], child: const FamilySyncApp()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Konfigurasi diperlukan'), findsOneWidget);
  });
}
