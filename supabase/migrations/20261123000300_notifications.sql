-- =============================================================================
-- FamilySync — Migration 20261123000300: Notifications (Phase 4)
--
--   notifications       per-user inbox (also the source of push messages)
--   notification_queue  push delivery queue, processed by the send-push Edge
--                       Function with the service role (no client access)
--
-- private.notify() decides, per recipient:
--   * recipient must be an active family member and not the actor
--   * the matching user_preferences toggle must be on
--   * muted conversations get no notification
--   * dedupe: UNIQUE (user_id, dedupe_key) — the same event never notifies
--     twice, even if a trigger fires again
--   * language from profiles.locale (ms / en)
--   * lock-screen privacy: message content is only included when the
--     recipient enabled show_message_preview (default OFF)
--   * quiet hours (recipient's time zone): inbox entry only, no push
--   * push only when the recipient has a registered device
-- =============================================================================

alter table public.user_preferences
  add column if not exists timezone text not null default 'Asia/Kuala_Lumpur'
    check (char_length(timezone) between 1 and 64);
grant update (timezone) on public.user_preferences to authenticated;

create table public.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  family_id   uuid references public.families (id) on delete cascade,
  type        text not null check (type in (
                'private_message', 'group_message', 'task_created', 'task_assigned', 'task_completed',
                'family_request', 'member_joined', 'family_event', 'announcement')),
  title       text not null check (char_length(title) between 1 and 120),
  body        text not null check (char_length(body) <= 300),
  data        jsonb not null default '{}'::jsonb,
  dedupe_key  text not null check (char_length(dedupe_key) between 1 and 200),
  read_at     timestamptz,
  created_at  timestamptz not null default now(),
  unique (user_id, dedupe_key)
);
create index notifications_user_idx on public.notifications (user_id, created_at desc);
create index notifications_unread_idx on public.notifications (user_id) where read_at is null;
create index notifications_family_idx on public.notifications (family_id);

create table public.notification_queue (
  id               bigint generated always as identity primary key,
  notification_id  uuid not null unique references public.notifications (id) on delete cascade,
  user_id          uuid not null references public.profiles (id) on delete cascade,
  status           text not null default 'pending' check (status in ('pending', 'sending', 'sent', 'failed', 'skipped')),
  attempts         int not null default 0,
  last_error       text check (last_error is null or char_length(last_error) <= 500),
  next_attempt_at  timestamptz not null default now(),
  claimed_at       timestamptz,
  sent_at          timestamptz,
  created_at       timestamptz not null default now()
);
create index notification_queue_due_idx on public.notification_queue (status, next_attempt_at);
create index notification_queue_user_idx on public.notification_queue (user_id);

alter table public.notifications enable row level security;
alter table public.notification_queue enable row level security;
revoke all on public.notifications, public.notification_queue from anon, authenticated;

grant select on public.notifications to authenticated;
grant update (read_at) on public.notifications to authenticated;
create policy notifications_select_own on public.notifications for select to authenticated
  using (user_id = (select auth.uid()));
create policy notifications_update_own on public.notifications for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
-- notification_queue: no policies and no grants → only the service role.

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------
create or replace function private.in_quiet_hours(p_start time, p_end time, p_tz text)
returns boolean
language plpgsql
stable
set search_path = ''
as $$
declare v_local time;
begin
  if p_start is null or p_end is null or p_start = p_end then
    return false;
  end if;
  begin
    v_local := (now() at time zone p_tz)::time;
  exception when others then
    v_local := (now() at time zone 'Asia/Kuala_Lumpur')::time;
  end;
  if p_start < p_end then
    return v_local >= p_start and v_local < p_end;
  end if;
  return v_local >= p_start or v_local < p_end;  -- window crosses midnight
end;
$$;

-- p_texts: {"ms": {"title":…, "body":…, "preview":…}, "en": {…}}; "preview"
-- (optional) replaces "body" only for recipients who enabled previews.
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
      and private.family_role_of(p_family_id, u.uid) is not null
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

