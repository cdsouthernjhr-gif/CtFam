# FamilySync: environment audit, roadmap and status report

_Last updated: 2026-11-22 (end of Phase 1)_

## 1. Phase 0: environment audit

| Item | Finding | Action taken |
|---|---|---|
| Working directory | Empty git repo (`cdsouthernjhr-gif/ctfam`), no existing project | New project created; nothing overwritten |
| Flutter / Dart | Not installed | Installed Flutter **3.50.1** stable (Dart **3.14.0**) |
| Android SDK | Not installed; `dl.google.com` blocked by network policy | Network allowance approved; installed cmdline-tools, platform 36, build-tools 36.0.0, platform-tools; NDK/CMake auto-installed by Gradle |
| JDK / Gradle | OpenJDK 21, Gradle wrapper 9.5.0, AGP 9.3.1 | OK |
| Git | Available; branch `ccr-04f99347-vg9i4z` | Used |
| Supabase CLI | Not installed; GitHub release downloads return 403 | **Not available.** Migrations are tested with the official `supabase/postgres:17.12.0.002` image in Docker instead |
| Supabase MCP | Connected. Account has 2 unrelated projects (`smartstock`, `Library`) and **no FamilySync project** | Nothing touched. No remote changes made |
| Firebase CLI / FlutterFire CLI | Not installed; no Firebase project or config | Deferred to Phase 4 (needs owner's Firebase project) |
| Docker | Available | Used for DB tests |
| Deno | Not installed | Installed 2.9.6 via npm for Edge Function checks |
| Android device / emulator | No device; no KVM, so the emulator is not viable | **The app has not been run on a device.** See §6 |
| Package versions | `supabase_flutter` latest stable **2.18.3**; v3 only as `3.0.0-dev.18` | Pinned 2.18.3; v2 API only (see DEVELOPMENT.md) |
| Flutter 3.50 change | `package:flutter/material.dart` deprecated in favour of `material_ui` | App uses `material_ui` consistently |

## 2. Credentials and configuration the project owner must supply

| Needed for | What | Where it goes |
|---|---|---|
| Running the app against a backend | A Supabase project (recommend a **new** project, e.g. "familysync", region `ap-southeast-1`), its URL and **publishable** key | `env/dev.json` (git-ignored). Applying migrations to it needs your approval |
| Auth emails | Redirect URL `familysync://auth-callback`; optionally custom SMTP (Supabase's default sender is rate-limited) | Supabase dashboard |
| Account deletion | Deploy `delete-account` Edge Function | `supabase functions deploy` |
| Push notifications (Phase 4) | Firebase project; `google-services.json` for `com.familysync.app`; FCM service account | `flutterfire configure`; service account **only** as an Edge Function secret |
| Release distribution | Upload keystore + passwords | `android/key.properties` (git-ignored) |
| Clickable https invite links (optional) | A domain with `assetlinks.json` | `INVITE_LINK_BASE` + intent filter |

Never paste service-role keys, keystore passwords or service-account JSON into chat or commit them.

## 3. Roadmap

| Phase | Scope | Status |
|---|---|---|
| 0 | Environment audit | **Done** |
| 1 | Flutter project, auth, profiles, families, roles, invitations, migrations, RLS | **Done** (not yet run against a hosted project or on a device) |
| 2 | Realtime To-Do: lists, items with `revision` + idempotent `set_todo_item_state` RPC, assignments, comments, activity, categories, filters, recurring tasks, `todo:{list_id}` channel, optimistic UI with rollback | Not started |
| 3 | Chat: race-safe direct conversations (unique pair per family), groups, messages with client UUIDs (idempotent send), receipts, Broadcast typing, Presence online status, attachments in private bucket, pagination, search, pin, mute | Not started |
| 4 | FCM: token registration (table + RPC already exist), `notification_queue`, Edge Function sender, preferences, lock-screen privacy, tap navigation, dedupe | Not started |
| 5 | Calendar: events, participants, reminders, recurrence (RRULE), month/week/day views | Not started |
| 6 | Offline: Drift (SQLite) cache, pending-operations queue with UUID op IDs, retry/backoff, conflict detection by revision, sync status UI | Not started |
| 7 | Security and performance: full RLS audit with Supabase advisors, rate-limit pruning job, index review, multi-device tests (3+ accounts) | Not started |
| 8 | Release: signed release APK, device install testing, final docs | Release config ready; signing key needed |

## 4. Module status

| Module | Status | Notes |
|---|---|---|
| A. Authentication | **Complete in code, verified by tests** | Live email flows still need a hosted project to verify |
| B. Family management | **Complete in code, verified by tests** | |
| C. Invitations | **Complete in code, verified by tests** | Includes race test (20 sessions → 1 join) |
| D. Private chat | Not implemented | Tab shows "coming soon" |
| E. Group chat | Not implemented | |
| F. Shared To-Do | Not implemented | |
| G. Calendar | Not implemented | |
| H. Notifications | Partial: `device_tokens` + `register_device_token` RPC + preference columns only | No Firebase integration |
| I. Offline | Not implemented | Network errors show a retry state |
| Dashboard | Partial | Tasks, messages and events sections await their modules |

## 5. Test results (2026-11-22)

| Suite | Command | Result |
|---|---|---|
| Format | `dart format --line-length 120 $(find lib test -name '*.dart' -not -path '*/generated/*')` | clean |
| Static analysis | `flutter analyze` (strict casts and raw types) | **No issues** |
| Flutter unit + widget | `flutter test` | **39 passed**, 0 failed |
| Database RLS / RPC | `scripts/db_test.sh` (pgTAP) | **79 assertions passed** |
| Concurrency | `single_use_invite_race.sh` | **joined=1, exhausted=19** of 20 racers |
| Edge Function | `deno check`, `deno lint`, `deno fmt --check` | pass |

What the DB tests cover: anon lockout; automatic profile creation; family creation; cross-family isolation
(families, members, profiles, activity, storage); self-promotion and direct-write attempts; role hierarchy
(owner/admin/moderator/member); invitation hashing, case-insensitive redemption, single-use, expiry,
revocation, approval flow, suspension, brute-force lockout; storage folder policies and private buckets;
device-token ownership; ownership transfer, leave and delete rules; RLS enabled on every table; every
SECURITY DEFINER function pins `search_path`.

**Not yet tested:** real Supabase Auth email delivery, deep links on a device, Realtime against a live
server, image upload against real Storage, the Edge Function against a deployed project, and multi-device
behaviour. All of these need the owner's Supabase project and a physical Android device.

## 6. Build results

| Build | Result |
|---|---|
| `flutter build apk --debug` | **Success**: `build/app/outputs/flutter-apk/app-debug.apk` (manifest verified: `com.familysync.app`, minSdk 24, targetSdk 36, INTERNET, both deep links, backup/cleartext disabled) |
| `flutter build apk --release` | **Success**: `build/app/outputs/flutter-apk/app-release.apk` (58.3 MB). Signed with the **debug key** because no release keystore exists yet, so it is for testing only and must not be distributed |

APK files are build outputs and are **not committed** to git. Rebuild with the commands in DEVELOPMENT.md.
The builds above contain no Supabase configuration, so they open on the *Configuration required* screen.
Build with `--dart-define-from-file=env/dev.json` to get a working app.

The app has **not** been installed or launched on an Android device or emulator (none available in the
build environment).

## 7. Security findings

- No secrets in the repository; `.gitignore` covers env files, keystores and `key.properties`.
- The app refuses secret and service-role keys at startup.
- See SECURITY.md for the full model. Open items: verify storage policies against a real project (the local
  shim mirrors only the columns used); add pruning for `private.rate_limit_events` and
  `private.invitation_attempts`; run Supabase security advisors once a project exists.

## 8. Known limitations

- Custom-scheme invite links (`familysync://…`) are not clickable in every messaging app; the code is also
  included in the share text.
- No offline cache yet: the app needs connectivity (Phase 6).
- Dashboard sections for tasks, messages and events are placeholders until Phases 2, 3 and 5.
- Release builds without `android/key.properties` are signed with the debug key and must not be distributed.
- Hand-written Dart models (no code generation); `select` strings are kept next to the models.
