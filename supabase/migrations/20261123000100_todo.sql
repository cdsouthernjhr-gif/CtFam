-- =============================================================================
-- FamilySync — Migration 20261123000100: Shared To-Do (Phase 2)
--
-- Tables: todo_categories, todo_lists, todo_list_members, todo_items,
--         todo_assignments, todo_comments, todo_activity_logs
--
-- Design
--   * Every row carries family_id so RLS and Realtime filters are cheap.
--   * A list is visible to the whole family (visibility = 'family') or only to
--     its creator, its explicit members and family owner/admin
--     (visibility = 'members').
--   * All item writes go through SECURITY DEFINER RPCs:
--       - upsert_todo_item: idempotent create (client-generated UUID) and
--         optimistic-concurrency update (expected revision).
--       - set_todo_item_status: idempotent "set completed = true/false"
--         (never a blind toggle). Completing a recurring item creates the next
--         occurrence exactly once.
--   * Every mutation increments `revision`, which clients use to discard stale
--     Realtime events and to detect conflicting edits.
-- =============================================================================

create type public.todo_priority as enum ('low', 'normal', 'high', 'urgent');
create type public.todo_status as enum ('open', 'completed');
create type public.todo_recurrence as enum ('none', 'daily', 'weekly', 'monthly', 'yearly');

