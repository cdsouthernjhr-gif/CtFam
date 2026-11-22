# Changelog

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
