-- =============================================================================
-- FamilySync — Migration 20261124000500: linked families (rumpun), stage 1
--
-- A family can be a BRANCH (cabang) of one PARENT family (induk); a parent can
-- have many branches, to any depth. All families connected this way form a
-- RUMPUN (clan).
--
-- Linking:
--   * requested by an owner/admin of one family who is an active member of
--     the other family (you can only link families you belong to);
--   * approved by an owner/admin of the OTHER family (both sides consent);
--     a requester who administers both sides links immediately;
--   * either side's owner/admin can remove the link at any time.
-- A link shares NOTHING private by itself: chats and tasks never cross
-- families. Later stages share only the family tree and events explicitly
-- marked for the clan.
-- =============================================================================

create table public.family_links (
  id                uuid primary key default gen_random_uuid(),
  parent_family_id  uuid not null references public.families (id) on delete cascade,
  child_family_id   uuid not null references public.families (id) on delete cascade,
  status            text not null default 'pending' check (status in ('pending', 'active')),
  requested_by      uuid references public.profiles (id) on delete set null,
  requested_side    text not null check (requested_side in ('parent', 'child')),
  approved_by       uuid references public.profiles (id) on delete set null,
  approved_at       timestamptz,
  created_at        timestamptz not null default now(),
  check (parent_family_id <> child_family_id)
);
-- one parent per family (pending or active)
create unique index family_links_one_parent_uq on public.family_links (child_family_id);
create index family_links_parent_idx on public.family_links (parent_family_id);
create index family_links_requested_by_idx on public.family_links (requested_by);
create index family_links_approved_by_idx on public.family_links (approved_by);

-- -----------------------------------------------------------------------------
-- Clan helpers (active links only; guarded against cycles and runaway depth)
-- -----------------------------------------------------------------------------

