# Changelog

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
