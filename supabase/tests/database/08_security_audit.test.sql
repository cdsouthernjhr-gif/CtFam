-- FamilySync — Catalog-wide security audit (Phase 7).
-- Guards against regressions in future migrations: a new table without RLS,
-- a grant to anon, a function exposed by accident, a public bucket, …
begin;
select no_plan();

-- 1. Row Level Security everywhere in the exposed schema
select is(
  (select coalesce(array_agg(c.relname order by c.relname), '{}') from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relrowsecurity),
  '{}'::name[], 'every public table has RLS enabled');

-- Tables that intentionally have no client policy (service role / RPC only)
select is(
  (select coalesce(array_agg(c.relname::text order by c.relname), '{}') from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
     and not exists (select 1 from pg_policies p where p.schemaname = 'public' and p.tablename = c.relname)),
  array['notification_queue'], 'only notification_queue has no policy (service role only)');

-- 2. anon has nothing in public
select is(
  (select count(*)::int from information_schema.role_table_grants
    where grantee = 'anon' and table_schema = 'public'),
  0, 'anon has no table privileges in public');

select is(
  (select coalesce(array_agg(p.proname::text order by p.proname), '{}') from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')),
  '{}'::text[], 'anon cannot execute any public function');

select ok(not has_schema_privilege('anon', 'private', 'usage'), 'anon cannot use the private schema');

-- 3. The exact set of functions signed-in users can call (catches accidental exposure)
select is(
  (select array_agg(distinct p.proname::text order by p.proname::text) from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and has_function_privilege('authenticated', p.oid, 'execute')),
  array[
    'account_deletion_blockers', 'add_conversation_members', 'calendar_occurrences', 'cancel_event_occurrence',
    'conversation_summaries', 'create_family', 'create_group_conversation', 'create_invitation',
    'create_todo_list', 'delete_family', 'delete_family_event', 'delete_message', 'delete_todo_item',
    'delete_todo_list', 'edit_message', 'get_or_create_direct_conversation', 'leave_conversation',
    'leave_family', 'mark_conversation_read', 'mark_family_delivered', 'mark_notifications_read',
    'post_announcement', 'preview_invitation', 'redeem_invitation', 'register_device_token',
    'remove_conversation_member', 'review_membership', 'revoke_invitation', 'search_messages',
    'send_message', 'set_conversation_member_role', 'set_event_reminders', 'set_event_rsvp',
    'set_member_role', 'set_member_status', 'set_message_pinned', 'set_todo_item_status',
    'set_todo_list_members', 'todo_list_summaries', 'transfer_ownership', 'update_group_conversation',
    'update_todo_list', 'upsert_family_event', 'upsert_todo_item'
  ]::text[],
  'callable RPCs match the reviewed allow-list');

select is(
  (select coalesce(array_agg(p.proname::text order by p.proname), '{}') from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('claim_push_batch', 'complete_push', 'verify_push_secret')
     and has_function_privilege('authenticated', p.oid, 'execute')),
  '{}'::text[], 'push RPCs are service-role only');

-- 4. SECURITY DEFINER hygiene
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'private') and p.prosecdef
     and not exists (select 1 from unnest(p.proconfig) c where c = 'search_path=""' or c = 'search_path=')),
  0, 'every SECURITY DEFINER function uses an empty search_path');

select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'private') and p.prosecdef and has_function_privilege('public', p.oid, 'execute')),
  0, 'no SECURITY DEFINER function is executable by PUBLIC');

-- 5. Policies never grant blanket write access
select is(
  (select coalesce(array_agg(tablename || '.' || policyname order by tablename), '{}') from pg_policies
    where schemaname = 'public' and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')
      and (coalesce(qual, '') = 'true' or coalesce(with_check, '') = 'true')),
  '{}'::text[], 'no write policy is unconditionally true');

select is(
  (select coalesce(array_agg(tablename || '.' || policyname order by tablename), '{}') from pg_policies
    where schemaname = 'public' and 'anon' = any (roles)),
  '{}'::text[], 'no policy targets anon');

select is(
  (select coalesce(array_agg(tablename || '.' || policyname order by tablename), '{}') from pg_policies
    where schemaname = 'public' and 'public' = any (roles)),
  '{}'::text[], 'no policy targets PUBLIC (every policy names its role)');

-- 6. Views must not bypass RLS
select is(
  (select coalesce(array_agg(c.relname::text), '{}') from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('v', 'm')
      and not coalesce(c.reloptions @> array['security_invoker=true'], false)),
  '{}'::text[], 'no public view runs with owner rights');

-- 7. Storage and Realtime
select is((select count(*)::int from storage.buckets where public), 0, 'every storage bucket is private');

select is(
  (select coalesce(array_agg(t.tablename::text order by t.tablename), '{}') from pg_publication_tables t
    join pg_class c on c.relname = t.tablename
    join pg_namespace n on n.oid = c.relnamespace and n.nspname = t.schemaname
   where t.pubname = 'supabase_realtime' and not c.relrowsecurity),
  '{}'::text[], 'every Realtime table has RLS (Postgres Changes respect it)');

select is(
  (select coalesce(array_agg(t.tablename::text order by t.tablename), '{}') from pg_publication_tables t
   where t.pubname = 'supabase_realtime' and t.schemaname = 'public'
     and t.tablename in ('notification_queue', 'invitations', 'invitation_uses', 'device_tokens', 'audit_logs')),
  '{}'::text[], 'sensitive tables are not broadcast through Realtime');

-- 8. Secrets never stored in plain columns
select is(
  (select coalesce(array_agg(table_name || '.' || column_name), '{}') from information_schema.columns
    where table_schema = 'public' and column_name ~* '(password|secret|plain_code|raw_code|service_role)'),
  '{}'::text[], 'no secret-looking columns in public');

select ok(
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'invitations'
           and column_name = 'token_hash'),
  'invitation codes are stored hashed');

select * from finish();
rollback;
