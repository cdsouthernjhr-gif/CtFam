# Security

## Principles

1. **The database is the security boundary.** Every rule is enforced by Postgres Row Level Security
   and SECURITY DEFINER functions. The Flutter UI only hides buttons
   (`FamilyPermissions` mirrors the rules for display only).
2. **Least privilege.** Table privileges are revoked from `anon` and `authenticated`, then granted per
   column where a policy needs them (for example, members may update only `family_members.nickname`).
3. **No direct writes to sensitive tables.** `family_members`, `invitations`, `invitation_uses` and
   `families` (insert/delete) have no client write policies. All changes go through RPCs that check the
   caller's role from the database.
4. **Never trust JWT `user_metadata`.** It is used only as the default display name.

## Secrets

| Secret | Where it lives |
|---|---|
| Supabase publishable key | App build (`--dart-define`). Safe to ship. |
| Supabase service-role / secret key | Edge Function environment only. The app **refuses to start** if given an `sb_secret_` or `service_role` key. |
| Firebase service account | Edge Function secret `FCM_SERVICE_ACCOUNT_JSON` only. |
| Firebase client identifiers | App build (`--dart-define`). Public by design. |
| Push webhook secret | Supabase Vault (`push_webhook_secret`); never leaves the database. |
| Release keystore | Developer machine / CI secret, `android/key.properties` (git-ignored). |

## Authorization rules (tested in `supabase/tests/database/01_family_security.test.sql`)

| Rule | Enforcement |
|---|---|
| Users see only families they actively belong to | `families_select_member` → `private.is_family_member` (status `active`, family not deleted) |
| Suspended / pending / removed members lose access immediately | All helpers require `status = 'active'` |
| No self-join without a valid invitation | No INSERT policy on `family_members`; only `create_family` / `redeem_invitation` insert |
| No self-promotion | `role` column not granted; `set_member_role` requires a strictly higher rank and can never assign `owner` |
| Admins can't touch owners or other admins | `private.lock_manageable_member` rank check |
| Exactly one owner | Partial unique index `family_members_one_owner`; `transfer_ownership` is transactional |
| Cross-family isolation (IDOR/BOLA) | Every policy keys on the row's `family_id` / storage path, never on client input |
| Profiles readable only by people who share a family | `private.shares_family_with` |
| Device tokens private to their owner | own-row policies; `register_device_token` RPC |
| Activity feed vs admin audit | `audit_logs.visibility` = `members` / `admins` |

## Invitations

- Code: 16 symbols of Crockford base32 from `gen_random_bytes(16)`, 80 bits, no modulo bias.
- Stored as `sha256('familysync:invite:' || normalized_code)`. Only a 4-character hint is kept for the
  history list. The plaintext is returned exactly once.
- `redeem_invitation` locks the invitation row with `SELECT … FOR UPDATE`. Expiry, revocation, usage and
  family capacity are checked inside the same transaction.
  `supabase/tests/concurrency/single_use_invite_race.sh` races 20 sessions against one single-use code:
  exactly 1 joins.
- Replay: `invitation_uses (invitation_id, user_id)` is unique, and re-use by the same user returns
  `exhausted`.
- Brute force: more than 10 failed attempts in 15 minutes per user returns `rate_limited`, even for a valid
  code. Failures are returned rather than raised, so the attempt record commits.

## Chat

- Conversations and messages are readable only by **active members of both the family and the
  conversation**. Family admins are not automatically members of other people's private chats.
- `send_message` derives the sender from `auth.uid()`; message ids cannot be hijacked (an existing id
  owned by someone else is rejected).
- Attachment paths must be inside `{conversation}/{message}/` and must exist in Storage before sending.
  Deleting the message removes the attachment rows, which revokes read access to the files.
- Typing and online status use **private** Realtime channels. RLS on `realtime.messages` restricts
  `conversation:{id}` to its members and `presence:family:{id}` to family members. Malformed topics grant
  nothing.

## Notifications

