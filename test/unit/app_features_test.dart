import 'dart:io';

import 'package:familysync/features/about/app_features.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the About feature list is updated for the version in pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(r'^version:\s*(\d+\.\d+\.\d+)\+', multiLine: true).firstMatch(pubspec)!.group(1)!;
    expect(
      latestFeatureVersion,
      version,
      reason:
          'Add the features of version $version to lib/features/about/app_features.dart '
          '(AppFeature(\'$version\', ...)).',
    );
  });

  test('every feature has both languages and a valid version', () {
    for (final a in appFeatureAreas) {
      expect(a.features, isNotEmpty, reason: a.en);
      for (final f in a.features) {
        expect(f.ms.trim(), isNotEmpty);
        expect(f.en.trim(), isNotEmpty);
        expect(RegExp(r'^\d+\.\d+\.\d+$').hasMatch(f.since), isTrue, reason: f.since);
      }
    }
  });

  test('versions compare numerically', () {
    expect(compareVersions('0.9.10', '0.9.9'), greaterThan(0));
    expect(compareVersions('1.0.0', '0.9.11'), greaterThan(0));
    expect(compareVersions('0.9.8', '0.9.8'), 0);
  });
}
