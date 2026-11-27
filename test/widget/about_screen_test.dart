import 'package:familysync/features/about/about_screen.dart';
import 'package:familysync/features/about/app_features.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/pump_app.dart';

void main() {
  testWidgets('About shows name, version, what is new and all features', (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'FamilySync',
      packageName: 'app.familysync',
      version: latestFeatureVersion,
      buildNumber: '99',
      buildSignature: '',
    );
    await pumpLocalized(tester, const AboutScreen());
    expect(find.text('FamilySync'), findsOneWidget);
    expect(find.textContaining('$latestFeatureVersion+99'), findsOneWidget);
    expect(find.text('Baharu dalam versi $latestFeatureVersion'), findsOneWidget);
    expect(find.text('Menu Tentang: versi dan senarai semua fungsi'), findsWidgets);

    await tester.scrollUntilVisible(find.text('Kutipan'), 200);
    await tester.tap(find.text('Kutipan'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Kutipan duit dengan tujuan'), findsOneWidget);
    expect(find.text('v0.9.8'), findsWidgets);
  });
}
