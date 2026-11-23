-- =============================================================================
-- FamilySync — Migration 20261124000200: RLS and query performance (Phase 7)
--
-- Measured with supabase/tests/perf/perf_check.sql (100 members, 25k
-- messages, 2k tasks, 500 events): the chat list took 2.9 s and message search
-- 3.5 s, because read policies called a membership function once PER ROW
-- (`private.is_conversation_member(conversation_id)`).
--
-- Policies now compare against the SET of ids the caller may read, computed
-- once per statement (`col in (select private.my_..._ids())`, a hashed
-- subplan). The rules are unchanged; only the evaluation strategy differs.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Set-returning access helpers (same rules as the per-id helpers)
-- -----------------------------------------------------------------------------

-- Conversations the caller is an active member of, in families where the
-- caller is an active member (mirrors private.is_conversation_member).
create or replace function private.my_conversation_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select cm.conversation_id
  from public.conversation_members cm
  join public.conversations c on c.id = cm.conversation_id and c.deleted_at is null
  join public.family_members fm on fm.family_id = c.family_id and fm.user_id = cm.user_id and fm.status = 'active'
  join public.families f on f.id = c.family_id and f.deleted_at is null
  where cm.user_id = (select auth.uid()) and cm.left_at is null;
$$;

-- To-Do lists the caller may read, including soft-deleted ones so Realtime
-- delivers deletions (mirrors private.can_read_todo_list).
create or replace function private.readable_todo_list_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select l.id
  from public.todo_lists l
  join public.family_members fm on fm.family_id = l.family_id and fm.user_id = (select auth.uid()) and fm.status = 'active'
  join public.families f on f.id = l.family_id and f.deleted_at is null
  where l.visibility = 'family'
     or l.created_by = fm.user_id
     or fm.role in ('owner', 'admin')
     or exists (select 1 from public.todo_list_members m where m.list_id = l.id and m.user_id = fm.user_id);
$$;

-- Events the caller may read, including soft-deleted ones
-- (mirrors private.can_read_event).
create or replace function private.readable_event_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select e.id
  from public.family_events e
  join public.family_members fm on fm.family_id = e.family_id and fm.user_id = (select auth.uid()) and fm.status = 'active'
  join public.families f on f.id = e.family_id and f.deleted_at is null
  where e.visibility = 'family'
     or e.created_by = fm.user_id
     or fm.role in ('owner', 'admin')
     or exists (select 1 from public.event_participants p where p.event_id = e.id and p.user_id = fm.user_id);
$$;

revoke all on function private.my_conversation_ids() from public;
revoke all on function private.readable_todo_list_ids() from public;
revoke all on function private.readable_event_ids() from public;
grant execute on function private.my_conversation_ids() to authenticated;
grant execute on function private.readable_todo_list_ids() to authenticated;
grant execute on function private.readable_event_ids() to authenticated;

-- -----------------------------------------------------------------------------
-- Policies
-- -----------------------------------------------------------------------------
alter policy conversations_select on public.conversations
  using (id in (select private.my_conversation_ids()));
alter policy conversation_members_select on public.conversation_members
  using (conversation_id in (select private.my_conversation_ids()));
alter policy messages_select on public.messages
  using (conversation_id in (select private.my_conversation_ids()));
alter policy message_attachments_select on public.message_attachments
  using (conversation_id in (select private.my_conversation_ids()));
alter policy message_receipts_select on public.message_receipts
  using (conversation_id in (select private.my_conversation_ids()));

alter policy todo_lists_select on public.todo_lists
  using (id in (select private.readable_todo_list_ids()));
alter policy todo_list_members_select on public.todo_list_members
  using (list_id in (select private.readable_todo_list_ids()));
alter policy todo_items_select on public.todo_items
  using (list_id in (select private.readable_todo_list_ids()));
alter policy todo_assignments_select on public.todo_assignments
  using (list_id in (select private.readable_todo_list_ids()));
alter policy todo_comments_select on public.todo_comments
  using (list_id in (select private.readable_todo_list_ids()));
alter policy todo_activity_select on public.todo_activity_logs
  using (
    (list_id is not null and list_id in (select private.readable_todo_list_ids()))
    or (list_id is null and (select private.is_family_member(family_id)))
  );

alter policy family_events_select on public.family_events
  using (id in (select private.readable_event_ids()));
alter policy event_participants_select on public.event_participants
  using (event_id in (select private.readable_event_ids()));

-- -----------------------------------------------------------------------------
-- Chat list: unread badges show "99+", so stop counting at 100.
-- -----------------------------------------------------------------------------
create or replace function public.conversation_summaries(p_family_id uuid)
returns table (
  id uuid, kind public.conversation_kind, name text, description text, image_path text,
  last_message_at timestamptz, last_message_preview text, last_message_sender_id uuid,
  created_at timestamptz, my_role text, muted_until timestamptz, pinned_at timestamptz,
  other_user_id uuid, member_count int, unread_count int)
language sql
stable
security invoker
set search_path = ''
as $$
  select c.id, c.kind, c.name, c.description, c.image_path,
         c.last_message_at, c.last_message_preview, c.last_message_sender_id, c.created_at,
         me.role, me.muted_until, me.pinned_at,
         (select o.user_id from public.conversation_members o
           where o.conversation_id = c.id and o.user_id <> me.user_id and c.kind = 'direct' limit 1),
         (select count(*)::int from public.conversation_members m where m.conversation_id = c.id and m.left_at is null),
         (select count(*)::int from (
            select 1 from public.messages msg
             where msg.conversation_id = c.id and msg.deleted_at is null and msg.kind <> 'system'
               and msg.sender_id is distinct from me.user_id
               and msg.created_at > coalesce(r.last_read_at, me.joined_at - interval '1 second')
             limit 100) u)
  from public.conversations c
  join public.conversation_members me on me.conversation_id = c.id and me.user_id = auth.uid() and me.left_at is null
  left join public.message_receipts r on r.conversation_id = c.id and r.user_id = me.user_id
  where c.family_id = p_family_id and c.deleted_at is null
  order by me.pinned_at desc nulls last, coalesce(c.last_message_at, c.created_at) desc;
$$;

-- -----------------------------------------------------------------------------
-- Message search: trigram index for ILIKE '%term%'.
-- -----------------------------------------------------------------------------
create extension if not exists pg_trgm with schema extensions;
create index if not exists messages_body_trgm_idx on public.messages
  using gin (body extensions.gin_trgm_ops) where deleted_at is null;