create or replace function private.display_name(p_user uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select display_name from public.profiles where id = p_user), 'FamilySync');
$$;
revoke all on function private.display_name(uuid) from public;

-- -----------------------------------------------------------------------------
-- Triggers
-- -----------------------------------------------------------------------------
create or replace function private.on_message_notify()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_conv public.conversations%rowtype;
  v_sender text := private.display_name(new.sender_id);
  v_snippet text;
  v_recipients uuid[];
  v_texts jsonb;
begin
  if new.kind = 'system' then
    return new;
  end if;
  select * into v_conv from public.conversations where id = new.conversation_id;
  select array_agg(user_id) into v_recipients from public.conversation_members
   where conversation_id = new.conversation_id and left_at is null and user_id is distinct from new.sender_id;
  v_snippet := case
    when new.body is not null then left(regexp_replace(new.body, '\s+', ' ', 'g'), 160)
    when new.kind = 'image' then '📷'
    else '📎' end;

  if v_conv.kind = 'direct' then
    v_texts := jsonb_build_object(
      'ms', jsonb_build_object('title', 'FamilySync', 'body', 'Mesej baharu daripada ' || v_sender,
                               'preview', v_sender || ': ' || v_snippet),
      'en', jsonb_build_object('title', 'FamilySync', 'body', 'New message from ' || v_sender,
                               'preview', v_sender || ': ' || v_snippet));
  else
    v_texts := jsonb_build_object(
      'ms', jsonb_build_object('title', 'FamilySync', 'body', 'Mesej baharu dalam ' || coalesce(v_conv.name, 'kumpulan'),
                               'preview', coalesce(v_conv.name, '') || ' · ' || v_sender || ': ' || v_snippet),
      'en', jsonb_build_object('title', 'FamilySync', 'body', 'New message in ' || coalesce(v_conv.name, 'a group'),
                               'preview', coalesce(v_conv.name, '') || ' · ' || v_sender || ': ' || v_snippet));
  end if;

  perform private.notify(
    v_recipients, new.family_id,
    case when v_conv.kind = 'direct' then 'private_message' else 'group_message' end,
    'msg:' || new.id, v_texts,
    jsonb_build_object('route', '/chat/' || new.conversation_id, 'tag', 'chat:' || new.conversation_id,
                       'channel', 'messages'),
    new.sender_id, new.conversation_id);
  return new;
end;
$$;

create trigger messages_notify after insert on public.messages
  for each row execute function private.on_message_notify();

create or replace function private.on_todo_assignment_notify()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_title text;
  v_actor text := private.display_name(new.assigned_by);
begin
  if new.user_id = new.assigned_by then
    return new;
  end if;
  select title into v_title from public.todo_items where id = new.item_id;
  perform private.notify(
    array[new.user_id], new.family_id, 'task_assigned', 'assign:' || new.item_id || ':' || new.user_id,
    jsonb_build_object(
      'ms', jsonb_build_object('title', 'Tugasan untuk anda', 'body', v_actor || ' menugaskan "' || v_title || '" kepada anda'),
      'en', jsonb_build_object('title', 'Task assigned to you', 'body', v_actor || ' assigned "' || v_title || '" to you')),
    jsonb_build_object('route', '/todo/' || new.list_id, 'channel', 'tasks'),
    new.assigned_by);
  return new;
end;
$$;

create trigger todo_assignments_notify after insert on public.todo_assignments
  for each row execute function private.on_todo_assignment_notify();

create or replace function private.on_todo_item_notify()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_list public.todo_lists%rowtype;
  v_recipients uuid[];
  v_actor uuid;
  v_name text;
