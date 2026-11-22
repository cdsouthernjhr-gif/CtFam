-- =============================================================================
-- FamilySync — Migration 0300: Realtime for family membership
-- Postgres Changes respects RLS: a subscriber only receives rows its SELECT
-- policy allows. Clients subscribe per family with a family_id filter.
-- =============================================================================
alter publication supabase_realtime add table public.family_members;
alter publication supabase_realtime add table public.families;
