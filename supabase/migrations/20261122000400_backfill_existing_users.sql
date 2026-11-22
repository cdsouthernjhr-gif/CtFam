-- =============================================================================
-- FamilySync — Migration 0400: backfill rows for pre-existing auth users
-- The on_auth_user_created trigger only fires for NEW users. Accounts that
-- already existed when FamilySync was installed (e.g. when reusing a project)
-- get their profile and preferences here. Idempotent.
-- =============================================================================
insert into public.profiles (id, display_name)
select u.id,
       left(coalesce(nullif(btrim(u.raw_user_meta_data ->> 'display_name'), ''),
                     nullif(btrim(u.raw_user_meta_data ->> 'full_name'), ''),
                     split_part(coalesce(u.email, 'Ahli'), '@', 1)), 60)
from auth.users u
on conflict (id) do nothing;

insert into public.user_preferences (user_id)
select u.id from auth.users u
on conflict (user_id) do nothing;
