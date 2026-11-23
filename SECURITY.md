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
| Firebase service account (Phase 4) | Edge Function secret only. |
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
- Notifications (Phase 4) will hide message content on the lock screen by default
  (`user_preferences.show_message_preview = false`).

## Rate limiting

`private.enforce_rate_limit(action, max, window)` applies to `create_family` (5/day),
`create_invitation` (30/h), `preview_invitation` (20/15 min), `register_device_token` (30/h),
`create_todo_list` (60/h), `create_todo_item` (600/h), `create_conversation` (100/h) and `send_message` (60/min).
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

- Lock-screen privacy for notifications arrives with Phase 4 (the default `show_message_preview = false`
  is already stored).
- The local DB tests use a storage shim. Storage policies must also be verified once against a real
  Supabase project.
- Rate-limit tables are not pruned yet. A scheduled cleanup job is planned for Phase 7.

## Reporting

Report vulnerabilities privately to the project owner. Do not open public issues for security bugs.
