-- =============================================================================
-- FamilySync — Migration 20261123000200: Private & group chat (Phase 3)
--
-- Tables: conversations, conversation_members, messages, message_attachments,
--         message_receipts
--
-- Design
--   * Direct conversations are unique per (family, user pair): direct_key =
--     family_id:least(uid):greatest(uid) with a UNIQUE constraint, so concurrent
--     "start chat" taps can never create duplicates.
--   * Messages use client-generated UUIDs: send_message is idempotent, so a
--     retry after a lost response never duplicates a message. A message is only
--     "sent" once this function has committed it.
--   * Read/delivery receipts are per-member cursors (message_receipts), not one
--     row per message, so they stay cheap for 100+ member groups.
--   * Access requires active membership of BOTH the family and the
--     conversation (private.is_conversation_member).
--   * Typing (Broadcast) and online status (Presence) use PRIVATE Realtime
--     channels authorised by RLS on realtime.messages.
-- =============================================================================

create type public.conversation_kind as enum ('direct', 'group');
create type public.message_kind as enum ('text', 'image', 'file', 'system');

create table public.conversations (
  id                      uuid primary key,
  family_id               uuid not null references public.families (id) on delete cascade,
  kind                    public.conversation_kind not null,
  name                    text check (name is null or char_length(btrim(name)) between 1 and 80),
  description             text check (description is null or char_length(description) <= 500),
  image_path              text check (image_path is null or char_length(image_path) <= 512),
  direct_key              text unique,
  created_by              uuid references public.profiles (id) on delete set null,
  last_message_at         timestamptz,
  last_message_preview    text check (last_message_preview is null or char_length(last_message_preview) <= 160),
  last_message_sender_id  uuid references public.profiles (id) on delete set null,
  revision                int not null default 1,
  deleted_at              timestamptz,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  check ((kind = 'group' and name is not null and direct_key is null)
      or (kind = 'direct' and direct_key is not null))
);
create index conversations_family_idx on public.conversations (family_id, last_message_at desc nulls last);
create index conversations_created_by_idx on public.conversations (created_by);
create index conversations_last_sender_idx on public.conversations (last_message_sender_id);
create trigger conversations_set_updated_at before update on public.conversations
  for each row execute function private.set_updated_at();

create table public.conversation_members (
  conversation_id  uuid not null references public.conversations (id) on delete cascade,
  user_id          uuid not null references public.profiles (id) on delete cascade,
  family_id        uuid not null references public.families (id) on delete cascade,
  role             text not null default 'member' check (role in ('admin', 'member')),
  joined_at        timestamptz not null default now(),
  left_at          timestamptz,
  muted_until      timestamptz,
  pinned_at        timestamptz,
  added_by         uuid references public.profiles (id) on delete set null,
  primary key (conversation_id, user_id)
);
create index conversation_members_user_idx on public.conversation_members (user_id) where left_at is null;
create index conversation_members_family_idx on public.conversation_members (family_id);
create index conversation_members_added_by_idx on public.conversation_members (added_by);

create table public.messages (
  id               uuid primary key,  -- client-generated: idempotent send
  conversation_id  uuid not null references public.conversations (id) on delete cascade,
  family_id        uuid not null references public.families (id) on delete cascade,
  sender_id        uuid references public.profiles (id) on delete set null,
  kind             public.message_kind not null default 'text',
  body             text check (body is null or char_length(body) <= 4000),
  meta             jsonb,
  reply_to_id      uuid references public.messages (id) on delete set null,
  edited_at        timestamptz,
  deleted_at       timestamptz,
  deleted_by       uuid references public.profiles (id) on delete set null,
  pinned_at        timestamptz,
  pinned_by        uuid references public.profiles (id) on delete set null,
  created_at       timestamptz not null default clock_timestamp()
);
create index messages_conversation_idx on public.messages (conversation_id, created_at desc, id desc);
create index messages_family_idx on public.messages (family_id, created_at desc);
create index messages_sender_idx on public.messages (sender_id);
create index messages_reply_idx on public.messages (reply_to_id);
create index messages_deleted_by_idx on public.messages (deleted_by);
create index messages_pinned_by_idx on public.messages (pinned_by);
create index messages_pinned_idx on public.messages (conversation_id, pinned_at) where pinned_at is not null;