- Message content is **not** included in notifications unless the recipient enabled previews
  (`show_message_preview`, default off). Android notifications also use `visibility = PRIVATE`.
- Recipients are re-checked at send time: active family member, still in the conversation, not muted,
  preference on.
- `notification_queue` and the push RPCs are service-role only. The Edge Function authenticates the
  database's call with a 64-hex secret kept in **Supabase Vault**; the function never stores it and asks
  the database to compare it (`verify_push_secret`). Missing or wrong secret gives 401 (verified on the
  hosted project).
- The FCM service account is an Edge Function secret (`FCM_SERVICE_ACCOUNT_JSON`) and never part of the
  app. The app only carries Firebase's public client identifiers.
- Notification taps navigate only to allow-listed in-app routes (`safeNotificationRoute`).
- Device tokens are deleted before sign-out and account deletion; unregistered tokens reported by FCM
  are deleted automatically.

## Calendar

- Events with visibility `participants` are readable only by the creator, participants and family
  owner/admin; RSVP to such an event is refused for anyone else, so members cannot add themselves.
- Only the creator or owner/admin can edit, delete or cancel occurrences; invitees must be active members
  of the same family.
- Reminders belong to participants (foreign key), are readable only by their owner, and stop when the user
  declines, leaves the family or loses access (checked at send time).

## Offline data on the device

- Cached responses and queued writes live in the app's private storage (SQLite), keyed by user id. They
  contain the same data the user can already read through RLS; nothing extra is stored.
- Signing in removes any other account's local data; signing out and deleting the account wipe the local
  database (after one last sync attempt; the user is warned about unsynced changes).
- Android backup and device-to-device transfer are disabled, so the database is not copied off the phone.
- The database is **not encrypted by the app**; it relies on Android's file-based encryption of app
  storage. SQLCipher could be added if a stricter threat model (rooted devices) is required.
- Replayed writes go through the same RLS-checked RPCs as live ones; a queued write is re-authorised when
  it is sent (lost access means it fails and is shown on the Sync screen).

## Rate limiting

`private.enforce_rate_limit(action, max, window)` applies to `create_family` (5/day),
`create_invitation` (30/h), `preview_invitation` (20/15 min), `register_device_token` (30/h),
`create_todo_list` (60/h), `create_todo_item` (600/h), `create_conversation` (100/h), `send_message` (60/min), `post_announcement` (10/day) and `create_event` (300/h).
Supabase Auth applies its own limits to sign-in, sign-up and email sending (see `supabase/config.toml`).

## Storage

- Buckets `avatars` and `family-media` are **private**, limited to 5 MB and `image/jpeg|png|webp`.
- The first path segment is the authorization key: `avatars/{user_id}/…`, `family-media/{family_id}/…`.
- Clients read through 1-hour signed URLs, which Storage only issues when the SELECT policy passes.

## SECURITY DEFINER review checklist

Every definer function:
- sets `search_path = ''` and uses schema-qualified names (asserted by a pgTAP test);
- derives the caller from `auth.uid()`, never from a parameter;
- has `EXECUTE` revoked from `PUBLIC` and `anon`;
- validates all inputs and locks rows it is about to change.

Helpers used by policies live in the `private` schema, which is not exposed through the Data API.

## Sessions and devices

- PKCE auth flow; refresh-token rotation enabled.
- *Sign out of all devices* calls `signOut(scope: global)`, which revokes every refresh token.
- Android backup and device-transfer of app data are disabled (`allowBackup=false`, data extraction
  rules), so session tokens are not copied off the device.
- Cleartext HTTP is disabled.

## Account deletion

The `delete-account` Edge Function identifies the user only from the verified JWT. It refuses while the
user still owns a family that has other members, removes their avatar files, and then deletes the auth
user. Database rows cascade.

## Known gaps (tracked in docs/STATUS.md)

- The local DB tests use a storage shim. Storage policies must also be verified once against a real
  Supabase project.

## Reporting

Report vulnerabilities privately to the project owner. Do not open public issues for security bugs.