-- -----------------------------------------------------------------------------
-- todo_categories (custom categories; built-in ones are fixed keys)
-- -----------------------------------------------------------------------------
create table public.todo_categories (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references public.families (id) on delete cascade,
  name        text not null check (char_length(btrim(name)) between 1 and 40),
  icon        text check (icon is null or char_length(icon) <= 40),
  color       text check (color is null or color ~ '^#[0-9A-Fa-f]{6}$'),
  created_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index todo_categories_family_name_uq on public.todo_categories (family_id, lower(btrim(name)));
create index todo_categories_created_by_idx on public.todo_categories (created_by);
create trigger todo_categories_set_updated_at before update on public.todo_categories
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- todo_lists
-- -----------------------------------------------------------------------------
create table public.todo_lists (
  id                  uuid primary key,  -- client-generated for idempotent creation
  family_id           uuid not null references public.families (id) on delete cascade,
  name                text not null check (char_length(btrim(name)) between 1 and 80),
  description         text check (description is null or char_length(description) <= 500),
  category            text not null default 'personal' check (category in
                        ('shopping', 'grocery', 'household', 'school', 'family_activities',
                         'bills', 'travel', 'personal', 'custom')),
  custom_category_id  uuid references public.todo_categories (id) on delete set null,
  visibility          text not null default 'family' check (visibility in ('family', 'members')),
  created_by          uuid references public.profiles (id) on delete set null,
  revision            int not null default 1,
  deleted_at          timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check (category <> 'custom' or custom_category_id is not null)
);
create index todo_lists_family_idx on public.todo_lists (family_id, created_at desc) where deleted_at is null;
create index todo_lists_created_by_idx on public.todo_lists (created_by);
create index todo_lists_custom_category_idx on public.todo_lists (custom_category_id);
create trigger todo_lists_set_updated_at before update on public.todo_lists
  for each row execute function private.set_updated_at();

create table public.todo_list_members (
  list_id     uuid not null references public.todo_lists (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  family_id   uuid not null references public.families (id) on delete cascade,
  added_by    uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now(),
  primary key (list_id, user_id)
);
create index todo_list_members_user_idx on public.todo_list_members (user_id);
create index todo_list_members_family_idx on public.todo_list_members (family_id);
create index todo_list_members_added_by_idx on public.todo_list_members (added_by);

-- -----------------------------------------------------------------------------
-- todo_items
-- -----------------------------------------------------------------------------
create table public.todo_items (
  id                    uuid primary key,  -- client-generated for idempotent creation
  list_id               uuid not null references public.todo_lists (id) on delete cascade,
  family_id             uuid not null references public.families (id) on delete cascade,
  title                 text not null check (char_length(btrim(title)) between 1 and 200),
  description           text check (description is null or char_length(description) <= 2000),
  status                public.todo_status not null default 'open',
  priority              public.todo_priority not null default 'normal',
  due_at                timestamptz,
  recurrence            public.todo_recurrence not null default 'none',
  recurrence_source_id  uuid unique references public.todo_items (id) on delete set null,
  position              double precision not null default extract(epoch from clock_timestamp()),
  completed_at          timestamptz,
  completed_by          uuid references public.profiles (id) on delete set null,
  created_by            uuid references public.profiles (id) on delete set null,
  updated_by            uuid references public.profiles (id) on delete set null,
  revision              int not null default 1,
  deleted_at            timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  check ((status = 'completed') = (completed_at is not null))
);
create index todo_items_list_idx on public.todo_items (list_id, status, position) where deleted_at is null;
create index todo_items_family_due_idx on public.todo_items (family_id, due_at) where deleted_at is null and status = 'open';
create index todo_items_completed_by_idx on public.todo_items (completed_by);
create index todo_items_created_by_idx on public.todo_items (created_by);
create index todo_items_updated_by_idx on public.todo_items (updated_by);
create trigger todo_items_set_updated_at before update on public.todo_items
  for each row execute function private.set_updated_at();

create table public.todo_assignments (
  item_id      uuid not null references public.todo_items (id) on delete cascade,
  user_id      uuid not null references public.profiles (id) on delete cascade,
  list_id      uuid not null references public.todo_lists (id) on delete cascade,
  family_id    uuid not null references public.families (id) on delete cascade,
  assigned_by  uuid references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now(),
  primary key (item_id, user_id)
);
create index todo_assignments_user_idx on public.todo_assignments (user_id);
create index todo_assignments_list_idx on public.todo_assignments (list_id);
create index todo_assignments_family_idx on public.todo_assignments (family_id);
create index todo_assignments_assigned_by_idx on public.todo_assignments (assigned_by);

create table public.todo_comments (
  id          uuid primary key,  -- client-generated for idempotent posting
  item_id     uuid not null references public.todo_items (id) on delete cascade,
  list_id     uuid not null references public.todo_lists (id) on delete cascade,
  family_id   uuid not null references public.families (id) on delete cascade,
  author_id   uuid references public.profiles (id) on delete set null,
  body        text not null check (char_length(btrim(body)) between 1 and 2000),
  edited_at   timestamptz,
  deleted_at  timestamptz,
  created_at  timestamptz not null default now()
);
create index todo_comments_item_idx on public.todo_comments (item_id, created_at);
create index todo_comments_list_idx on public.todo_comments (list_id);
create index todo_comments_family_idx on public.todo_comments (family_id);
create index todo_comments_author_idx on public.todo_comments (author_id);

create table public.todo_activity_logs (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references public.families (id) on delete cascade,
  list_id     uuid references public.todo_lists (id) on delete cascade,
  item_id     uuid references public.todo_items (id) on delete set null,
  actor_id    uuid references public.profiles (id) on delete set null,
  action      text not null check (char_length(action) between 1 and 64),
  details     jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);
create index todo_activity_list_idx on public.todo_activity_logs (list_id, created_at desc);
create index todo_activity_family_idx on public.todo_activity_logs (family_id, created_at desc);
create index todo_activity_item_idx on public.todo_activity_logs (item_id);
create index todo_activity_actor_idx on public.todo_activity_logs (actor_id);

-- -----------------------------------------------------------------------------
-- Access helpers
-- -----------------------------------------------------------------------------
create or replace function private.can_access_todo_list(p_list_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.todo_lists l
    where l.id = p_list_id
      and l.deleted_at is null
      and private.is_family_member(l.family_id)
      and (
        l.visibility = 'family'
        or l.created_by = (select auth.uid())
        or private.has_family_role(l.family_id, array['owner', 'admin']::public.family_role[])
        or exists (select 1 from public.todo_list_members m
                   where m.list_id = l.id and m.user_id = (select auth.uid()))
      )
  );
$$;

-- Read access ignores soft deletion so Realtime can deliver "deleted" events
-- (Postgres Changes only sends rows that pass the SELECT policy). Clients
-- filter deleted rows themselves. Writes use can_access_todo_list (active only).
create or replace function private.can_read_todo_list(p_list_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.todo_lists l
    where l.id = p_list_id
      and private.is_family_member(l.family_id)
      and (
        l.visibility = 'family'
        or l.created_by = (select auth.uid())
        or private.has_family_role(l.family_id, array['owner', 'admin']::public.family_role[])
        or exists (select 1 from public.todo_list_members m
                   where m.list_id = l.id and m.user_id = (select auth.uid()))
      )
  );
$$;

-- List settings (rename, delete, members): creator or family owner/admin.
create or replace function private.can_manage_todo_list(p_list_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.todo_lists l
    where l.id = p_list_id
      and l.deleted_at is null
      and private.is_family_member(l.family_id)
      and (l.created_by = (select auth.uid())
           or private.has_family_role(l.family_id, array['owner', 'admin']::public.family_role[]))
  );
$$;

revoke all on function private.can_access_todo_list(uuid) from public;
revoke all on function private.can_manage_todo_list(uuid) from public;
revoke all on function private.can_read_todo_list(uuid) from public;
grant execute on function private.can_read_todo_list(uuid) to authenticated;
grant execute on function private.can_access_todo_list(uuid) to authenticated;
grant execute on function private.can_manage_todo_list(uuid) to authenticated;

create or replace function private.todo_log(
  p_family_id uuid, p_list_id uuid, p_item_id uuid, p_action text, p_details jsonb default '{}'::jsonb)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.todo_activity_logs (family_id, list_id, item_id, actor_id, action, details)
  values (p_family_id, p_list_id, p_item_id, auth.uid(), p_action, coalesce(p_details, '{}'::jsonb));
$$;
revoke all on function private.todo_log(uuid, uuid, uuid, text, jsonb) from public;

-- =============================================================================
-- ROW LEVEL SECURITY
-- =============================================================================
alter table public.todo_categories     enable row level security;
alter table public.todo_lists          enable row level security;
alter table public.todo_list_members   enable row level security;
alter table public.todo_items          enable row level security;
alter table public.todo_assignments    enable row level security;
alter table public.todo_comments       enable row level security;
alter table public.todo_activity_logs  enable row level security;

revoke all on public.todo_categories, public.todo_lists, public.todo_list_members, public.todo_items,
  public.todo_assignments, public.todo_comments, public.todo_activity_logs from anon, authenticated;

-- categories: family members read/create; creator or owner/admin update/delete
grant select, delete on public.todo_categories to authenticated;
grant insert (family_id, name, icon, color, created_by) on public.todo_categories to authenticated;
grant update (name, icon, color) on public.todo_categories to authenticated;
create policy todo_categories_select on public.todo_categories for select to authenticated
  using ((select private.is_family_member(family_id)));
create policy todo_categories_insert on public.todo_categories for insert to authenticated
  with check (created_by = (select auth.uid()) and (select private.is_family_member(family_id)));
create policy todo_categories_update on public.todo_categories for update to authenticated
  using (created_by = (select auth.uid())
         or (select private.has_family_role(family_id, array['owner', 'admin']::public.family_role[])))
  with check ((select private.is_family_member(family_id)));
create policy todo_categories_delete on public.todo_categories for delete to authenticated
  using (created_by = (select auth.uid())
         or (select private.has_family_role(family_id, array['owner', 'admin']::public.family_role[])));

-- lists: read if readable (incl. soft-deleted, for Realtime); writes via RPCs only
grant select on public.todo_lists to authenticated;
create policy todo_lists_select on public.todo_lists for select to authenticated
  using ((select private.can_read_todo_list(id)));

grant select on public.todo_list_members to authenticated;
create policy todo_list_members_select on public.todo_list_members for select to authenticated
  using ((select private.can_read_todo_list(list_id)));

-- items: read if list accessible; writes via RPCs only
grant select on public.todo_items to authenticated;
create policy todo_items_select on public.todo_items for select to authenticated
  using ((select private.can_read_todo_list(list_id)));

grant select on public.todo_assignments to authenticated;
create policy todo_assignments_select on public.todo_assignments for select to authenticated
  using ((select private.can_read_todo_list(list_id)));

-- comments: read if list accessible; insert as self; authors edit their own
grant select on public.todo_comments to authenticated;
grant insert (id, item_id, list_id, family_id, author_id, body) on public.todo_comments to authenticated;
grant update (body, edited_at, deleted_at) on public.todo_comments to authenticated;
create policy todo_comments_select on public.todo_comments for select to authenticated
  using ((select private.can_read_todo_list(list_id)));
create policy todo_comments_insert on public.todo_comments for insert to authenticated
  with check (
    author_id = (select auth.uid())
    and (select private.can_access_todo_list(list_id))
    and exists (select 1 from public.todo_items i
                where i.id = item_id and i.list_id = todo_comments.list_id
                  and i.family_id = todo_comments.family_id and i.deleted_at is null)
  );
create policy todo_comments_update on public.todo_comments for update to authenticated
  using (author_id = (select auth.uid()) and deleted_at is null)
  with check (author_id = (select auth.uid()));

grant select on public.todo_activity_logs to authenticated;
create policy todo_activity_select on public.todo_activity_logs for select to authenticated
  using (
    (list_id is not null and (select private.can_read_todo_list(list_id)))
    or (list_id is null and (select private.is_family_member(family_id)))
  );

-- =============================================================================
-- RPCs
-- =============================================================================

-- create_todo_list: idempotent on p_id.
create or replace function public.create_todo_list(
  p_id uuid, p_family_id uuid, p_name text, p_category text default 'personal',
  p_description text default null, p_visibility text default 'family',
  p_member_ids uuid[] default '{}', p_custom_category_id uuid default null)
returns public.todo_lists
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_list public.todo_lists%rowtype;
begin
  if p_id is null then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  select * into v_list from public.todo_lists where id = p_id;
  if v_list.id is not null then
    -- Replay of an already-applied create: return the row if the caller may see it.
    if v_list.created_by = v_uid then return v_list; end if;
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not private.is_family_member(p_family_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_custom_category_id is not null and not exists (
       select 1 from public.todo_categories c where c.id = p_custom_category_id and c.family_id = p_family_id) then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(coalesce(p_member_ids, '{}')) m(uid)
             where private.family_role_of(p_family_id, m.uid) is null) then
    raise exception 'member_not_found' using errcode = 'P0002';
  end if;
  perform private.enforce_rate_limit('create_todo_list', 60, interval '1 hour');

  insert into public.todo_lists (id, family_id, name, description, category, custom_category_id, visibility, created_by)
  values (p_id, p_family_id, btrim(p_name), nullif(btrim(p_description), ''),
          case when p_custom_category_id is not null then 'custom' else coalesce(p_category, 'personal') end,
          p_custom_category_id, coalesce(p_visibility, 'family'), v_uid)
  returning * into v_list;

  insert into public.todo_list_members (list_id, user_id, family_id, added_by)
  select p_id, m.uid, p_family_id, v_uid
  from (select distinct unnest(coalesce(p_member_ids, '{}')) as uid) m
  where m.uid <> v_uid
  on conflict do nothing;

  perform private.todo_log(p_family_id, p_id, null, 'list.created', jsonb_build_object('name', v_list.name));
  return v_list;
end;
$$;

-- update_todo_list: rename / describe / recategorise with optimistic concurrency.
create or replace function public.update_todo_list(
  p_id uuid, p_name text, p_description text, p_category text, p_expected_revision int default null,
  p_custom_category_id uuid default null)
returns public.todo_lists
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_list public.todo_lists%rowtype;
begin
  perform private.require_uid();
  if not private.can_manage_todo_list(p_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_list from public.todo_lists where id = p_id for update;
  if p_expected_revision is not null and v_list.revision <> p_expected_revision then
    raise exception 'revision_conflict' using errcode = 'P0409';
  end if;
  if p_custom_category_id is not null and not exists (
       select 1 from public.todo_categories c where c.id = p_custom_category_id and c.family_id = v_list.family_id) then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  update public.todo_lists
     set name = btrim(p_name),
         description = nullif(btrim(p_description), ''),
         category = case when p_custom_category_id is not null then 'custom' else coalesce(p_category, category) end,
         custom_category_id = p_custom_category_id,
         revision = revision + 1
   where id = p_id
  returning * into v_list;
  perform private.todo_log(v_list.family_id, p_id, null, 'list.updated', jsonb_build_object('name', v_list.name));
  return v_list;
end;
$$;

create or replace function public.delete_todo_list(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_family uuid;
begin
  perform private.require_uid();
  if not private.can_manage_todo_list(p_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.todo_lists set deleted_at = now(), revision = revision + 1
   where id = p_id and deleted_at is null
  returning family_id into v_family;
  if v_family is not null then
    perform private.todo_log(v_family, p_id, null, 'list.deleted', '{}'::jsonb);
  end if;
end;
$$;

-- set_todo_list_members: replace the member set of a 'members' list.
create or replace function public.set_todo_list_members(p_list_id uuid, p_user_ids uuid[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_family uuid;
begin
  if not private.can_manage_todo_list(p_list_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select family_id into v_family from public.todo_lists where id = p_list_id for update;
  if exists (select 1 from unnest(coalesce(p_user_ids, '{}')) m(uid)
             where private.family_role_of(v_family, m.uid) is null) then
    raise exception 'member_not_found' using errcode = 'P0002';
  end if;
  delete from public.todo_list_members where list_id = p_list_id and not (user_id = any (coalesce(p_user_ids, '{}')));
  insert into public.todo_list_members (list_id, user_id, family_id, added_by)
  select p_list_id, m.uid, v_family, v_uid from (select distinct unnest(coalesce(p_user_ids, '{}')) uid) m
  on conflict do nothing;
  update public.todo_lists set revision = revision + 1 where id = p_list_id;
  perform private.todo_log(v_family, p_list_id, null, 'list.members_changed',
    jsonb_build_object('count', coalesce(array_length(p_user_ids, 1), 0)));
end;
$$;

-- Internal: replace assignees of an item (validated as active family members).
create or replace function private.set_item_assignees(p_item public.todo_items, p_user_ids uuid[])
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_before uuid[];
  v_after uuid[];
begin
  if exists (select 1 from unnest(coalesce(p_user_ids, '{}')) m(uid)
             where private.family_role_of(p_item.family_id, m.uid) is null) then
    raise exception 'member_not_found' using errcode = 'P0002';
  end if;
  select coalesce(array_agg(user_id order by user_id), '{}') into v_before
    from public.todo_assignments where item_id = p_item.id;
  select coalesce(array_agg(distinct u order by u), '{}') into v_after
    from unnest(coalesce(p_user_ids, '{}')) u;
  if v_before = v_after then
    return false;
  end if;
  delete from public.todo_assignments where item_id = p_item.id and not (user_id = any (v_after));
  insert into public.todo_assignments (item_id, user_id, list_id, family_id, assigned_by)
  select p_item.id, u, p_item.list_id, p_item.family_id, v_uid from unnest(v_after) u
  on conflict do nothing;
  perform private.todo_log(p_item.family_id, p_item.list_id, p_item.id, 'item.assigned',
    jsonb_build_object('user_ids', to_jsonb(v_after)));
  return true;
end;
$$;
revoke all on function private.set_item_assignees(public.todo_items, uuid[]) from public;

-- -----------------------------------------------------------------------------
-- upsert_todo_item
--   * p_id unknown  -> create (idempotent: replaying the same p_id returns the
--                      existing row without changes).
--   * p_id known    -> update; when p_expected_revision is given and differs,
--                      raise revision_conflict (P0409) so the client can
--                      reconcile instead of overwriting someone else's edit.
--   * p_assignee_ids null = leave assignees unchanged.
-- -----------------------------------------------------------------------------
create or replace function public.upsert_todo_item(
  p_id uuid,
  p_list_id uuid,
  p_title text,
  p_description text default null,
  p_priority public.todo_priority default 'normal',
  p_due_at timestamptz default null,
  p_recurrence public.todo_recurrence default 'none',
  p_assignee_ids uuid[] default null,
  p_expected_revision int default null)
returns public.todo_items
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_item public.todo_items%rowtype;
  v_list public.todo_lists%rowtype;
  v_changed boolean;
begin
  if p_id is null then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  select * into v_item from public.todo_items where id = p_id for update;

  if v_item.id is null then
    if not private.can_access_todo_list(p_list_id) then
      raise exception 'forbidden' using errcode = '42501';
    end if;
    perform private.enforce_rate_limit('create_todo_item', 600, interval '1 hour');
    select * into v_list from public.todo_lists where id = p_list_id;
    insert into public.todo_items (id, list_id, family_id, title, description, priority, due_at, recurrence,
                                   created_by, updated_by)
    values (p_id, p_list_id, v_list.family_id, btrim(p_title), nullif(btrim(p_description), ''),
            coalesce(p_priority, 'normal'), p_due_at, coalesce(p_recurrence, 'none'), v_uid, v_uid)
    returning * into v_item;
    if p_assignee_ids is not null then
      perform private.set_item_assignees(v_item, p_assignee_ids);
    end if;
    perform private.todo_log(v_item.family_id, v_item.list_id, v_item.id, 'item.created',
      jsonb_build_object('title', v_item.title));
    return v_item;
  end if;

  -- Existing item
  if v_item.deleted_at is not null or not private.can_access_todo_list(v_item.list_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_list_id is distinct from v_item.list_id then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  if p_expected_revision is not null and p_expected_revision <> v_item.revision then
    raise exception 'revision_conflict' using errcode = 'P0409';
  end if;

  v_changed := (btrim(p_title), nullif(btrim(p_description), ''), coalesce(p_priority, 'normal'), p_due_at,
                coalesce(p_recurrence, 'none'))
               is distinct from
               (v_item.title, v_item.description, v_item.priority, v_item.due_at, v_item.recurrence);
  if p_assignee_ids is not null then
    v_changed := private.set_item_assignees(v_item, p_assignee_ids) or v_changed;
  end if;
  if not v_changed then
    return v_item;  -- idempotent replay / no-op edit
  end if;

  update public.todo_items
     set title = btrim(p_title), description = nullif(btrim(p_description), ''),
         priority = coalesce(p_priority, 'normal'), due_at = p_due_at,
         recurrence = coalesce(p_recurrence, 'none'),
         updated_by = v_uid, revision = revision + 1
   where id = p_id
  returning * into v_item;
  perform private.todo_log(v_item.family_id, v_item.list_id, v_item.id, 'item.updated',
    jsonb_build_object('title', v_item.title));
  return v_item;
end;
$$;

-- Next due date for a recurring item.
create or replace function private.next_due(p_due timestamptz, p_rule public.todo_recurrence)
returns timestamptz
language sql
immutable
set search_path = ''
as $$
  select case p_rule
    when 'daily' then p_due + interval '1 day'
    when 'weekly' then p_due + interval '7 days'
    when 'monthly' then p_due + interval '1 month'
    when 'yearly' then p_due + interval '1 year'
    else null
  end;
$$;

-- -----------------------------------------------------------------------------
-- set_todo_item_status(id, completed): idempotent; never toggles blindly.
-- Completing a recurring item spawns the next occurrence exactly once
-- (unique recurrence_source_id).
-- -----------------------------------------------------------------------------
create or replace function public.set_todo_item_status(p_id uuid, p_completed boolean)
returns public.todo_items
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_item public.todo_items%rowtype;
  v_next_id uuid;
  v_target public.todo_status := case when p_completed then 'completed' else 'open' end;
begin
  select * into v_item from public.todo_items where id = p_id for update;
  if v_item.id is null or v_item.deleted_at is not null or not private.can_access_todo_list(v_item.list_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_item.status = v_target then
    return v_item;  -- already in the requested state: no-op
  end if;

  update public.todo_items
     set status = v_target,
         completed_at = case when p_completed then now() else null end,
         completed_by = case when p_completed then v_uid else null end,
         updated_by = v_uid, revision = revision + 1
   where id = p_id
  returning * into v_item;

  perform private.todo_log(v_item.family_id, v_item.list_id, v_item.id,
    case when p_completed then 'item.completed' else 'item.reopened' end,
    jsonb_build_object('title', v_item.title));

  if p_completed and v_item.recurrence <> 'none' then
    v_next_id := gen_random_uuid();
    insert into public.todo_items (id, list_id, family_id, title, description, priority, due_at, recurrence,
                                   recurrence_source_id, created_by, updated_by)
    values (v_next_id, v_item.list_id, v_item.family_id, v_item.title, v_item.description, v_item.priority,
            private.next_due(coalesce(v_item.due_at, now()), v_item.recurrence), v_item.recurrence,
            v_item.id, v_uid, v_uid)
    on conflict (recurrence_source_id) do nothing;
    if found then
      insert into public.todo_assignments (item_id, user_id, list_id, family_id, assigned_by)
      select v_next_id, a.user_id, a.list_id, a.family_id, v_uid
      from public.todo_assignments a where a.item_id = v_item.id;
      perform private.todo_log(v_item.family_id, v_item.list_id, v_next_id, 'item.recurred',
        jsonb_build_object('title', v_item.title, 'from', v_item.id));
    end if;
  end if;
  return v_item;
end;
$$;

create or replace function public.delete_todo_item(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_item public.todo_items%rowtype;
begin
  select * into v_item from public.todo_items where id = p_id for update;
  if v_item.id is null or not private.can_access_todo_list(v_item.list_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_item.deleted_at is not null then
    return;  -- idempotent
  end if;
  if not (v_item.created_by = v_uid or private.can_manage_todo_list(v_item.list_id)) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.todo_items set deleted_at = now(), updated_by = v_uid, revision = revision + 1 where id = p_id;
  perform private.todo_log(v_item.family_id, v_item.list_id, v_item.id, 'item.deleted',
    jsonb_build_object('title', v_item.title));
end;
$$;

-- -----------------------------------------------------------------------------
-- todo_list_summaries(family_id): lists with progress counters.
-- SECURITY INVOKER: RLS on the underlying tables applies.
-- -----------------------------------------------------------------------------
create or replace function public.todo_list_summaries(p_family_id uuid)
returns table (
  id uuid, name text, description text, category text, custom_category_id uuid, visibility text,
  created_by uuid, revision int, created_at timestamptz, updated_at timestamptz,
  total_items int, completed_items int, overdue_items int, due_today_items int)
language sql
stable
security invoker
set search_path = ''
as $$
  select l.id, l.name, l.description, l.category, l.custom_category_id, l.visibility,
         l.created_by, l.revision, l.created_at, l.updated_at,
         count(i.id)::int,
         count(i.id) filter (where i.status = 'completed')::int,
         count(i.id) filter (where i.status = 'open' and i.due_at < now())::int,
         count(i.id) filter (where i.status = 'open' and i.due_at >= date_trunc('day', now())
                                   and i.due_at < date_trunc('day', now()) + interval '1 day')::int
  from public.todo_lists l
  left join public.todo_items i on i.list_id = l.id and i.deleted_at is null
  where l.family_id = p_family_id and l.deleted_at is null
  group by l.id
  order by l.updated_at desc;
$$;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('create_todo_list', 'update_todo_list', 'delete_todo_list', 'set_todo_list_members',
                        'upsert_todo_item', 'set_todo_item_status', 'delete_todo_item', 'todo_list_summaries')
  loop
    execute format('revoke all on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated', r.sig);
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- Realtime: persistent changes are delivered with Postgres Changes (RLS-aware).
-- Assignment changes bump the item's revision, so todo_items events cover them.
-- -----------------------------------------------------------------------------
alter publication supabase_realtime add table public.todo_lists;
alter publication supabase_realtime add table public.todo_items;
alter publication supabase_realtime add table public.todo_comments;
