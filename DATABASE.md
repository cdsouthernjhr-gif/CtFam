# Database

Postgres 17 on Supabase. Migrations live in `supabase/migrations/` and are applied in filename order.

| Migration | Contents |
|---|---|
| `20261122000100_foundation.sql` | enums, helpers, profiles, families, family_members, invitations, invitation_uses, audit_logs, device_tokens, user_preferences, rate limiting, RLS, RPCs |
| `20261122000200_storage.sql` | private buckets `avatars`, `family-media`, plus their policies |
| `20261122000300_realtime_family.sql` | adds `family_members`, `families` to `supabase_realtime` |
| `20261122000400_backfill_existing_users.sql` | profile + preferences for accounts that existed before install (idempotent) |
| `20261122000500_fk_indexes.sql` | covering indexes for foreign keys |

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
| `device_tokens` | FCM tokens (used in Phase 4) | own rows |
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
Planned channels: `todo:{list_id}` (Phase 2), `conversation:{id}` with Broadcast for typing and Presence
for online status (Phase 3).

## Planned tables (later phases)

Chat (`conversations`, `conversation_members`, `messages`, `message_attachments`, `message_receipts`),
To-Do (`todo_lists`, `todo_list_members`, `todo_items` with `revision` column, `todo_assignments`,
`todo_activity_logs`, `todo_comments`, `todo_categories`), Calendar (`family_events`,
`event_participants`, `event_reminders`), notifications (`notifications`, `notification_queue`) and
`sync_operations`. They will be added as new migrations, and existing migrations will not be edited once
deployed.

## Typed models

Dart models in `lib/features/*/domain/*_models.dart` are hand-written to match these columns. The
`select` strings sit next to the models (for example, `FamilyMember.select`) to keep queries and parsing
in sync.