create table public.message_attachments (
  id               uuid primary key default gen_random_uuid(),
  message_id       uuid not null references public.messages (id) on delete cascade,
  conversation_id  uuid not null references public.conversations (id) on delete cascade,
  family_id        uuid not null references public.families (id) on delete cascade,
  storage_path     text not null unique check (char_length(storage_path) <= 512),
  mime_type        text not null check (char_length(mime_type) <= 120),
  size_bytes       int not null check (size_bytes between 1 and 10485760),
  file_name        text not null check (char_length(file_name) between 1 and 200),
  width            int check (width is null or width > 0),
  height           int check (height is null or height > 0),
  created_at       timestamptz not null default now()
);
create index message_attachments_message_idx on public.message_attachments (message_id);
create index message_attachments_conversation_idx on public.message_attachments (conversation_id);
create index message_attachments_family_idx on public.message_attachments (family_id);

-- One row per (conversation, member): how far that member has received / read.
create table public.message_receipts (
  conversation_id    uuid not null references public.conversations (id) on delete cascade,
  user_id            uuid not null references public.profiles (id) on delete cascade,
  family_id          uuid not null references public.families (id) on delete cascade,
  last_delivered_at  timestamptz,
  last_read_at       timestamptz,
  updated_at         timestamptz not null default now(),
  primary key (conversation_id, user_id)
);
create index message_receipts_user_idx on public.message_receipts (user_id);
create index message_receipts_family_idx on public.message_receipts (family_id);
create trigger message_receipts_set_updated_at before update on public.message_receipts
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- Access helpers
-- -----------------------------------------------------------------------------
create or replace function private.is_conversation_member(p_conversation_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.conversation_members cm
    join public.conversations c on c.id = cm.conversation_id and c.deleted_at is null
    where cm.conversation_id = p_conversation_id
      and cm.user_id = (select auth.uid())
      and cm.left_at is null
      and private.is_family_member(c.family_id)
  );
$$;

