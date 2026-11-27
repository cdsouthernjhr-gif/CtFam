# FamilySync — working notes

## Every release
1. Bump `version:` in `pubspec.yaml` (x.y.z+build).
2. Add a CHANGELOG.md entry.
3. **Add each new or changed feature to `lib/features/about/app_features.dart`**
   (`AppFeature('<x.y.z>', '<Bahasa Melayu>', '<English>')`) in the right area. The About screen
   (Profile → Tentang FamilySync) shows them, and `test/unit/app_features_test.dart` fails until the
   newest listed version equals the pubspec version.
4. Run format, `flutter analyze`, `flutter test`, DB tests (`scripts/db_test.sh`) when SQL changed,
   then build the APK.
5. Database migrations go to the hosted project only after the owner approves.

## Conventions
- Reply to the owner in Malay.
- Never put service-role keys or other secrets in the app; never disable RLS.