begin
  select * into v_list from public.todo_lists where id = new.list_id;
  if tg_op = 'INSERT' then
    -- New task: list creator and (for members-only lists) list members.
    v_actor := new.created_by;
    v_recipients := array(
      select v_list.created_by
      union select m.user_id from public.todo_list_members m where m.list_id = new.list_id);
    v_name := private.display_name(v_actor);
    perform private.notify(
      v_recipients, new.family_id, 'task_created', 'new:' || new.id,
      jsonb_build_object(
        'ms', jsonb_build_object('title', v_list.name, 'body', v_name || ' menambah "' || new.title || '"'),
        'en', jsonb_build_object('title', v_list.name, 'body', v_name || ' added "' || new.title || '"')),
      jsonb_build_object('route', '/todo/' || new.list_id, 'tag', 'todo:' || new.list_id, 'channel', 'tasks'),
      v_actor);
  elsif new.status = 'completed' and old.status is distinct from 'completed' then
    v_actor := new.completed_by;
    v_recipients := array(
      select new.created_by
      union select a.user_id from public.todo_assignments a where a.item_id = new.id);
    v_name := private.display_name(v_actor);
    perform private.notify(
      v_recipients, new.family_id, 'task_completed', 'done:' || new.id || ':' || new.revision,
      jsonb_build_object(
        'ms', jsonb_build_object('title', v_list.name, 'body', v_name || ' menyiapkan "' || new.title || '"'),
        'en', jsonb_build_object('title', v_list.name, 'body', v_name || ' completed "' || new.title || '"')),
      jsonb_build_object('route', '/todo/' || new.list_id, 'tag', 'todo:' || new.list_id, 'channel', 'tasks'),
      v_actor);
  end if;
  return new;
end;
$$;

create trigger todo_items_notify_insert after insert on public.todo_items
  for each row execute function private.on_todo_item_notify();
create trigger todo_items_notify_complete after update of status on public.todo_items
  for each row execute function private.on_todo_item_notify();

create or replace function private.on_family_member_notify()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admins uuid[];
  v_family text;
  v_name text := private.display_name(new.user_id);
begin
  if new.role = 'owner' then
    return new;  -- family creator
  end if;
  if not ((tg_op = 'INSERT' and new.status in ('pending', 'active'))
          or (tg_op = 'UPDATE' and new.status in ('pending', 'active') and old.status not in ('pending', 'active'))) then
    return new;
  end if;
  select name into v_family from public.families where id = new.family_id;
  select array_agg(user_id) into v_admins from public.family_members
   where family_id = new.family_id and status = 'active' and role in ('owner', 'admin');
  if new.status = 'pending' then
    perform private.notify(
      v_admins, new.family_id, 'family_request',
      'req:' || new.family_id || ':' || new.user_id || ':' || extract(epoch from new.status_changed_at)::bigint,
      jsonb_build_object(
        'ms', jsonb_build_object('title', v_family, 'body', v_name || ' meminta untuk menyertai keluarga'),
        'en', jsonb_build_object('title', v_family, 'body', v_name || ' asked to join the family')),
      jsonb_build_object('route', '/family', 'channel', 'family'),
      new.user_id);
  else
    perform private.notify(
      v_admins, new.family_id, 'member_joined',
      'join:' || new.family_id || ':' || new.user_id || ':' || extract(epoch from new.status_changed_at)::bigint,
      jsonb_build_object(
        'ms', jsonb_build_object('title', v_family, 'body', v_name || ' telah menyertai keluarga'),
        'en', jsonb_build_object('title', v_family, 'body', v_name || ' joined the family')),
      jsonb_build_object('route', '/family', 'channel', 'family'),
      new.user_id);
  end if;
  return new;
end;
$$;

create trigger family_members_notify after insert or update of status on public.family_members
  for each row execute function private.on_family_member_notify();

-- -----------------------------------------------------------------------------
-- Client RPCs
-- -----------------------------------------------------------------------------
-- Important family announcement (owner/admin) → every active member.
create or replace function public.post_announcement(p_family_id uuid, p_title text, p_body text)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_title text := btrim(coalesce(p_title, ''));
  v_body text := btrim(coalesce(p_body, ''));
  v_members uuid[];
  v_id uuid := gen_random_uuid();
