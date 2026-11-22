-- =============================================================================
-- FamilySync — Migration 0500: covering indexes for foreign keys
-- Flagged by the Supabase performance advisor (unindexed_foreign_keys). These
-- keep ON DELETE CASCADE / SET NULL from scanning whole tables when a user or
-- family is deleted.
-- =============================================================================
create index if not exists audit_logs_actor_idx              on public.audit_logs (actor_id);
create index if not exists families_created_by_idx           on public.families (created_by);
create index if not exists family_members_invited_by_idx     on public.family_members (invited_by);
create index if not exists family_members_status_changed_by_idx on public.family_members (status_changed_by);
create index if not exists invitation_uses_user_idx          on public.invitation_uses (user_id);
create index if not exists invitations_created_by_idx        on public.invitations (created_by);
create index if not exists invitations_revoked_by_idx        on public.invitations (revoked_by);
create index if not exists user_preferences_active_family_idx on public.user_preferences (active_family_id);