-- Group admins, or family owner/admin/moderator ("moderate permitted content").
create or replace function private.can_moderate_conversation(p_conversation_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_conversation_member(p_conversation_id) and (
    exists (select 1 from public.conversation_members cm
            where cm.conversation_id = p_conversation_id and cm.user_id = (select auth.uid())
              and cm.left_at is null and cm.role = 'admin')
    or exists (select 1 from public.conversations c
               where c.id = p_conversation_id
                 and private.has_family_role(c.family_id,
                       array['owner', 'admin', 'moderator']::public.family_role[]))
  );
$$;

-- Parses the uuid after the last ':' of a Realtime topic (null if invalid).
create or replace function private.topic_uuid(p_topic text)
returns uuid
language plpgsql
immutable
set search_path = ''
as $$
declare v text := split_part(coalesce(p_topic, ''), ':', array_length(string_to_array(coalesce(p_topic, ''), ':'), 1));
begin
  if v ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    return v::uuid;
  end if;
  return null;
end;
$$;

revoke all on function private.is_conversation_member(uuid) from public;
revoke all on function private.can_moderate_conversation(uuid) from public;
grant execute on function private.is_conversation_member(uuid) to authenticated;
grant execute on function private.can_moderate_conversation(uuid) to authenticated;
grant execute on function private.topic_uuid(text) to authenticated;

-- =============================================================================
-- RLS (reads only; every write goes through an RPC, except a member's own
-- mute/pin preferences)
-- =============================================================================
alter table public.conversations         enable row level security;
alter table public.conversation_members  enable row level security;
alter table public.messages              enable row level security;
alter table public.message_attachments   enable row level security;
alter table public.message_receipts      enable row level security;

revoke all on public.conversations, public.conversation_members, public.messages,
  public.message_attachments, public.message_receipts from anon, authenticated;

grant select on public.conversations to authenticated;
create policy conversations_select on public.conversations for select to authenticated
  using ((select private.is_conversation_member(id)));

grant select on public.conversation_members to authenticated;
grant update (muted_until, pinned_at) on public.conversation_members to authenticated;
create policy conversation_members_select on public.conversation_members for select to authenticated
  using ((select private.is_conversation_member(conversation_id)));
create policy conversation_members_update_own on public.conversation_members for update to authenticated
  using (user_id = (select auth.uid()) and left_at is null)
  with check (user_id = (select auth.uid()));

-- Soft-deleted messages stay readable (body is cleared) so Realtime delivers
-- the deletion to every open chat.
grant select on public.messages to authenticated;
create policy messages_select on public.messages for select to authenticated
  using ((select private.is_conversation_member(conversation_id)));

grant select on public.message_attachments to authenticated;
create policy message_attachments_select on public.message_attachments for select to authenticated
  using ((select private.is_conversation_member(conversation_id)));

grant select on public.message_receipts to authenticated;
create policy message_receipts_select on public.message_receipts for select to authenticated
  using ((select private.is_conversation_member(conversation_id)));

-- =============================================================================
-- RPCs
-- =============================================================================
create or replace function private.add_member_rows(
  p_conversation_id uuid, p_family_id uuid, p_user_ids uuid[], p_role text, p_added_by uuid)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare v_count int;
begin
  if exists (select 1 from unnest(coalesce(p_user_ids, '{}')) u(uid)
             where private.family_role_of(p_family_id, u.uid) is null) then
    raise exception 'member_not_found' using errcode = 'P0002';
  end if;
  with ins as (
    insert into public.conversation_members (conversation_id, user_id, family_id, role, added_by)
    select p_conversation_id, u, p_family_id, p_role, p_added_by
    from (select distinct unnest(coalesce(p_user_ids, '{}')) u) x
    on conflict (conversation_id, user_id) do update
      set left_at = null, joined_at = case when public.conversation_members.left_at is null
                                           then public.conversation_members.joined_at else now() end
    where public.conversation_members.left_at is not null
    returning 1
  )
  select count(*) into v_count from ins;
  insert into public.message_receipts (conversation_id, user_id, family_id)
  select p_conversation_id, u, p_family_id from (select distinct unnest(coalesce(p_user_ids, '{}')) u) x
  on conflict do nothing;
  return v_count;
end;
$$;
revoke all on function private.add_member_rows(uuid, uuid, uuid[], text, uuid) from public;

-- System message inside a conversation (member added/removed, renamed …).
create or replace function private.system_message(p_conversation_id uuid, p_event text, p_meta jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_family uuid;
begin
  select family_id into v_family from public.conversations where id = p_conversation_id;
  insert into public.messages (id, conversation_id, family_id, sender_id, kind, body, meta)
  values (gen_random_uuid(), p_conversation_id, v_family, auth.uid(), 'system', p_event, coalesce(p_meta, '{}'::jsonb));
end;
$$;
revoke all on function private.system_message(uuid, text, jsonb) from public;

-- ---------------------------------------------------------------------------
create or replace function public.get_or_create_direct_conversation(p_family_id uuid, p_other_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_key text;
  v_id uuid;
begin
  if p_other_user_id is null or p_other_user_id = v_uid then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  if private.family_role_of(p_family_id, v_uid) is null or private.family_role_of(p_family_id, p_other_user_id) is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_key := p_family_id::text || ':' || least(v_uid, p_other_user_id)::text || ':' || greatest(v_uid, p_other_user_id)::text;

  insert into public.conversations (id, family_id, kind, direct_key, created_by)
  values (gen_random_uuid(), p_family_id, 'direct', v_key, v_uid)
  on conflict (direct_key) do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from public.conversations where direct_key = v_key;
  else
    perform private.enforce_rate_limit('create_conversation', 100, interval '1 hour');
  end if;
  perform private.add_member_rows(v_id, p_family_id, array[v_uid, p_other_user_id], 'member', v_uid);
  return v_id;
end;
$$;

create or replace function public.create_group_conversation(
  p_id uuid, p_family_id uuid, p_name text, p_description text default null, p_member_ids uuid[] default '{}')
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_existing public.conversations%rowtype;
begin
  if p_id is null or coalesce(btrim(p_name), '') = '' then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  select * into v_existing from public.conversations where id = p_id;
  if v_existing.id is not null then
    if v_existing.created_by = v_uid then return v_existing.id; end if;  -- idempotent replay
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if private.family_role_of(p_family_id, v_uid) is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform private.enforce_rate_limit('create_conversation', 100, interval '1 hour');
  insert into public.conversations (id, family_id, kind, name, description, created_by)
  values (p_id, p_family_id, 'group', btrim(p_name), nullif(btrim(p_description), ''), v_uid);
  perform private.add_member_rows(p_id, p_family_id, array[v_uid], 'admin', v_uid);
  perform private.add_member_rows(p_id, p_family_id,
    array(select u from unnest(coalesce(p_member_ids, '{}')) u where u <> v_uid), 'member', v_uid);
  perform private.system_message(p_id, 'group_created', jsonb_build_object('name', btrim(p_name)));
  return p_id;
end;
$$;

create or replace function public.update_group_conversation(
  p_id uuid, p_name text, p_description text default null, p_image_path text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_conv public.conversations%rowtype;
begin
  perform private.require_uid();
  select * into v_conv from public.conversations where id = p_id for update;
  if v_conv.kind is distinct from 'group' or not private.can_moderate_conversation(p_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if coalesce(btrim(p_name), '') = '' then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  if p_image_path is not null and p_image_path not like (p_id::text || '/%') then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  update public.conversations
     set name = btrim(p_name), description = nullif(btrim(p_description), ''),
         image_path = coalesce(p_image_path, image_path), revision = revision + 1
   where id = p_id;
  if v_conv.name is distinct from btrim(p_name) then
    perform private.system_message(p_id, 'group_renamed', jsonb_build_object('name', btrim(p_name)));
  end if;
end;
$$;

create or replace function public.add_conversation_members(p_id uuid, p_user_ids uuid[])
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_conv public.conversations%rowtype;
  v_added int;
begin
  perform private.require_uid();
  select * into v_conv from public.conversations where id = p_id for update;
  if v_conv.kind is distinct from 'group' or not private.can_moderate_conversation(p_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_added := private.add_member_rows(p_id, v_conv.family_id, p_user_ids, 'member', auth.uid());
  if v_added > 0 then
    perform private.system_message(p_id, 'members_added', jsonb_build_object('user_ids', to_jsonb(p_user_ids)));
  end if;
  return v_added;
end;
$$;

-- Ensures a group always has at least one admin after someone leaves.
create or replace function private.ensure_group_admin(p_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.conversation_members set role = 'admin'
  where conversation_id = p_id
    and user_id = (select user_id from public.conversation_members
                   where conversation_id = p_id and left_at is null order by joined_at limit 1)
    and not exists (select 1 from public.conversation_members
                    where conversation_id = p_id and left_at is null and role = 'admin');
$$;
revoke all on function private.ensure_group_admin(uuid) from public;

create or replace function public.remove_conversation_member(p_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_conv public.conversations%rowtype;
begin
  perform private.require_uid();
  select * into v_conv from public.conversations where id = p_id for update;
  if v_conv.kind is distinct from 'group' or not private.can_moderate_conversation(p_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_user_id = auth.uid() then
    raise exception 'cannot_manage_self' using errcode = '42501';
  end if;
  update public.conversation_members set left_at = now(), role = 'member'
   where conversation_id = p_id and user_id = p_user_id and left_at is null;
  if found then
    perform private.ensure_group_admin(p_id);
    perform private.system_message(p_id, 'member_removed', jsonb_build_object('user_id', p_user_id));
  end if;
end;
$$;

create or replace function public.leave_conversation(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_conv public.conversations%rowtype;
begin
  perform private.require_uid();
  select * into v_conv from public.conversations where id = p_id for update;
  if v_conv.kind is distinct from 'group' or not private.is_conversation_member(p_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.conversation_members set left_at = now(), role = 'member'
   where conversation_id = p_id and user_id = auth.uid() and left_at is null;
  perform private.ensure_group_admin(p_id);
  perform private.system_message(p_id, 'member_left', '{}'::jsonb);
end;
$$;

create or replace function public.set_conversation_member_role(p_id uuid, p_user_id uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_uid();
  if p_role not in ('admin', 'member') then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  if not exists (select 1 from public.conversations where id = p_id and kind = 'group')
     or not private.can_moderate_conversation(p_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.conversation_members set role = p_role
   where conversation_id = p_id and user_id = p_user_id and left_at is null;
  if not found then
    raise exception 'member_not_found' using errcode = 'P0002';
  end if;
  perform private.ensure_group_admin(p_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- send_message: idempotent on p_id. p_attachments is a JSON array of
-- {path, mime_type, size_bytes, file_name, width?, height?}; every path must be
-- an object already uploaded under chat-attachments/{conversation}/{message}/.
-- ---------------------------------------------------------------------------
create or replace function private.allowed_attachment_mime(p_mime text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_mime = any (array[
    'image/jpeg', 'image/png', 'image/webp', 'image/gif',
    'application/pdf', 'text/plain',
    'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'application/vnd.ms-powerpoint', 'application/vnd.openxmlformats-officedocument.presentationml.presentation']);
$$;

create or replace function public.send_message(
  p_id uuid,
  p_conversation_id uuid,
  p_body text default null,
  p_reply_to_id uuid default null,
  p_attachments jsonb default '[]'::jsonb)
returns public.messages
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_msg public.messages%rowtype;
  v_conv public.conversations%rowtype;
  v_body text := nullif(btrim(coalesce(p_body, '')), '');
  v_att jsonb := coalesce(p_attachments, '[]'::jsonb);
  v_count int;
  v_kind public.message_kind := 'text';
  v_preview text;
  a jsonb;
begin
  if p_id is null then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  select * into v_msg from public.messages where id = p_id;
  if v_msg.id is not null then
    if v_msg.sender_id = v_uid and v_msg.conversation_id = p_conversation_id then
      return v_msg;  -- idempotent retry: already stored
    end if;
    raise exception 'forbidden' using errcode = '42501';
  end if;

  if not private.is_conversation_member(p_conversation_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if jsonb_typeof(v_att) <> 'array' or jsonb_array_length(v_att) > 10 then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  v_count := jsonb_array_length(v_att);
  if v_body is null and v_count = 0 then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  if v_body is not null and char_length(v_body) > 4000 then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  if p_reply_to_id is not null and not exists (
       select 1 from public.messages where id = p_reply_to_id and conversation_id = p_conversation_id) then
    raise exception 'invalid_input' using errcode = '22023';
  end if;

  for a in select * from jsonb_array_elements(v_att) loop
    if (a ->> 'path') is null
       or (a ->> 'path') not like (p_conversation_id::text || '/' || p_id::text || '/%')
       or not private.allowed_attachment_mime(a ->> 'mime_type')
       or coalesce((a ->> 'size_bytes')::bigint, 0) not between 1 and 10485760
       or coalesce(btrim(a ->> 'file_name'), '') = ''
       or not exists (select 1 from storage.objects o
                      where o.bucket_id = 'chat-attachments' and o.name = (a ->> 'path')) then
      raise exception 'invalid_attachment' using errcode = '22023';
    end if;
  end loop;

  perform private.enforce_rate_limit('send_message', 60, interval '1 minute');

  if v_count > 0 then
    v_kind := case when not exists (select 1 from jsonb_array_elements(v_att) x
                                    where (x ->> 'mime_type') not like 'image/%')
                   then 'image' else 'file' end;
  end if;

  select * into v_conv from public.conversations where id = p_conversation_id for update;

  insert into public.messages (id, conversation_id, family_id, sender_id, kind, body, reply_to_id)
  values (p_id, p_conversation_id, v_conv.family_id, v_uid, v_kind, v_body, p_reply_to_id)
  returning * into v_msg;

  insert into public.message_attachments (message_id, conversation_id, family_id, storage_path, mime_type,
                                          size_bytes, file_name, width, height)
  select p_id, p_conversation_id, v_conv.family_id, x ->> 'path', x ->> 'mime_type', (x ->> 'size_bytes')::int,
         left(btrim(x ->> 'file_name'), 200), nullif(x ->> 'width', '')::int, nullif(x ->> 'height', '')::int
  from jsonb_array_elements(v_att) x;

  v_preview := case
    when v_body is not null then left(regexp_replace(v_body, '\s+', ' ', 'g'), 140)
    when v_kind = 'image' then '📷'
    else '📎 ' || left(v_att -> 0 ->> 'file_name', 120)
  end;
  update public.conversations
     set last_message_at = v_msg.created_at, last_message_preview = v_preview,
         last_message_sender_id = v_uid, revision = revision + 1
   where id = p_conversation_id;

  insert into public.message_receipts (conversation_id, user_id, family_id, last_delivered_at, last_read_at)
  values (p_conversation_id, v_uid, v_conv.family_id, v_msg.created_at, v_msg.created_at)
  on conflict (conversation_id, user_id) do update
    set last_delivered_at = greatest(public.message_receipts.last_delivered_at, excluded.last_delivered_at),
        last_read_at = greatest(public.message_receipts.last_read_at, excluded.last_read_at);
  return v_msg;
end;
$$;

create or replace function public.edit_message(p_id uuid, p_body text)
returns public.messages
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_msg public.messages%rowtype;
  v_body text := nullif(btrim(coalesce(p_body, '')), '');
begin
  select * into v_msg from public.messages where id = p_id for update;
  if v_msg.id is null or v_msg.sender_id is distinct from v_uid or v_msg.deleted_at is not null
     or v_msg.kind = 'system' or not private.is_conversation_member(v_msg.conversation_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if (v_body is null and v_msg.kind = 'text') or char_length(coalesce(v_body, '')) > 4000 then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  if v_body is not distinct from v_msg.body then
    return v_msg;
  end if;
  update public.messages set body = v_body, edited_at = now() where id = p_id returning * into v_msg;
  update public.conversations set last_message_preview = left(regexp_replace(coalesce(v_body, ''), '\s+', ' ', 'g'), 140),
                                  revision = revision + 1
   where id = v_msg.conversation_id and last_message_at = v_msg.created_at and v_body is not null;
  return v_msg;
end;
$$;

-- Own messages, or moderators (group admin / family moderator+).
create or replace function public.delete_message(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_msg public.messages%rowtype;
begin
  select * into v_msg from public.messages where id = p_id for update;
  if v_msg.id is null or not private.is_conversation_member(v_msg.conversation_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_msg.deleted_at is not null then
    return;  -- idempotent
  end if;
  if not (v_msg.sender_id = v_uid or private.can_moderate_conversation(v_msg.conversation_id)) or v_msg.kind = 'system' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.messages
     set body = null, meta = null, deleted_at = now(), deleted_by = v_uid, pinned_at = null, pinned_by = null
   where id = p_id;
  -- Attachment rows go away, which also revokes Storage read access to them.
  delete from public.message_attachments where message_id = p_id;
  update public.conversations set last_message_preview = null, revision = revision + 1
   where id = v_msg.conversation_id and last_message_at = v_msg.created_at;
end;
$$;

-- Direct chats: either participant. Groups: moderators only.
create or replace function public.set_message_pinned(p_id uuid, p_pinned boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_msg public.messages%rowtype;
  v_kind public.conversation_kind;
begin
  select * into v_msg from public.messages where id = p_id for update;
  if v_msg.id is null or v_msg.deleted_at is not null or v_msg.kind = 'system'
     or not private.is_conversation_member(v_msg.conversation_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select kind into v_kind from public.conversations where id = v_msg.conversation_id;
  if v_kind = 'group' and not private.can_moderate_conversation(v_msg.conversation_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_pinned = (v_msg.pinned_at is not null) then
    return;  -- idempotent
  end if;
  update public.messages
     set pinned_at = case when p_pinned then now() end, pinned_by = case when p_pinned then v_uid end
   where id = p_id;
end;
$$;

-- Monotonic read cursor (never moves backwards; capped at now()).
create or replace function public.mark_conversation_read(p_conversation_id uuid, p_up_to timestamptz default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  -- clock_timestamp(), not now(): the cursor must cover messages committed
  -- earlier in the same transaction too.
  v_at timestamptz := least(coalesce(p_up_to, clock_timestamp()), clock_timestamp());
begin
  if not private.is_conversation_member(p_conversation_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  insert into public.message_receipts (conversation_id, user_id, family_id, last_delivered_at, last_read_at)
  select p_conversation_id, v_uid, c.family_id, v_at, v_at from public.conversations c where c.id = p_conversation_id
  on conflict (conversation_id, user_id) do update
    set last_read_at = greatest(coalesce(public.message_receipts.last_read_at, '-infinity'), excluded.last_read_at),
        last_delivered_at = greatest(coalesce(public.message_receipts.last_delivered_at, '-infinity'), excluded.last_delivered_at)
    where public.message_receipts.last_read_at is null or public.message_receipts.last_read_at < excluded.last_read_at;
end;
$$;

-- Marks every conversation of the family as delivered up to now (app opened).
create or replace function public.mark_family_delivered(p_family_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_uid uuid := private.require_uid();
begin
  update public.message_receipts r
     set last_delivered_at = clock_timestamp()
   where r.user_id = v_uid and r.family_id = p_family_id
     and private.is_conversation_member(r.conversation_id)
     and exists (select 1 from public.conversations c
                 where c.id = r.conversation_id
                   and c.last_message_at > coalesce(r.last_delivered_at, '-infinity'));
end;
$$;

-- ---------------------------------------------------------------------------
-- Read models (SECURITY INVOKER: RLS applies)
-- ---------------------------------------------------------------------------
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
         (select count(*)::int from public.messages msg
           where msg.conversation_id = c.id and msg.deleted_at is null and msg.kind <> 'system'
             and msg.sender_id is distinct from me.user_id
             and msg.created_at > coalesce(r.last_read_at, me.joined_at - interval '1 second'))
  from public.conversations c
  join public.conversation_members me on me.conversation_id = c.id and me.user_id = auth.uid() and me.left_at is null
  left join public.message_receipts r on r.conversation_id = c.id and r.user_id = me.user_id
  where c.family_id = p_family_id and c.deleted_at is null
  order by me.pinned_at desc nulls last, coalesce(c.last_message_at, c.created_at) desc;
$$;

create or replace function public.search_messages(p_family_id uuid, p_query text)
returns table (id uuid, conversation_id uuid, sender_id uuid, body text, created_at timestamptz)
language sql
stable
security invoker
set search_path = ''
as $$
  select m.id, m.conversation_id, m.sender_id, m.body, m.created_at
  from public.messages m
  where m.family_id = p_family_id and m.deleted_at is null and m.kind <> 'system'
    and char_length(btrim(coalesce(p_query, ''))) >= 2
    and m.body ilike '%' || replace(replace(replace(btrim(p_query), '\', '\\'), '%', '\%'), '_', '\_') || '%'
  order by m.created_at desc
  limit 50;
$$;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('get_or_create_direct_conversation', 'create_group_conversation', 'update_group_conversation',
                        'add_conversation_members', 'remove_conversation_member', 'leave_conversation',
                        'set_conversation_member_role', 'send_message', 'edit_message', 'delete_message',
                        'set_message_pinned', 'mark_conversation_read', 'mark_family_delivered',
                        'conversation_summaries', 'search_messages')
  loop
    execute format('revoke all on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated', r.sig);
  end loop;
end;
$$;

-- =============================================================================
-- Storage: chat-attachments/{conversation_id}/{message_id}/{file}
-- =============================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat-attachments', 'chat-attachments', false, 10 * 1024 * 1024, array[
  'image/jpeg', 'image/png', 'image/webp', 'image/gif', 'application/pdf', 'text/plain',
  'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.ms-powerpoint', 'application/vnd.openxmlformats-officedocument.presentationml.presentation'])
on conflict (id) do update
  set public = excluded.public, file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Upload: any conversation member, into that conversation's folder.
create policy "chat-attachments: members upload"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'chat-attachments' and (select private.is_conversation_member(private.path_uuid(name))));

-- Read: members, and only while the attachment is part of a (non-deleted)
-- message, or the uploader before sending.
create policy "chat-attachments: members read"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'chat-attachments'
    and (select private.is_conversation_member(private.path_uuid(name)))
    and (owner = (select auth.uid())
         or exists (select 1 from public.message_attachments a where a.storage_path = name))
  );

-- Uploader may delete an object that was never attached (abandoned upload).
create policy "chat-attachments: uploader deletes unsent"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'chat-attachments' and owner = (select auth.uid())
    and not exists (select 1 from public.message_attachments a where a.storage_path = name)
  );

-- =============================================================================
-- Realtime
--   * Postgres Changes (RLS-aware) for persistent data.
--   * Private channels: Broadcast (typing) and Presence (online). Joining and
--     sending on them is authorised by these policies on realtime.messages.
--       conversation:{conversation_id}      -> conversation members
--       presence:family:{family_id}         -> active family members
-- =============================================================================
alter publication supabase_realtime add table public.conversations;
alter publication supabase_realtime add table public.messages;
alter publication supabase_realtime add table public.message_receipts;
alter publication supabase_realtime add table public.conversation_members;

create policy "familysync: receive on own channels"
  on realtime.messages for select to authenticated
  using (
    (realtime.topic() like 'conversation:%'
       and (select private.is_conversation_member(private.topic_uuid(realtime.topic()))))
    or (realtime.topic() like 'presence:family:%'
       and (select private.is_family_member(private.topic_uuid(realtime.topic()))))
  );

create policy "familysync: send on own channels"
  on realtime.messages for insert to authenticated
  with check (
    extension in ('broadcast', 'presence') and (
      (realtime.topic() like 'conversation:%'
         and (select private.is_conversation_member(private.topic_uuid(realtime.topic()))))
      or (realtime.topic() like 'presence:family:%'
         and (select private.is_family_member(private.topic_uuid(realtime.topic()))))
    )
  );
