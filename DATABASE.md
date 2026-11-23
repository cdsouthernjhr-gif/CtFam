# Database

Postgres 17 on Supabase. Migrations live in `supabase/migrations/` and are applied in filename order.

| Migration | Contents |
|---|---|
| `20261122000100_foundation.sql` | enums, helpers, profiles, families, family_members, invitations, invitation_uses, audit_logs, device_tokens, user_preferences, rate limiting, RLS, RPCs |
| `20261122000200_storage.sql` | private buckets `avatars`, `family-media`, plus their policies |
| `20261122000300_realtime_family.sql` | adds `family_members`, `families` to `supabase_realtime` |
| `20261122000400_backfill_existing_users.sql` | profile + preferences for accounts that existed before install (idempotent) |
| `20261122000500_fk_indexes.sql` | covering indexes for foreign keys |
| `20261123000100_todo.sql` | shared To-Do: tables, RLS, RPCs, Realtime publication |
| `20261123000200_chat.sql` | private and group chat, attachments bucket, Realtime Authorization policies |
| `20261123000300_notifications.sql` | inbox, push queue, notify triggers, announcements, service-role RPCs |
| `20261123000400_push_dispatch.sql` | pg_net/pg_cron dispatch, Vault-verified webhook, housekeeping |
| `20261123000500_calendar.sql` | family calendar: events, RSVP, reminders, recurrence, reminder cron |

