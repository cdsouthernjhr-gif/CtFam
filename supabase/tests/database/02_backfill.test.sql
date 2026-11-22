-- Re-running the backfill must create rows for users that lack them and be idempotent.
begin;
select no_plan();
-- simulate a user created before FamilySync's trigger existed
insert into auth.users (id, email, aud, role, raw_user_meta_data)
values ('00000000-0000-0000-0000-0000000000aa', 'legacy@test.local', 'authenticated', 'authenticated',
        '{"full_name":"Hisham Legacy"}');
delete from public.user_preferences where user_id = '00000000-0000-0000-0000-0000000000aa';
delete from public.profiles where id = '00000000-0000-0000-0000-0000000000aa';
select is((select count(*)::int from public.profiles where id = '00000000-0000-0000-0000-0000000000aa'), 0,
  'legacy user starts without a profile');
\i supabase/migrations/20261122000400_backfill_existing_users.sql
\i supabase/migrations/20261122000400_backfill_existing_users.sql
select is((select display_name from public.profiles where id = '00000000-0000-0000-0000-0000000000aa'), 'Hisham Legacy',
  'backfill creates the profile from full_name metadata');
select is((select count(*)::int from public.user_preferences where user_id = '00000000-0000-0000-0000-0000000000aa'), 1,
  'backfill creates preferences exactly once');
select * from finish();
rollback;
