# Changelog

## [0.9.9] - 2026-11-27: New icon for Collections

### Changed
- Collections use a "giving hand" icon (instead of the piggy bank) on the Family tab, the Collections
  screens and in notifications.

## [0.9.8] - 2026-11-27: Money collections (Kutipan)

### Added
- **Collections** (Family tab → savings icon): each with a title and a purpose, an optional due date and
  optional sharing with linked families. Target types: one total, per member (pay in instalments), or
  no target.
- Members record their own payments ("I have paid", optional receipt photo); a treasurer confirms or
  rejects them (with a reason) and only confirmed payments count. Payments recorded by a treasurer are
  confirmed at once. Treasurers: the creator, the extra treasurers they pick, and the family
  owner/admins.
- Treasurers record expenses (with receipts); the page shows collected, pending, spent and balance,
  progress to the target (and how much above it), a per-member table, and every payment with its
  status. Everyone who can see a collection sees all amounts. Treasurers can send a reminder (once a
  day) to whoever still owes, and close or reopen a collection.
- Notifications for new collections, payments to confirm, confirmations/rejections and reminders.
- The app only records money; it does not move it.

### Database
- Migration `20261127000200_collections` (applied to the hosted project with approval): tables
  `collections`, `collection_treasurers`, `collection_targets`, `collection_payments`,
  `collection_expenses` (read-only under RLS, writes through RPCs), private bucket
  `collection-receipts`, notification type `collection`, RPCs `upsert_collection`,
  `set_collection_status`, `delete_collection`, `record_collection_payment`,
  `review_collection_payment`, `delete_collection_payment`, `record_collection_expense`,
  `delete_collection_expense`, `remind_collection`, `collection_summaries`. pgTAP: `16_collections`
  (56 assertions).

## [0.9.7] - 2026-11-27: Before/after photos in To-Do; list cover photos

### Added
- To-Do items: optional **Before** and **After** photos (up to 4 each, camera or gallery). Tap for full
  screen with zoom and delete; **Compare** shows before and after together. Items with photos show a
  photo count. Photos can be added once the task is saved and need a connection.
- To-Do lists: optional cover photo (list creator or family owner/admin, menu ⋮ → Cover photo), shown
  above the list and on the list card.

### Database
- Migration `20261127000100_todo_photos` (applied to the hosted project with approval): private bucket
  `todo-photos` with list-aware storage policies (private lists stay private), table
  `todo_item_photos` (RPC-only writes, limit enforced on the server), `todo_lists.cover_path`, RPCs
  `add_todo_item_photo`, `delete_todo_item_photo`, `set_todo_list_cover`; `todo_list_summaries` returns
  the cover. pgTAP: `15_todo_photos` (31 assertions).

## [0.9.6] - 2026-11-27: Spinning 3D photo card in the family tree

### Added
- Family tree: tap a person's photo (the circle on the card) to open their photo on a card that turns
  in 3D (the back shows the name and years). Tap the card: it slows down, stops facing you and shows the
  details: age, relationship to you, birthday and countdown, parents, spouses, children, and
  **Open full profile**. Tap again to spin again; ✕ closes. People without a photo get a card with
  their initials. With the system "remove animations" setting on, it does not spin and the details
  show at once. Tapping the rest of the card still opens the person page.

## [0.9.5] - 2026-11-24: Print-ready family tree PDF; all descendants on the person page

### Added
- **Print the family tree (A4)**: the PDF button now asks what to print, then shows a print preview
  with **Print** and **Share** buttons.
  - Scope: the whole tree, one branch (pick the person), or each child's branch in its own section.
  - Generations: all, 2, 3 or 4 (counting the top row).
  - Style: **Chart** or **List** (an indented outline, portrait, flows over as many pages as needed).
  - Photos on or off.
- Chart printing: compact print cards (names at 8.5 pt). If the chart fits one landscape A4 page at
  70 % or more it is printed on one page; otherwise it is printed at full size over several pages,
  cut only in the gaps between cards (never through a card). Page 1 is then a page map: a small map with
  labelled pages (A1, A2, B1…) and an index of page numbers with the first names on each page. Lines
  cut at the page edge say "continues on page N". Empty pages are skipped.
