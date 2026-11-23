-- =============================================================================
-- FamilySync — Migration 20261124000700: clan events (rumpun, stage 3)
--
--   * new event visibility 'clan': visible to every member of every family in
--     the organiser's clan, who may RSVP (and then gets reminders); only the
--     organiser's family edits it;
--   * calendar_occurrences(family) also returns clan events from linked
--     families;
--   * private.notify widens recipients to the clan ONLY for 'family_event'
--     notifications. Chats, tasks, announcements and requests still require
--     membership of the family itself, so someone who left a family but is in
--     a linked one does not keep receiving its chat notifications.
-- "All my families" calendar views are built in the app from data each user
-- can already read.
-- =============================================================================

alter table public.family_events drop constraint family_events_visibility_check;
alter table public.family_events add constraint family_events_visibility_check
  check (visibility in ('family', 'participants', 'clan'));

create or replace function private.event_visible_to(p_event_id uuid, p_user uuid, p_include_deleted boolean)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.family_events e
    where e.id = p_event_id
      and (p_include_deleted or e.deleted_at is null)
      and (
        (private.family_role_of(e.family_id, p_user) is not null
         and (e.visibility in ('family', 'clan')
              or e.created_by = p_user
              or private.family_role_of(e.family_id, p_user) in ('owner', 'admin')
              or exists (select 1 from public.event_participants p where p.event_id = e.id and p.user_id = p_user)))
        or (e.visibility = 'clan' and private.is_clan_member(e.family_id, p_user))
      )
  );
$$;

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
  where e.visibility in ('family', 'clan')
     or e.created_by = fm.user_id
     or fm.role in ('owner', 'admin')
     or exists (select 1 from public.event_participants p where p.event_id = e.id and p.user_id = fm.user_id)
  union
  select e.id from public.family_events e
  where e.visibility = 'clan' and e.family_id in (select private.my_clan_family_ids());
$$;

-- Clan of a family the caller belongs to (empty otherwise).
create or replace function private.clan_of_my_family(p_family_id uuid)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select c.family_id from private.family_clan(p_family_id) c where private.is_family_member(p_family_id);
$$;
revoke all on function private.clan_of_my_family(uuid) from public;
grant execute on function private.clan_of_my_family(uuid) to authenticated;

create or replace function public.calendar_occurrences(p_family_id uuid, p_from timestamptz, p_to timestamptz)
returns table (event_id uuid, occurrence_start timestamptz, occurrence_end timestamptz)
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  if p_from is null or p_to is null or p_to <= p_from or p_to - p_from > interval '400 days' then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  return query
    select e.id, o.occurrence_start, o.occurrence_end
    from public.family_events e
    cross join lateral private.event_occurrences(e.starts_at, e.ends_at, e.timezone, e.recurrence, e.recurrence_until,
                                                 e.cancelled_occurrences, p_from, p_to) o
    where (e.family_id = p_family_id
           or (e.visibility = 'clan' and e.family_id in (select private.clan_of_my_family(p_family_id))))
      and e.deleted_at is null
      and e.starts_at < p_to
      and (e.recurrence <> 'none' or e.ends_at >= p_from)
      and (e.recurrence_until is null or e.recurrence_until >= (p_from - interval '1 day')::date)
    order by o.occurrence_start, e.id;
end;
$$;

create or replace function private.notify(
  p_user_ids uuid[],
  p_family_id uuid,
  p_type text,
  p_dedupe_key text,
  p_texts jsonb,
  p_data jsonb default '{}'::jsonb,
  p_actor uuid default null,
  p_conversation_id uuid default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_lang text;
  v_t jsonb;
  v_id uuid;
  v_body text;
  v_count int := 0;
begin
  for r in
    select distinct u.uid, p.locale, pr.notify_private_messages, pr.notify_group_messages, pr.notify_tasks,
           pr.notify_events, pr.notify_announcements, pr.show_message_preview, pr.quiet_hours_start,
           pr.quiet_hours_end, pr.timezone
    from unnest(coalesce(p_user_ids, '{}')) u(uid)
    join public.profiles p on p.id = u.uid
    left join public.user_preferences pr on pr.user_id = u.uid
    where u.uid is distinct from p_actor
      and (private.family_role_of(p_family_id, u.uid) is not null
           -- clan events (and only events) also reach members of linked families
           or (p_type = 'family_event' and private.is_clan_member(p_family_id, u.uid)))
  loop
    -- preference toggle for this type
    if not coalesce(case p_type
         when 'private_message' then r.notify_private_messages
         when 'group_message' then r.notify_group_messages
         when 'task_created' then r.notify_tasks
         when 'task_assigned' then r.notify_tasks
         when 'task_completed' then r.notify_tasks
         when 'family_event' then r.notify_events
         when 'announcement' then r.notify_announcements
         else true end, true) then
      continue;
    end if;
    -- muted conversation / no longer a member
    if p_conversation_id is not null and not exists (
         select 1 from public.conversation_members cm
         where cm.conversation_id = p_conversation_id and cm.user_id = r.uid and cm.left_at is null
           and (cm.muted_until is null or cm.muted_until <= now())) then
      continue;
    end if;

    v_lang := case when r.locale = 'en' then 'en' else 'ms' end;
    v_t := coalesce(p_texts -> v_lang, p_texts -> 'ms');
    v_body := case when coalesce(r.show_message_preview, false) and (v_t ->> 'preview') is not null
                   then v_t ->> 'preview' else v_t ->> 'body' end;

    insert into public.notifications (user_id, family_id, type, title, body, data, dedupe_key)
    values (r.uid, p_family_id, p_type, left(coalesce(v_t ->> 'title', 'FamilySync'), 120), left(coalesce(v_body, ''), 300),
            coalesce(p_data, '{}'::jsonb), left(p_dedupe_key, 200))
    on conflict (user_id, dedupe_key) do nothing
    returning id into v_id;
    if v_id is null then
      continue;  -- duplicate event
    end if;
    v_count := v_count + 1;

    if exists (select 1 from public.device_tokens d where d.user_id = r.uid)
       and not private.in_quiet_hours(r.quiet_hours_start, r.quiet_hours_end, r.timezone) then
      insert into public.notification_queue (notification_id, user_id) values (v_id, r.uid);
    end if;
  end loop;
  return v_count;
end;
$$;
revoke all on function private.notify(uuid[], uuid, text, text, jsonb, jsonb, uuid, uuid) from public;