-- Topmost ancestor family of p_family_id.
create or replace function private.clan_root(p_family_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  with recursive up(fid, depth, path) as (
    select p_family_id, 0, array[p_family_id]
    union all
    select l.parent_family_id, up.depth + 1, up.path || l.parent_family_id
    from up
    join public.family_links l on l.child_family_id = up.fid and l.status = 'active'
    where up.depth < 50 and not (l.parent_family_id = any (up.path))
  )
  select fid from up order by depth desc limit 1;
$$;

-- Every family in the same clan as p_family_id (including itself), with the
-- depth below the root.
create or replace function private.family_clan(p_family_id uuid)
returns table (family_id uuid, depth int)
language sql
stable
security definer
set search_path = ''
as $$
  with recursive down(fid, depth, path) as (
    select r, 0, array[r] from (select private.clan_root(p_family_id) as r) x
    union all
    select l.child_family_id, down.depth + 1, down.path || l.child_family_id
    from down
    join public.family_links l on l.parent_family_id = down.fid and l.status = 'active'
    join public.families f on f.id = l.child_family_id and f.deleted_at is null
    where down.depth < 50 and not (l.child_family_id = any (down.path))
  )
  select fid, depth from down;
$$;

-- Families in the clans of every family the caller is an active member of.
create or replace function private.my_clan_family_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select distinct c.family_id
  from public.family_members fm
  join public.families f on f.id = fm.family_id and f.deleted_at is null
  cross join lateral private.family_clan(fm.family_id) c
  where fm.user_id = (select auth.uid()) and fm.status = 'active';
$$;

-- Is p_user an active member of any family in the clan of p_family_id?
create or replace function private.is_clan_member(p_family_id uuid, p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from private.family_clan(p_family_id) c
    where private.family_role_of(c.family_id, p_user) is not null);
$$;

revoke all on function private.clan_root(uuid) from public;
revoke all on function private.family_clan(uuid) from public;
revoke all on function private.my_clan_family_ids() from public;
revoke all on function private.is_clan_member(uuid, uuid) from public;
grant execute on function private.my_clan_family_ids() to authenticated;

-- -----------------------------------------------------------------------------
-- RLS: a link is visible to members of either family
-- -----------------------------------------------------------------------------
alter table public.family_links enable row level security;
revoke all on public.family_links from anon, authenticated;
grant select on public.family_links to authenticated;
create policy family_links_select on public.family_links for select to authenticated
  using ((select private.is_family_member(parent_family_id)) or (select private.is_family_member(child_family_id)));

-- -----------------------------------------------------------------------------
-- RPCs
-- -----------------------------------------------------------------------------
create or replace function public.request_family_link(p_parent_family_id uuid, p_child_family_id uuid)
returns public.family_links
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_admin_parent boolean := private.has_family_role(p_parent_family_id, array['owner', 'admin']::public.family_role[]);
  v_admin_child boolean := private.has_family_role(p_child_family_id, array['owner', 'admin']::public.family_role[]);
  v_link public.family_links%rowtype;
  v_notify uuid[];
  v_other uuid;
begin
  if p_parent_family_id is null or p_child_family_id is null or p_parent_family_id = p_child_family_id then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  -- must administer one side and belong to the other
  if not ((v_admin_child and private.is_family_member(p_parent_family_id))
          or (v_admin_parent and private.is_family_member(p_child_family_id))) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if exists (select 1 from public.family_links where child_family_id = p_child_family_id) then
    raise exception 'already_linked' using errcode = '22023';
  end if;
  -- no cycles: the parent must not be inside the child's subtree (pending links included)
  if exists (
    with recursive down(fid, path) as (
      select p_child_family_id, array[p_child_family_id]
      union all
      select l.child_family_id, down.path || l.child_family_id
      from down join public.family_links l on l.parent_family_id = down.fid
      where not (l.child_family_id = any (down.path)) and cardinality(down.path) < 50
    )
    select 1 from down where fid = p_parent_family_id) then
    raise exception 'link_cycle' using errcode = '22023';
  end if;
  perform private.enforce_rate_limit('request_family_link', 20, interval '1 day');

  insert into public.family_links (parent_family_id, child_family_id, status, requested_by, requested_side,
                                   approved_by, approved_at)
  values (p_parent_family_id, p_child_family_id,
          case when v_admin_parent and v_admin_child then 'active' else 'pending' end,
          v_uid, case when v_admin_child then 'child' else 'parent' end,
          case when v_admin_parent and v_admin_child then v_uid end,
          case when v_admin_parent and v_admin_child then now() end)
  returning * into v_link;

  if v_link.status = 'pending' then
    v_other := case when v_link.requested_side = 'child' then p_parent_family_id else p_child_family_id end;
    select array_agg(user_id) into v_notify from public.family_members
     where family_id = v_other and status = 'active' and role in ('owner', 'admin');
    perform private.notify(
      v_notify, v_other, 'family_request', 'family-link:' || v_link.id,
      jsonb_build_object(
        'ms', jsonb_build_object('title', 'Permintaan sambungan keluarga',
              'body', private.display_name(v_uid) || ' mahu menyambungkan "'
                      || (select name from public.families where id = p_child_family_id) || '" sebagai cabang kepada "'
                      || (select name from public.families where id = p_parent_family_id) || '"'),
        'en', jsonb_build_object('title', 'Family link request',
              'body', private.display_name(v_uid) || ' wants to link "'
                      || (select name from public.families where id = p_child_family_id) || '" as a branch of "'
                      || (select name from public.families where id = p_parent_family_id) || '"')),
      jsonb_build_object('route', '/family-links', 'tag', 'family-link', 'channel', 'family'),
      v_uid);
  end if;
  perform private.audit(p_child_family_id, 'family.link_requested', 'family', p_parent_family_id, '{}'::jsonb, 'admins');
  return v_link;
end;
$$;

-- The other side's owner/admin approves (or declines, which removes the request).
create or replace function public.respond_family_link(p_link_id uuid, p_approve boolean)
returns public.family_links
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_link public.family_links%rowtype;
  v_side uuid;
begin
  select * into v_link from public.family_links where id = p_link_id for update;
  if v_link.id is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_side := case when v_link.requested_side = 'child' then v_link.parent_family_id else v_link.child_family_id end;
  if not private.has_family_role(v_side, array['owner', 'admin']::public.family_role[]) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_link.status = 'active' then
    return v_link;  -- idempotent
  end if;
  if not p_approve then
    delete from public.family_links where id = p_link_id;
    v_link.status := 'pending';
    return v_link;
  end if;
  update public.family_links set status = 'active', approved_by = v_uid, approved_at = now()
   where id = p_link_id returning * into v_link;
  perform private.notify(
    array[v_link.requested_by], v_side, 'family_request', 'family-link-ok:' || v_link.id,
    jsonb_build_object(
      'ms', jsonb_build_object('title', 'Keluarga disambungkan', 'body', 'Permintaan sambungan keluarga anda telah diluluskan'),
      'en', jsonb_build_object('title', 'Families linked', 'body', 'Your family link request was approved')),
    jsonb_build_object('route', '/family-links', 'tag', 'family-link', 'channel', 'family'),
    v_uid);
  perform private.audit(v_link.child_family_id, 'family.linked', 'family', v_link.parent_family_id, '{}'::jsonb, 'members');
  perform private.audit(v_link.parent_family_id, 'family.linked', 'family', v_link.child_family_id, '{}'::jsonb, 'members');
  return v_link;
end;
$$;

-- Owner/admin of either side removes a link or withdraws a request.
create or replace function public.remove_family_link(p_link_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_link public.family_links%rowtype;
begin
  perform private.require_uid();
  select * into v_link from public.family_links where id = p_link_id for update;
  if v_link.id is null then
    return;  -- idempotent
  end if;
  if not (private.has_family_role(v_link.parent_family_id, array['owner', 'admin']::public.family_role[])
          or private.has_family_role(v_link.child_family_id, array['owner', 'admin']::public.family_role[])) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  delete from public.family_links where id = p_link_id;
  if v_link.status = 'active' then
    perform private.audit(v_link.child_family_id, 'family.unlinked', 'family', v_link.parent_family_id, '{}'::jsonb, 'members');
    perform private.audit(v_link.parent_family_id, 'family.unlinked', 'family', v_link.child_family_id, '{}'::jsonb, 'members');
  end if;
end;
$$;

-- Families in the clan of p_family_id (caller must be a member), with their
-- position relative to it. Only public facts: name, member count, depth.
create or replace function public.linked_families(p_family_id uuid)
returns table (family_id uuid, name text, member_count int, depth int, parent_family_id uuid, relation text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_parent uuid;
begin
  if not private.is_family_member(p_family_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select l.parent_family_id into v_parent from public.family_links l
   where l.child_family_id = p_family_id and l.status = 'active';
  return query
    select c.family_id, f.name,
           (select count(*)::int from public.family_members m where m.family_id = c.family_id and m.status = 'active'),
           c.depth,
           (select l.parent_family_id from public.family_links l where l.child_family_id = c.family_id and l.status = 'active'),
           case
             when c.family_id = p_family_id then 'self'
             when c.family_id = v_parent then 'parent'
             when exists (select 1 from public.family_links l where l.child_family_id = c.family_id
                           and l.parent_family_id = p_family_id and l.status = 'active') then 'child'
             else 'clan'
           end
    from private.family_clan(p_family_id) c
    join public.families f on f.id = c.family_id and f.deleted_at is null
    order by c.depth, f.name;
end;
$$;

-- Pending link requests involving p_family_id (caller must be a member).
-- incoming = waiting for THIS family's approval.
create or replace function public.family_link_requests(p_family_id uuid)
returns table (id uuid, parent_family_id uuid, child_family_id uuid, other_family_name text, incoming boolean,
               requested_by_name text, created_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.is_family_member(p_family_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return query
    select l.id, l.parent_family_id, l.child_family_id,
           (select f.name from public.families f
             where f.id = case when l.parent_family_id = p_family_id then l.child_family_id else l.parent_family_id end),
           (l.requested_side = 'child' and l.parent_family_id = p_family_id)
             or (l.requested_side = 'parent' and l.child_family_id = p_family_id),
           private.display_name(l.requested_by), l.created_at
    from public.family_links l
    where l.status = 'pending' and (l.parent_family_id = p_family_id or l.child_family_id = p_family_id)
    order by l.created_at;
end;
$$;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('request_family_link', 'respond_family_link', 'remove_family_link', 'linked_families',
                        'family_link_requests')
  loop
    execute format('revoke all on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated', r.sig);
  end loop;
end;
$$;

alter publication supabase_realtime add table public.family_links;