- Fonts: Noto Sans + Noto Naskh Arabic are bundled (SIL OFL), so names with accents and Jawi names print
  correctly. Chinese, Japanese and Korean script is not supported yet (shown as boxes).
- Person page: descendants are no longer limited to children. Grandchildren, great-grandchildren,
  great-great-grandchildren and further generations are listed, grouped by generation.

## [0.9.4] - 2026-11-24: Blinking birthday reminders on the dashboard

### Added
- "Upcoming birthdays": birthdays 7 days away or closer pulse (soft highlight behind the row, cake icon
  grows and brightens; faster on the day) and show a countdown: "Hari ini 🎂", "Esok 🎉", "3 hari lagi".
  Birthdays 8–30 days away stay plain. With the system "remove animations" setting on, the row is
  highlighted without animating.

## [0.9.3] - 2026-11-24: Create or join another family from the app

### Fixed
- Creating a second family was only possible from the first-run screen; once in a family there was no
  menu for it. The Family tab's ⇄ menu ("My families") is now always shown and lists your families plus
  **Create a new family** and **Join with a code**. A new family becomes the active one, with you as owner.

## [0.9.2] - 2026-11-24: Family tree layout follows relationships

### Fixed
- **Spouse placed far from their partner, lines crossing** (reported by the owner): rows were sorted by
  birth date, so an in-married spouse older than the siblings was put before the eldest sibling. The chart
  now uses a relationship-based ("tidy tree") layout: a person and their in-married spouse(s) are one unit
  and always side by side; children are laid out under their parents in birth order and the couple is
  centred over them; separate trees (e.g. in-laws) sit side by side. Age only orders siblings.
- Children of a married couple get **one** connector from the middle of the couple (instead of one from
  each parent), so lines no longer cross.
- PDF: initials in the avatar circles were invisible (PDF ignores the fill's alpha); now a light tint.
- Verified by rendering the owner's scenario (older husband of the youngest sibling) to PDF/PNG.

## [0.9.1] - 2026-11-24: Family tree chart editing, PDF, zoom

### Added
- **Edit from the chart:** owner/admin long-press a card for View, Edit, Add parent / child / spouse and
  Remove from tree (editing and removal only for people of a family they administer). Relations can be
  removed from the person page (✕ on the chip) by an owner/admin of either family; both people stay.
- **Download PDF:** the whole chart (same layout, photos, years, adoptive and spouse lines) as a PDF,
  opened in the share sheet to save to Files/Drive, print or send. Page sized to the tree; names outside
  Latin-1 are replaced so the built-in font can render them.
- **Zoom:** pinch (0.2×–3×), + / − / fit-to-screen buttons, double-tap to zoom in or back to fit; the chart
  opens fitted to the screen width.

### Fixed (found by the new tests)
- Zoom level was read with `getMaxScaleOnAxis()`, which includes the z axis (always 1), so zooming out
  below 100% was miscalculated.
- The long-press menu overflowed on small screens; it now scrolls.

## [0.9.0] - 2026-11-24: Linked families (rumpun)

Owner decisions: owner/admin approve links (1b); everyone in the clan sees the whole tree incl. birth dates
(2a); cross-family relations need an admin of both families (3a); birthday push only within one's own
families (4a); no depth limit (cycles refused; technical guard 50 levels).

### Added
- **Parent and branch families** (`20261124000500_family_links.sql`): a family can be a branch of one
  parent; any number of branches, any depth. Requested by an owner/admin of one family who belongs to the
  other; approved by an owner/admin of the other (both sides consent); either side can unlink. A link
  shares nothing private: members, chats, tasks, activity stay within each family. "Linked families"
  screen with the clan outline, requests, approve/decline/withdraw, unlink.
- **Shared clan tree** (`20261124000600_clan_tree.sql`): people and relations visible across the clan;
  each person keeps a home family that alone edits the record; cross-family relations need both
  families' admins; duplicate records (same gender and birth date) are suggested and merged (across
  families after the other admin approves); relationships are computed across the clan (e.g. cousins in
  different branch families); birthday notices go to the person's home family and every family of their
  account.
