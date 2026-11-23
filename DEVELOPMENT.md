# Development guide

## Toolchain (verified versions)

| Tool | Version |
|---|---|
| Flutter | 3.50.1 stable (Dart 3.14.0) |
| Android SDK | platform 36, build-tools 36.0.0, platform-tools 37 |
| AGP / Kotlin / Gradle | 9.3.1 / 2.4.20 (built-in Kotlin) / 9.5.0 |
| JDK | 21 |
| Postgres (tests) | `supabase/postgres:17.12.0.002` Docker image |
| Deno (Edge Functions) | 2.9.6 |

### Notes on Flutter 3.50

- `package:flutter/material.dart` is **deprecated** (since 3.47). The app imports
  `package:material_ui/material_ui.dart`, and its `GlobalMaterialLocalizations` (which includes Malay).
  Don't mix in the old library: the two define *different* classes.
- `android/gradle.properties` sets `android.builtInKotlin=true`. With the template's default of
  `false`, `share_plus` 13.3.1 fails to compile under AGP 9.3 (`friendPathsSet` error).

### Dependency policy

Every dependency is pinned exactly in `pubspec.yaml`, and `pubspec.lock` is committed.
`supabase_flutter` is pinned to **2.18.3**, the latest *stable* release. 3.x exists only as
`3.0.0-dev.*` pre-releases, so only v2 APIs are used. The one exception is `Supabase.initialize(publishableKey:)`,
which 2.18.3 already supports (`anonKey` is deprecated there).

## 1. Supabase project

1. Create a project (Region: Singapore `ap-southeast-1` is closest to Malaysia).
2. Apply migrations in order from `supabase/migrations/`. With the Supabase CLI:
   ```bash
   supabase link --project-ref <ref>
   supabase db push
   ```
   Or paste each file into the SQL editor in filename order.
3. **Auth → URL Configuration**: add `familysync://auth-callback` to *Redirect URLs*.
4. **Auth → Providers → Email**: keep *Confirm email* enabled. Set minimum password length 8.
5. Deploy the Edge Function:
   ```bash
   supabase functions deploy delete-account
   ```
   `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are injected by the platform.
   Never put the service-role key anywhere else.
6. Copy the **Project URL** and the **publishable key** (`sb_publishable_…`) from
   *Project Settings → API Keys*.

> Production changes need explicit approval. Use a separate dev project (or Supabase branching)
> for experiments.

## 2. App configuration

```bash
cp env/example.json env/dev.json   # git-ignored
```

```json
{
  "SUPABASE_URL": "https://<ref>.supabase.co",
  "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_...",
  "INVITE_LINK_BASE": "familysync://app/join"
}
```

Run with `flutter run --dart-define-from-file=env/dev.json`. If configuration is missing or a secret
key is supplied, the app shows a *Configuration required* screen instead of starting.

## 3. Tests

```bash
dart run build_runner build --delete-conflicting-outputs   # Drift code (committed; CI checks it)
flutter analyze
flutter test                 # unit + widget (offline tests use in-memory SQLite)
scripts/db_test.sh           # migrations + pgTAP + concurrency tests (Docker)
KEEP_DB=1 scripts/db_test.sh # leave the DB running on localhost:54329 (password: postgres)
scripts/perf_check.sh        # after KEEP_DB=1: seeds a 100-member family, checks query budgets
```

The DB tests run against the official `supabase/postgres` image. The Storage service's tables are not
part of that image, so `supabase/tests/support/00_storage_shim.sql` recreates the minimal
`storage.buckets` / `storage.objects` columns **for local tests only**. It is never applied to a real project.

Edge Function checks (Deno):

```bash
cd supabase/functions && deno check delete-account/index.ts send-push/index.ts && deno lint && deno fmt --check && deno test send-push/
```

## 4. Building APKs

```bash
flutter build apk --debug   --dart-define-from-file=env/dev.json
flutter build apk --release --dart-define-from-file=env/prod.json \
  --obfuscate --split-debug-info=build/symbols/$(grep '^version:' pubspec.yaml | cut -d' ' -f2)
```

Output: `build/app/outputs/flutter-apk/app-{debug,release}.apk`. Release builds obfuscate Dart code;
keep the `build/symbols/<version>` folder (not in git) to decode crash stack traces with
`flutter symbolize`.

### Release signing

1. Create a keystore once and keep it safe; losing it means you can never update the app:
   ```bash
   keytool -genkey -v -keystore ~/familysync-release.jks -keyalg RSA -keysize 4096 \
     -validity 10000 -alias familysync
   ```
2. Create `android/key.properties` (git-ignored):
   ```properties
   storePassword=...
   keyPassword=...
   keyAlias=familysync
   storeFile=/absolute/path/to/familysync-release.jks
   ```
3. Build the release. **Without `key.properties` the release build is signed with the debug key**
   so it can be installed for testing. Do not distribute such a build.

### Versioning

`version: X.Y.Z+N` in `pubspec.yaml` is `versionName+versionCode`. Increase `N` for every build you
distribute.

## 5. Deep links

| Link | Purpose |
|---|---|
| `familysync://app/join?code=XXXX` | invitation (QR codes and share text) |
| `familysync://auth-callback` | Supabase Auth email confirmation / password recovery |

Custom-scheme links are not clickable in some messaging apps. The share text therefore also includes the
code, which can be typed into *Join with a code*. To get clickable `https://` links, host a verified
Android App Link domain and set `INVITE_LINK_BASE` (see docs/STATUS.md).

## 6. Firebase (push notifications)

No `google-services.json` is used. The app reads Firebase's public client identifiers from
`--dart-define` (`FIREBASE_API_KEY`, `FIREBASE_APP_ID`, `FIREBASE_MESSAGING_SENDER_ID`,
`FIREBASE_PROJECT_ID`; see `env/example.json`); push is disabled when they are empty. The FCM service
account is stored only as the Edge Function secret `FCM_SERVICE_ACCOUNT_JSON`. Step-by-step guide:
[docs/FIREBASE_SETUP.md](docs/FIREBASE_SETUP.md).