All timestamps are `timestamptz` (stored in UTC, displayed in the device's local time). All primary keys
are UUIDs.

## Tables (Phase 1)

| Table | Purpose | Client access |
|---|---|---|
| `profiles` | 1:1 with `auth.users`, created by trigger | read: self + shared-family; update: self (selected columns) |
| `families` | family record, settings, soft delete (`deleted_at`) | read: active members; update: owner/admin |
| `family_members` | membership, `role` (`owner/admin/moderator/member`), `status` (`pending/active/suspended/removed/left`) | read: members of that family; update: own `nickname` only |
| `invitations` | hashed code, limits, expiry, revocation | read: owner/admin |
| `invitation_uses` | one row per redemption (unique per user and invitation) | read: self, owner/admin |
| `audit_logs` | family activity (`members`) and admin audit (`admins`) | read by visibility |
| `device_tokens` | FCM registration tokens | own rows |
| `user_preferences` | active family, notification toggles, theme | own row |
| `private.invitation_attempts`, `private.rate_limit_events` | abuse protection | none (private schema) |

Key constraints: `unique (family_id, user_id)` on members; a partial unique index ensures **one active
owner per family**; check constraints mirror the client validators (name lengths, phone format,
`use_count <= max_uses`, and so on).

### Relationship notes

`family_members.user_id`, `invitation_uses.user_id` and `audit_logs.actor_id` reference `profiles(id)`
(which cascades from `auth.users`), so PostgREST can embed profiles in a single query, for example
`family_members?select=*,profiles(display_name,avatar_path)`.

## RPCs (all `SECURITY DEFINER`, `authenticated` only)

| Function | Who | Notes |
|---|---|---|
| `create_family(name, description)` → uuid | any user | caller becomes owner; 5/day |
| `delete_family(family_id, confirm_name)` | owner | soft delete; revokes all invitations |
| `create_invitation(family_id, max_uses, expires_in_hours, requires_approval, note)` → (id, code, expires_at) | owner; admin if `allow_admin_invites` | code returned once |
| `revoke_invitation(id)` | owner/admin | idempotent |
| `preview_invitation(code)` → (family_name, member_count, requires_approval, expires_at) | any user | rate limited |
| `redeem_invitation(code)` → jsonb `{status, family_id}` | any user | atomic; see SECURITY.md |
| `review_membership(family_id, user_id, approve)` | owner/admin | pending only |
| `set_member_role(family_id, user_id, role)` | owner/admin | strictly lower rank; never `owner` |
| `set_member_status(family_id, user_id, status)` | owner/admin | `active` (from suspended), `suspended`, `removed` |
| `transfer_ownership(family_id, new_owner)` | owner | old owner becomes admin |
| `leave_family(family_id)` | member | an owner with other members must transfer first |
| `register_device_token(token, device_name, app_version)` | any user | token moves to the latest account on that device |
| `account_deletion_blockers()` | any user | families the caller still owns with other members |

Errors are raised as short codes (`forbidden`, `rate_limited`, `owner_must_transfer`, …), which the app
maps to localized messages (`lib/core/errors/app_failure.dart`).

## Realtime channels

| Channel | Source | Used by |
|---|---|---|
| `family:{family_id}` | Postgres Changes on `family_members` (filter `family_id`) and `families` (filter `id`) | Family, Dashboard |

Subscriptions are opened only while a screen watches them (Riverpod `autoDispose`) and are removed on
dispose. After every (re)subscribe the client re-fetches, so missed events while offline are reconciled.
Phase 2–4 channels are listed in their sections below.

## To-Do (Phase 2)

| Table | Purpose | Client access |
|---|---|---|
| `todo_lists` | list per family; `visibility` = `family` or `members`; `revision`; soft delete | read via `can_read_todo_list`; writes via RPC |
| `todo_list_members` | explicit members of a members-only list | read; writes via `set_todo_list_members` |
| `todo_items` | tasks; `status`, `priority`, `due_at`, `recurrence`, `recurrence_source_id` (unique), `revision`, soft delete | read; writes via RPC |
| `todo_assignments` | item ↔ member (denormalised `list_id`, `family_id`) | read; writes via `upsert_todo_item` |
| `todo_comments` | comments (client UUID for idempotent posting) | read; insert as self; edit own |
| `todo_activity_logs` | per-list history | read |
| `todo_categories` | custom categories per family | members CRUD (own) |

**Access helpers:** `private.can_read_todo_list` (family member and list visible, *including* soft-deleted
rows, so Realtime delivers deletions) and `private.can_access_todo_list` (same, but active lists only; used
for every write).

| RPC | Notes |
|---|---|
| `create_todo_list(id, family_id, name, category, description, visibility, member_ids)` | idempotent on `id` |
| `update_todo_list(id, name, description, category, expected_revision)` | creator or owner/admin; `revision_conflict` (P0409) |
| `delete_todo_list(id)` | creator or owner/admin; soft delete |
| `set_todo_list_members(list_id, user_ids)` | creator or owner/admin; members must be active family members |
| `upsert_todo_item(id, list_id, title, description, priority, due_at, recurrence, assignee_ids, expected_revision)` | idempotent create; stale edit gives `revision_conflict`; `assignee_ids` null = unchanged |
| `set_todo_item_status(id, completed)` | idempotent; recurring items create the next occurrence once |
| `delete_todo_item(id)` | item creator, list creator or owner/admin; idempotent |
| `todo_list_summaries(family_id)` | SECURITY INVOKER; progress, overdue and due-today counts |

**Realtime:** `todo_lists`, `todo_items`, `todo_comments` are in `supabase_realtime`. Channels:
`todo:{list_id}` (filter `list_id` / `id`) and `todo-family:{family_id}` (filter `family_id`). Assignment
changes bump the item's revision, so they arrive as `todo_items` updates.

## Chat (Phase 3)

| Table | Purpose | Client access |
|---|---|---|
| `conversations` | `kind` direct/group; `direct_key` UNIQUE (`family:least(uid):greatest(uid)`); last message preview | read if member; writes via RPC |
| `conversation_members` | membership, `role` admin/member, `left_at`, own `muted_until`/`pinned_at` | read if member; update own mute/pin only |
| `messages` | client UUID id; `kind` text/image/file/system; reply, edit, soft delete, pin | read if member (deleted rows stay readable, so Realtime delivers deletions); writes via RPC |
| `message_attachments` | storage path, MIME, size, dimensions | read if member |
| `message_receipts` | per-member `last_delivered_at` / `last_read_at` cursors | read if member; writes via RPC |

Access: `private.is_conversation_member` (active family member and active conversation member);
`private.can_moderate_conversation` (group admin or family owner/admin/moderator).

| RPC | Notes |
|---|---|
| `get_or_create_direct_conversation(family_id, other_user_id)` | race-safe; both users must be active family members |
| `create_group_conversation(id, family_id, name, description, member_ids)` | idempotent; creator becomes admin |
| `update_group_conversation`, `add_conversation_members`, `remove_conversation_member`, `set_conversation_member_role` | moderators |
| `leave_conversation(id)` | groups; ensures an admin remains |
| `send_message(id, conversation_id, body, reply_to_id, attachments)` | idempotent; validation as above |
| `edit_message`, `delete_message`, `set_message_pinned` | see SECURITY.md |
| `mark_conversation_read(conversation_id, up_to)`, `mark_family_delivered(family_id)` | monotonic cursors |
| `conversation_summaries(family_id)`, `search_messages(family_id, query)` | SECURITY INVOKER |

**Storage:** private bucket `chat-attachments` (10 MB; images, PDF, text, Office). Path
`{conversation_id}/{message_id}/{file}`. Upload and read are limited to conversation members; reads also
require the file to belong to a non-deleted message (or be the uploader's own unsent upload).

**Realtime Authorization** (RLS on `realtime.messages`, private channels only):
`conversation:{id}` for conversation members (Broadcast typing; Postgres Changes) and
`presence:family:{id}` for active family members (Presence).

## Notifications (Phase 4)

| Object | Purpose | Access |
|---|---|---|
| `notifications` | per-user inbox; `type`, `title`, `body`, `data.route`, `dedupe_key` (unique per user), `read_at` | own rows; update `read_at` only |
| `notification_queue` | push jobs: `pending → sending → sent/failed`, attempts, backoff | service role only |
| `user_preferences.timezone` | quiet-hours time zone (default `Asia/Kuala_Lumpur`) | own row |
| `private.notify(...)` | recipient filtering and texts (see SECURITY.md) | internal |
| `post_announcement(family_id, title, body)` | owner/admin, 10/day | authenticated |
| `mark_notifications_read(ids)` | null = all | authenticated |
| `claim_push_batch(limit)`, `complete_push(...)`, `verify_push_secret(secret)` | used by `send-push` | service role only |
| `private.push_config` | function URL | internal |
| Vault secret `push_webhook_secret` | `x-push-secret` header | never leaves the DB |
| cron `familysync-push` (every minute), `familysync-housekeeping` (03:17 daily) | dispatch retries, pruning | pg_cron |

Realtime: `notifications` (channel `notifications:{uid}`, filter `user_id`).

## Calendar (Phase 5)

| Table | Purpose | Client access |
|---|---|---|
| `family_events` | client UUID id; times as `timestamptz` + IANA `timezone`; `all_day`; `recurrence` + `recurrence_until`; `cancelled_occurrences`; `default_reminders`; `visibility`; `revision`; soft delete | read via `can_read_event` (incl. deleted, for Realtime); writes via RPC |
| `event_participants` | invitees + RSVP `pending/going/maybe/declined` | read if the event is readable; writes via RPC |
| `event_reminders` | per participant, minutes before start (0 to 4 weeks, max 5) | own rows only; writes via RPC |

| RPC | Notes |
|---|---|
| `upsert_family_event(id, family_id, title, starts_at, ends_at, all_day, timezone, description, location, category, recurrence, recurrence_until, visibility, participant_ids, reminder_minutes, expected_revision)` | create: any active member, 300/h, idempotent and race-safe; update: creator or owner/admin, `revision_conflict` (P0409) |
| `delete_family_event(id)` | creator or owner/admin; soft delete; idempotent |
| `cancel_event_occurrence(id, occurrence_start)` | must be a real occurrence; idempotent |
| `set_event_rsvp(event_id, rsvp)` | anyone who can see the event; joining copies the default reminders |
| `set_event_reminders(event_id, minutes[])` | participants only, own reminders |
| `calendar_occurrences(family_id, from, to)` | SECURITY INVOKER; expands recurrences; max 400 days |

`private.event_occurrences()` expands a series in the event's time zone, always from the first start
(`local_start + n × step`), so there is no drift and DST keeps the wall-clock time.
`private.dispatch_event_reminders()` runs every minute (`familysync-event-reminders`) with a 10-minute
look-back; the dedupe key `remind:{event}:{occurrence}:{minutes}` makes each reminder fire once.

Realtime: `family_events`, `event_participants` (channel `calendar:{family_id}`, filter `family_id`).

## Planned tables (later phases)

`sync_operations` (Phase 6, offline). They will be added as new migrations, and existing migrations will not be edited once
deployed.

## Typed models

Dart models in `lib/features/*/domain/*_models.dart` are hand-written to match these columns. The
`select` strings sit next to the models (for example, `FamilyMember.select`) to keep queries and parsing
in sync.