- **Clan events and combined calendar** (`20261124000700_clan_events.sql`): events can be shared with
  the whole clan (RSVP and reminders for members of linked families, editing only by the organiser's
  family); "All my families" calendar view with family labels. Notifications widen to the clan for
  events only; chats/tasks still require membership of the family itself.
- **Tests:** `12_family_links` (28), `13_clan_tree` (29), `14_clan_events` (14) pgTAP assertions
  including no-leak checks; API contract now 25 selects / 60 RPCs; 129 Flutter tests.

## [0.8.2] - 2026-11-24: Chat conversation stuck on loading (fixed)

### Fixed
- **Opening a conversation never finished loading.** The members query embedded `profiles` from
  `conversation_members`, which has two foreign keys to `profiles` (`user_id`, `added_by`); PostgREST
  rejected it as ambiguous (HTTP 300, PGRST201). The same problem affected event participants in the
  calendar. Both now name the foreign key (`profiles!…_user_id_fkey`). The unit/widget tests used mocked
  repositories and pgTAP tests SQL directly, so neither could see it.
- Failed screens no longer spin for ~40 s: Riverpod's automatic retry now applies only to network errors
  (3 tries: 0.5 s, 1 s, 2 s); other errors show at once with "Try again".

### Added
- `scripts/api_contract.sh` (in CI): extracts every `select` (23) and RPC call with its parameter names
  (52) from the app source and runs them through a real PostgREST as a signed-in member. Verified to fail on
  the old chat query.

## [0.8.1] - 2026-11-24: Family tree photos

### Added
- Photo for every person in the tree and a cover photo for the whole tree: gallery or camera, change,
  remove. Private bucket `tree-photos` (5 MB, JPEG/PNG/WebP), paths `{family}/{person}/…` and
  `{family}/cover/…` (`20261124000400_tree_photos.sql`).
- Who: family members see all photos; owner/admin change or remove any photo and the cover; a member only
  the photo of their own record. Paths are set through `set_person_photo` / `set_tree_photo`, which check
  the file exists in the right folder; replaced or removed files are deleted from storage; removing a person
  removes their photo.
