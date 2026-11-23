# FamilySync

Private family communication, real-time chat and shared task management, built as an
Android app with **Flutter** on a **Supabase** backend.

- **Platform:** Android only
- **Languages:** Bahasa Melayu (primary), English
- **Target:** private family groups of 20–100+ members

> **Status: Phases 1–5 (foundation, real-time To-Do, chat, notifications, calendar) complete and deployed. Phases 6–8 not started.**
> Push delivery needs the owner's Firebase project (see [docs/FIREBASE_SETUP.md](docs/FIREBASE_SETUP.md)).
> Authentication, profiles, families, roles, secure invitations and shared real-time To-Do lists work end to
> end against the database, along with private and group chat, notifications and the family calendar. Offline mode
> is **not implemented yet**. See [docs/STATUS.md](docs/STATUS.md).

## What works today (Phase 1)

| Area | Implemented |
|---|---|
| Auth | Email sign-up with confirmation, sign-in, forgot/reset password via deep link, sign out, sign out of all devices, persistent session (PKCE) |
| Profile | Display name, phone, bio, profile photo (private bucket and signed URLs), language (BM/EN), theme (system/light/dark) |
| Account deletion | Edge Function `delete-account` (blocked while you still own a family that has other members) |
| Families | Create, edit name/description/photo, approval and invite settings, leave, soft-delete (owner, typed confirmation), switch between families |
| Roles | Owner / Admin / Moderator / Member, enforced server-side; promote, demote, suspend, reactivate, remove, transfer ownership |
| Invitations | 80-bit random codes (only a hash is stored), share link + QR code, expiry, usage limits, single-use or multi-use, revoke, history, optional admin approval, brute-force limiting, race-safe redemption |
| Activity | Family activity feed (member-visible) plus an admin audit trail |
| Realtime | Member list and family details update live through the `family:{id}` channel |
| To-Do (Phase 2) | Shared lists (family-wide or members-only), tasks with priority, due date, recurrence, assignees and comments; live sync across devices; optimistic UI with rollback; revision conflict detection; filters by status, member and search; progress; activity history |
| Chat (Phase 3) | Private and group chat; reply, edit, delete, pin; image and document attachments; Sending/Sent/Delivered/Read/Failed with retry; typing indicator; online status; unread counts; mute; message search; group admin tools |
| Notifications (Phase 4) | In-app inbox with bell and badge; FCM push through a DB queue and Edge Function; per-type preferences; lock-screen privacy by default; quiet hours; mute; announcements; dedupe; tap navigation |
| Calendar (Phase 5) | Month grid and agenda; all-day and timed events; daily/weekly/monthly/yearly repeat with end date and per-occurrence cancel; invitees and RSVP; personal reminders via push; participants-only events; live updates |
| Dashboard | Family header, member overview, today's/overdue/my tasks, upcoming events, recent messages, recent activity, quick invite |

## Repository layout

```
lib/                    Flutter app (feature-first clean architecture)
  core/                 config, errors, router, theme, utils, shared widgets
  shared/providers/     Supabase client + session state
  features/<feature>/   data / domain / presentation per feature
  l10n/                 ARB files (app_ms.arb is the template)
supabase/
  migrations/           versioned SQL (schema, RLS, RPCs, storage, realtime)
  functions/            Deno Edge Functions
  tests/                pgTAP RLS tests, concurrency tests, local shims
test/                   unit + widget tests
scripts/db_test.sh      runs every migration and DB test in Docker
docs/STATUS.md          environment audit, roadmap and status report
```

## Quick start

See **[DEVELOPMENT.md](DEVELOPMENT.md)** for full setup, covering the Supabase project, Auth redirect URLs,
Edge Function deployment and APK signing.

```bash
cp env/example.json env/dev.json        # fill in URL + publishable key
flutter pub get
flutter run --dart-define-from-file=env/dev.json
```

Checks:

```bash
dart format --line-length 120 $(find lib test -name '*.dart' -not -path '*/generated/*')
flutter analyze
flutter test
scripts/db_test.sh                       # needs Docker
```

## Documentation

- [DEVELOPMENT.md](DEVELOPMENT.md): setup, configuration, build, signing
- [DATABASE.md](DATABASE.md): schema, RPCs, realtime channels
- [SECURITY.md](SECURITY.md): threat model, RLS rules, secrets handling
- [CHANGELOG.md](CHANGELOG.md)
- [docs/STATUS.md](docs/STATUS.md): audit, roadmap, test and build results, known limitations