begin
  if not private.has_family_role(p_family_id, array['owner', 'admin']::public.family_role[]) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if char_length(v_title) not between 1 and 120 or char_length(v_body) not between 1 and 300 then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  perform private.enforce_rate_limit('post_announcement', 10, interval '1 day');
  select array_agg(user_id) into v_members from public.family_members
   where family_id = p_family_id and status = 'active';
  perform private.audit(p_family_id, 'family.announcement', 'announcement', v_id,
    jsonb_build_object('title', v_title, 'body', v_body), 'members');
  return private.notify(
    v_members, p_family_id, 'announcement', 'ann:' || v_id,
    jsonb_build_object('ms', jsonb_build_object('title', v_title, 'body', v_body),
                       'en', jsonb_build_object('title', v_title, 'body', v_body)),
    jsonb_build_object('route', '/home', 'channel', 'family'),
    v_uid);
end;
$$;

create or replace function public.mark_notifications_read(p_ids uuid[] default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare v_count int;
begin
  update public.notifications set read_at = now()
   where user_id = private.require_uid() and read_at is null
     and (p_ids is null or id = any (p_ids));
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.post_announcement(uuid, text, text) from public, anon;
revoke all on function public.mark_notifications_read(uuid[]) from public, anon;
grant execute on function public.post_announcement(uuid, text, text) to authenticated;
grant execute on function public.mark_notifications_read(uuid[]) to authenticated;

-- -----------------------------------------------------------------------------
-- Service-role RPCs used by the send-push Edge Function
-- -----------------------------------------------------------------------------
-- Claims due queue rows (pending, or stuck in 'sending' > 5 min) with
-- SKIP LOCKED so concurrent workers never send the same notification twice.
create or replace function public.claim_push_batch(p_limit int default 100)
returns table (queue_id bigint, notification_id uuid, user_id uuid, type text, title text, body text,
               data jsonb, attempts int, tokens text[])
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  with due as (
    select q.id from public.notification_queue q
    where (q.status = 'pending' and q.next_attempt_at <= now())
       or (q.status = 'sending' and q.claimed_at < now() - interval '5 minutes')
    order by q.id
    limit greatest(1, least(coalesce(p_limit, 100), 500))
    for update skip locked
  ), claimed as (
    update public.notification_queue q
       set status = 'sending', attempts = q.attempts + 1, claimed_at = now()
      from due where q.id = due.id
    returning q.id, q.notification_id, q.user_id, q.attempts
  )
  select c.id, c.notification_id, c.user_id, n.type, n.title, n.body, n.data, c.attempts,
         coalesce((select array_agg(d.token) from public.device_tokens d where d.user_id = c.user_id), '{}')
  from claimed c join public.notifications n on n.id = c.notification_id;
end;
$$;

-- Records the outcome. Failed sends retry with exponential backoff (2^n min)
-- up to 5 attempts. Tokens FCM reported as unregistered are deleted.
create or replace function public.complete_push(
  p_queue_id bigint, p_success boolean, p_error text default null, p_invalid_tokens text[] default '{}')
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_attempts int;
begin
  if coalesce(array_length(p_invalid_tokens, 1), 0) > 0 then
    delete from public.device_tokens where token = any (p_invalid_tokens);
  end if;
  select attempts into v_attempts from public.notification_queue where id = p_queue_id for update;
  if p_success then
    update public.notification_queue set status = 'sent', sent_at = now(), last_error = null where id = p_queue_id;
  elsif v_attempts >= 5 then
    update public.notification_queue set status = 'failed', last_error = left(p_error, 500) where id = p_queue_id;
  else
    update public.notification_queue
       set status = 'pending', last_error = left(p_error, 500),
           next_attempt_at = now() + make_interval(mins => power(2, v_attempts)::int)
     where id = p_queue_id;
  end if;
end;
$$;

revoke all on function public.claim_push_batch(int) from public, anon, authenticated;
revoke all on function public.complete_push(bigint, boolean, text, text[]) from public, anon, authenticated;
grant execute on function public.claim_push_batch(int) to service_role;
grant execute on function public.complete_push(bigint, boolean, text, text[]) to service_role;
grant select, update on public.notification_queue to service_role;
grant select on public.notifications to service_role;

-- In-app inbox updates live.
alter publication supabase_realtime add table public.notifications;