- Tree cards show the photo; person page has a photo with a camera badge for those allowed to edit.
- Tests: `11_tree_photos` (22 assertions: own folder only, no cover for members, nested paths refused,
  file must exist and be in the person's folder, outsiders see nothing, delete rights), widget tests.

## [0.8.0] - 2026-11-24: Family tree (salasilah) and birthdays

### Added
- **Family tree** (`20261124000300_family_tree.sql`): `family_persons` (optionally linked to an account;
  people without an account and deceased relatives supported; birth date required) and
  `family_relations` (only parent→child, biological or adoptive, and spouse links are stored).
- **Computed relationships** (`relationship_between`): closest common ancestor gives (up, down), named in
  Malay and English: abang/kakak/adik (from birth dates; seibu/sebapa for half-siblings), anak saudara,
  cucu saudara, bapa/ibu saudara, sepupu (dua/tiga pupu), datuk, moyang, anak angkat, and by marriage:
  suami/isteri, mertua, ipar, menantu, anak/ibu/bapa tiri, biras, besan. The person explaining the link is
  returned ("anak saudara anda · anak kepada Hasan").
- **Permissions:** owner/admin add and edit anyone, link a person to a member account, and confirm
  relations; members create/edit only their own record and propose relations, which stay pending (and
  unused) until an admin confirms. Validation: no cycles, one biological father and mother, parents born
  before children, no spouse links between ancestor and descendant.
- **Birthdays:** daily notification (08:05 Malaysia time) to the family and a greeting to the person;
  29 February birthdays on 28 February in common years; deceased skipped; dashboard "Upcoming birthdays".
- **App:** zoomable generational tree, person page with the relationship to you, parents/spouse/siblings/
  children, add/propose relation, pending proposals for admins, own-record prompt, account linking.
- **Tests:** 52 pgTAP assertions (`09_family_tree`), tree layout/birthday unit tests and widget tests
  (121 Flutter tests).

### Security
- Fixed (found by the new tests): `delete_todo_item` and `delete_message` let any member delete a task or
  message whose creator had deleted their account (NULL owner column made the permission check pass).
  `20261124000250_null_safe_permissions.sql`, regression test `10_null_safety`.

## [0.7.1] - 2026-11-24: Email delivery fixed

### Deployed
- Custom SMTP switched to Brevo by the owner. Brevo initially rejected Supabase with
  `525 5.7.1 Unauthorized IP address` (Authorized IPs blocking); fixed in Brevo. Recovery email received.
- **Email confirmation turned back on** (`mailer_autoconfirm = false`): new accounts must confirm their
  address with the code before signing in.

## [0.7.0] - 2026-11-24: Phase 7, security and performance review

### Performance
- Measured at family scale (`scripts/perf_check.sh`: 100 members, 25k messages, 2k tasks, 500 events,
  20k notifications) through RLS as a signed-in member. Read policies called a membership function per
  row; they now compare against the set of readable ids computed once per statement
  (`20261124000200_performance.sql`), with identical rules:
  chat list 2,920 → 18 ms, message search 3,544 → 63 ms (plus a trigram index), To-Do overview
  286 → 3 ms, list of 400 tasks 108 → 3 ms, calendar month 53 → 10 ms. Unread counts stop at 100 ("99+").
- Every measured query is within budget; CI fails if a budget is exceeded.

### Security
- Catalog-wide audit test (`08_security_audit`, 18 assertions): RLS on every table, nothing granted to
  `anon`, the callable RPC set equals a reviewed allow-list, push RPCs service-role only, definer
  functions use an empty `search_path` and are not executable by PUBLIC, no unconditional write policy,
  private buckets, Realtime tables protected by RLS, no secret-looking columns, invite codes hashed.
- `20261124000100_hardening.sql`: trigger functions no longer executable by PUBLIC; new functions are not
  executable by default.
- Release APK built with Dart obfuscation; push error logging limited to debug builds; APK scanned for
  secrets (none).
- Hosted re-check: 0 tables without RLS, 0 anon grants/functions, 0 public buckets.

### Known (owner action)
- Leaked-password protection needs a paid Supabase plan. (Email confirmation: fixed in 0.7.1.)

## [0.6.0] - 2026-11-23: Phase 6, offline mode

### Added
- **On-device database** (Drift/SQLite, `lib/core/offline/`): `cache_entries` (last server responses as raw
  JSON, per user) and `outbox_ops` (queued writes, replayed strictly in insertion order).
- **Offline reading:** network-first with fallback to the stored copy for memberships, family, members,
  activity, profile, To-Do lists/items/summaries, chat list, latest messages and receipts, calendar
  occurrences/events/reminders, notification inbox and unread count. Non-network errors are never hidden
  by the cache. The app can start without a connection when it has been used before.
- **Offline writes** (outbox): To-Do create/edit/complete/reopen/delete, text messages, event RSVP. The UI
  stays optimistic (no rollback on network loss); queued changes are re-applied after restarts; later
  writes to the same item queue behind earlier ones; chained offline edits drop the stale revision while a
  queued edit based on an old server revision still fails with a conflict.
- **Sync engine:** replays when connectivity returns, on app resume, every 20 s while work is queued, and
  right after queueing. Network errors stop the replay (order kept); rejected ops (conflict, lost access)
  are marked failed and shown for retry/discard.
- **UI:** status strip above the navigation bar (offline, syncing, failed), Sync screen (`/sync`) with
  "Sync now", per-change discard; sign-out warns when changes are unsynced.
- **Privacy:** local data is per user; other accounts' data is removed at sign-in; everything is wiped
  before sign-out and account deletion (after one last sync attempt).
- **Tests:** offline store, sync engine ordering/failure handling, queued To-Do overlay, offline To-Do and
  chat flows across a reload, sync UI (111 Flutter tests); `07_offline_replay` pgTAP (11 assertions) proves
  every replayed RPC is idempotent and stale queued edits are rejected.

### Fixed
- Network errors raised by `package:http` (`ClientException`, TLS, dropped connections) are now
  recognised as "no connection".

## [0.5.0] - 2026-11-23: Phase 5, family calendar

### Added
- **Database** (`20261123000500_calendar.sql`): `family_events`, `event_participants` (RSVP), `event_reminders`
  (per participant) with RLS. Visibility `family` or `participants` (creator, participants, owner/admin).
- **Recurrence** daily/weekly/monthly/yearly, optional end date, expanded on the server in the event's time
  zone from the first occurrence (no drift, DST-correct, Jan 31 monthly gives Feb 28). Single occurrences
  can be cancelled.
- **RPCs:** `upsert_family_event` (idempotent create, race-safe; `revision_conflict` on stale edits),
  `delete_family_event`, `cancel_event_occurrence`, `set_event_rsvp`, `set_event_reminders`,
  `calendar_occurrences` (SECURITY INVOKER, max 400 days).
- **Notifications:** invitation, change of time/place/title, cancellation (participants who did not
  decline), and **reminders** every minute via pg_cron (`familysync-event-reminders`) through the Phase 4
  pipeline (preferences, quiet hours, dedupe per occurrence and reminder, push).
- **App:** month grid with event dots, day list, agenda (60 days), event form (all-day, start/end, location,
  notes, category, repeat, end date, reminders, invitees, participants-only), event detail (RSVP, my
  reminders, participants, map link, edit/delete, cancel one occurrence), live updates (`calendar:{family}`),
  upcoming events on the dashboard, notification taps open the event, activity feed entries.
- **Tests:** 65 pgTAP assertions, calendar race test (same id ×10 gives 1 event and 0 errors; 11 concurrent
  RSVPs; 3 overlapping reminder runs give each reminder once), 98 Flutter tests.

## [0.4.1] - 2026-11-23: Firebase client configured

### Changed
- Release build now carries the owner's Firebase client identifiers (project `familysync-c3dbf`), so the
  app registers for push. Delivery starts once `FCM_SERVICE_ACCOUNT_JSON` is set as an Edge Function
  secret.

## [0.4.0] - 2026-11-23: Phase 4, notifications

### Added
- **Database** (`20261123000300_notifications.sql`): `notifications` (in-app inbox, RLS own rows) and
  `notification_queue` (service role only). `private.notify()` applies preference toggles, conversation
  mute, quiet hours (recipient time zone, inbox only), lock-screen privacy (content only with
  `show_message_preview`), recipient language (ms/en), active-family check and dedupe
  (`UNIQUE(user_id, dedupe_key)`).
- **Triggers:** new private/group message, task created/assigned/completed, join request (admins),
  member joined (admins). `post_announcement` RPC for owners/admins sends to every member.
- **Dispatch** (`20261123000400_push_dispatch.sql`): pg_net kick on new queue rows, pg_cron every minute
  for retries; webhook secret in Supabase Vault and verified in the database (`verify_push_secret`,
  service role only); daily housekeeping (rate-limit events, invitation attempts, old queue rows, old read
  notifications).
- **Edge Function `send-push`:** FCM HTTP v1 with a service-account OAuth token (RS256 via WebCrypto),
  claim with `FOR UPDATE SKIP LOCKED`, Android channels, collapse tags, `PRIVATE` visibility,
  unregistered-token cleanup, exponential backoff (5 attempts).
- **App:** Firebase from public `--dart-define` values (no google-services.json), notification
  permission, token registration/refresh, token removal before sign-out and account deletion,
  foreground display (deduplicated; suppressed for the open conversation), tap navigation through a
  route allow-list, Android channels and monochrome status icon, in-app inbox with bell and unread badge,
  notification settings (types, preview, quiet hours), announcement composer.
- **Docs:** `docs/FIREBASE_SETUP.md`.
- **Tests:** 44 pgTAP assertions; pg_net dispatch integration test (real HTTP call with the Vault
  secret); 6 Deno tests (message, JWT signature, OAuth grant, error mapping, partial delivery); 86 Flutter
  tests.

### Changed
- `compileSdk` 37 (required by flutter_local_notifications 23 / androidx.core 1.19); `targetSdk` unchanged.

## [0.3.0] - 2026-11-23: Phase 3, private and group chat

### Added
- **Database** (`20261123000200_chat.sql`): conversations, conversation_members, messages,
  message_attachments, message_receipts with RLS. Access requires active membership of both the family
  and the conversation.
- **Direct chats** are unique per user pair (`direct_key` UNIQUE): concurrent "start chat" taps give
  one conversation.
- **Idempotent `send_message`** with client UUIDs; a message counts as sent only after the server stores it.
  Validates replies, body length (4000), attachments (must already be uploaded under
  `chat-attachments/{conversation}/{message}/`, allowed MIME types, 10 MB) and rate limit (60/min).
- Edit own messages; delete own (moderators: any) with soft delete. Deleting removes attachment
  rows, which also revokes Storage read access. Pin (direct: either participant; group: moderators).
- **Receipts:** per-member delivered/read cursors (monotonic). Unread counts in
  `conversation_summaries`; group "read by N".
- **Groups:** create (idempotent), rename/describe, add/remove members, admin role, leave (an admin
  always remains), system messages for group events.
- **Realtime:** private channel `conversation:{id}` (Postgres Changes for messages, receipts and
  members, plus Broadcast typing), `chats:{family}` for the list, Presence `presence:family:{id}` for
  online status. Joining and sending are authorised by RLS policies on `realtime.messages`.
- **App:** chat list with unread badges, online dot, mute and pin markers and message search; new private
  chat or group sheet; conversation screen with pagination, date separators, reply, edit, delete, pin,
  copy, image/camera/document attachments, Sending/Sent/Delivered/Read/Failed (tap to retry), typing
  indicator and pinned banner; group info screen; unread badge on the Chat tab; recent messages on the
  dashboard.
- **Tests:** 76 pgTAP assertions, chat race test (direct chat ×10 concurrent gives 1; same message id ×10
  concurrent gives 1; 12 members posting at once gives 12/12), 79 Flutter tests.

## [0.2.0] - 2026-11-23: Phase 2, real-time shared To-Do

### Added
- **Database** (`20261123000100_todo.sql`): todo_categories, todo_lists, todo_list_members, todo_items,
  todo_assignments, todo_comments, todo_activity_logs, all with RLS. Lists are family-wide or members-only.
- **RPCs:** create/update/delete list (idempotent create, revision-checked update),
  `upsert_todo_item` (idempotent create with a client UUID, `revision_conflict` on stale edits),
  `set_todo_item_status` (idempotent set, never a blind toggle; recurring items spawn the next occurrence
  exactly once), `delete_todo_item`, `set_todo_list_members`, `todo_list_summaries`.
- **Realtime:** `todo:{list_id}` per open list and `todo-family:{family_id}` for the overview. Read access
  includes soft-deleted rows so deletions are delivered; the client filters them out.
- **App:** lists overview with category filter and progress, list screen with quick add, status, member
  and search filters, progress bar, completed section, item sheet (priority, due date and time, recurrence,
  assignees, comments), list activity history, rename and delete, live "syncing" state.
- **Optimistic UI with rollback**, revision-based merge (stale or duplicate Realtime events ignored),
  conflict reload, and a full refetch after reconnect.
- **Dashboard:** today's, overdue, my and open task counters plus the next tasks due.
- **Tests:** 63 pgTAP assertions; a concurrency test (12 sessions: 1 edit wins and 11 get conflicts; a
  recurring item completed concurrently creates exactly 1 next occurrence); 65 Flutter tests.

## [0.1.6] - 2026-11-22: Correct error for server-side email failures

### Fixed
- HTTP 5xx responses from Supabase Auth were shown as "Tiada sambungan internet". gotrue raises
  `AuthRetryableFetchException` for both real network failures (no status code) and 5xx responses.
  These are now separated: a 5xx shows "Pelayan menghadapi masalah…", and a failed email send shows
  "Pelayan tidak dapat menghantar e-mel… semak tetapan SMTP".

### Known
- Auth logs (12:33–12:34 UTC) still show Gmail rejecting the SMTP password (`535 5.7.8 BadCredentials`)
  after the username fix. The SMTP password must be a valid 16-character Gmail App Password.

## [0.1.5] - 2026-11-22: Email delivery fixes

### Fixed
- Signing up with an already-registered email now shows "E-mel ini sudah didaftarkan…" instead of
  waiting for a code. Supabase sends no email in that case (`user_repeated_signup`); it is detected from
  the empty `identities` list.
- Project SMTP username set to the full Gmail address. Auth logs showed Gmail rejecting the login
  (`535 5.7.8 BadCredentials`).

## [0.1.4] - 2026-11-22: Branded code emails live

### Deployed
- Custom SMTP (Gmail, sender "FamilySync") configured by the owner; email rate limit 30/hour.
- Branded Malay templates with a one-time code applied for sign-up, password reset and email change.

### Changed
- "Masukkan kod" screen text is code-focused again (emails no longer contain links).

## [0.1.3] - 2026-11-22: Auth settings applied

### Changed
- "Semak e-mel anda" screen now explains both options: open the email link on this phone, or type the
  code. Needed because the free plan's default mailer cannot use custom (code) templates.

### Deployed (Management API)
- Password policy: minimum 8 characters, letters and digits required.
- Verified: Site URL / redirect URL = `familysync://auth-callback`.
- Not available on the free plan: custom email templates without custom SMTP, leaked-password protection.

## [0.1.2] - 2026-11-22: Code-based email verification

### Changed
- Sign-up confirmation and password reset now use a **one-time code** typed into the new
  *Masukkan kod* screen instead of an email link. The flow stays inside FamilySync and no longer depends
  on deep links or the project's Site URL (which still pointed to the old smartstock page).
- Signing in with an unconfirmed email resends the code and opens the code screen.
- Resend button with a 60-second cooldown; hint to check the Spam folder.

### Added
- Branded Malay email templates showing the code (`supabase/templates/*.html`) and
  `docs/AUTH_SETUP.md` with the dashboard settings (Site URL, templates, custom SMTP).
- Tests: verify-code widget tests, OTP error mapping, router rules (42 Flutter tests).

## [0.1.1] - 2026-11-22: Hosted deployment

### Added
- Migration `0400_backfill_existing_users`: profiles and preferences for accounts created before
  FamilySync was installed (with pgTAP test).
- Migration `0500_fk_indexes`: covering indexes for 8 foreign keys (Supabase performance advisor).

### Deployed
- All migrations and the `delete-account` Edge Function to Supabase project `bdakjtyxpgfkgfwjvlfq`
  (formerly `smartstock`, emptied after a verified backup). See docs/STATUS.md §9.

## [0.1.0] - 2026-11-22: Phase 0 + Phase 1 (foundation)

### Added
- Environment audit, roadmap and status report (`docs/STATUS.md`).
- Flutter 3.50.1 Android project (`com.familysync.app`) using Riverpod 3, GoRouter 18, Material 3
  (`material_ui`), Bahasa Melayu (primary) and English localization.
- Supabase schema: profiles, families, family_members, invitations, invitation_uses, audit_logs,
  device_tokens, user_preferences, rate limiting, RLS on every table, 13 SECURITY DEFINER RPCs.
- Private storage buckets `avatars` and `family-media`, with path-scoped policies, MIME and size limits.
- Realtime family membership updates (`family:{id}`).
- Auth flows: sign up with email confirmation, sign in, forgot/reset password via deep link, sign out,
  global sign-out, account deletion through the `delete-account` Edge Function.
- Family management: create, edit, photo, approval setting, roles, suspend/reactivate/remove,
  transfer ownership, leave, delete, switch family, activity feed.
- Invitations: hashed 80-bit codes, QR, share link, expiry, usage limits, revoke, history, approval,
  brute-force limiting, race-safe redemption.
- Dashboard with family header, member overview, recent activity.
- Tests: 79 pgTAP assertions, a 20-session invitation race test, and 39 Flutter unit/widget tests.
- App icon, splash screen, deep links, release-signing configuration, CI workflow.
