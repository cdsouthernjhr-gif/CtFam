-- =============================================================================
-- FamilySync — Migration 20261124000600: shared clan family tree (rumpun, stage 2)
--
-- Owner decisions: every member of every linked family sees the whole clan
-- tree including birth dates (2a); a relation between people of two different
-- families needs an owner/admin of BOTH families (3a); birthday push
-- notifications stay within one's own families (4a).
--
--   * people and relations are readable across the clan;
--   * each person keeps a home family (family_id); only that family's
--     owner/admin (or the person themselves) edits the record;
--   * cross-family relations carry two approvals (family_ok / other_ok) and
--     only count when both are given;
--   * duplicates (the same person recorded in two families) are merged:
--     immediately inside one family, or by request + approval across families;
--     a merge only joins records with the same gender and birth date;
--   * relationships are computed over the whole clan.
-- =============================================================================

alter table public.family_relations
  add column if not exists other_family_id uuid references public.families (id) on delete cascade,
  add column if not exists family_ok boolean not null default true,
  add column if not exists other_ok boolean not null default true;
create index if not exists family_relations_other_family_idx on public.family_relations (other_family_id);

-- Clan-wide reading
alter policy family_persons_select on public.family_persons
  using (family_id in (select private.my_clan_family_ids()));
alter policy family_relations_select on public.family_relations
  using (family_id in (select private.my_clan_family_ids()));
alter policy "tree-photos: read members" on storage.objects
  using (bucket_id = 'tree-photos' and private.path_uuid(name) in (select private.my_clan_family_ids()));

create or replace function private.validate_relation(p_rel public.family_relations, p_for_confirm boolean)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_a public.family_persons%rowtype;
  v_b public.family_persons%rowtype;
begin
  -- both people must be in the same clan as the relation's family
  select * into v_a from public.family_persons where id = p_rel.person_a and deleted_at is null
     and family_id in (select c.family_id from private.family_clan(p_rel.family_id) c);
  select * into v_b from public.family_persons where id = p_rel.person_b and deleted_at is null
     and family_id in (select c.family_id from private.family_clan(p_rel.family_id) c);
  if v_a.id is null or v_b.id is null then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  if p_rel.kind = 'parent' then
    -- no cycles: the parent must not already descend from the child
    if exists (select 1 from private.tree_ancestors(v_a.id, true) t where t.person = v_b.id) then
      raise exception 'tree_cycle' using errcode = '22023';
    end if;
    if p_rel.parent_type = 'biological' then
      if v_a.birth_date >= v_b.birth_date then
        raise exception 'invalid_dates' using errcode = '22023';
      end if;
      -- at most one biological father and one biological mother
      if exists (select 1 from public.family_relations r join public.family_persons p on p.id = r.person_a
                  where r.kind = 'parent' and r.person_b = v_b.id and r.parent_type = 'biological'
                    and r.deleted_at is null and r.id <> p_rel.id
                    and (r.status = 'confirmed' or (not p_for_confirm and r.status = 'pending'))
                    and p.gender = v_a.gender and p.deleted_at is null) then
        raise exception 'too_many_parents' using errcode = '22023';
      end if;
    elsif (select count(*) from public.family_relations r
            where r.kind = 'parent' and r.person_b = v_b.id and r.parent_type = 'adoptive'
              and r.deleted_at is null and r.status = 'confirmed' and r.id <> p_rel.id) >= 2 then
      raise exception 'too_many_parents' using errcode = '22023';
    end if;
  else
    -- spouses must not be ancestor/descendant of each other
    if exists (select 1 from private.tree_ancestors(v_a.id) t where t.person = v_b.id)
       or exists (select 1 from private.tree_ancestors(v_b.id) t where t.person = v_a.id) then
      raise exception 'invalid_input' using errcode = '22023';
    end if;
  end if;
end;
$$;

create or replace function public.relationship_between(p_family_id uuid, p_target uuid, p_from uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_from uuid := p_from;
  v_me public.family_persons%rowtype;
  v_t public.family_persons%rowtype;
  b record;
  v_older boolean;
  v_half_ms text;
  v_half_en text;
  v_spouse uuid;
  v_ms text;
  v_en text;
  v_via uuid;
  v_g text;
begin
  if not private.is_family_member(p_family_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_from is null then
    -- my own record anywhere in the clan, preferring the acting family
    select p.id into v_from from public.family_persons p
     where p.user_id = auth.uid() and p.deleted_at is null
       and p.family_id in (select c.family_id from private.family_clan(p_family_id) c)
     order by (p.family_id = p_family_id) desc, p.created_at
     limit 1;
    if v_from is null then
      return jsonb_build_object('kind', 'no_profile');
    end if;
  end if;
  select * into v_me from public.family_persons where id = v_from and deleted_at is null
     and family_id in (select c.family_id from private.family_clan(p_family_id) c);
  select * into v_t from public.family_persons where id = p_target and deleted_at is null
     and family_id in (select c.family_id from private.family_clan(p_family_id) c);
  if v_me.id is null or v_t.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_me.id = v_t.id then
    return jsonb_build_object('kind', 'self', 'ms', 'diri anda', 'en', 'you', 'up', 0, 'down', 0);
  end if;

  -- 1. Blood
  select * into b from private.blood_link(v_me.id, v_t.id);
  if b.up is not null then
    v_older := case when v_t.birth_date = v_me.birth_date then null else v_t.birth_date < v_me.birth_date end;
    if b.up = 1 and b.down = 1 then
      v_half_ms := private.half_sibling_kind(v_me.id, v_t.id, 'ms');
      v_half_en := private.half_sibling_kind(v_me.id, v_t.id, 'en');
    end if;
    v_ms := private.blood_term(b.up, b.down, v_t.gender, v_older, v_half_ms, 'ms');
    v_en := private.blood_term(b.up, b.down, v_t.gender, v_older, v_half_en, 'en');
    if b.adoptive then
      v_ms := v_ms || ' (angkat)';
      v_en := 'adoptive ' || v_en;
    end if;
    -- target's parent on the path explains the link ("anak kepada Hasan")
    v_via := case when b.down >= 2 then b.to_path[2] end;
    return jsonb_build_object('kind', 'blood', 'ms', v_ms, 'en', v_en, 'up', b.up, 'down', b.down,
                              'via', v_via, 'adoptive', b.adoptive);
  end if;

  -- 2. Spouse
  if v_t.id in (select private.person_spouses(v_me.id)) then
    return jsonb_build_object('kind', 'marriage',
      'ms', case v_t.gender when 'male' then 'suami' else 'isteri' end,
      'en', case v_t.gender when 'male' then 'husband' else 'wife' end);
  end if;

  v_older := case when v_t.birth_date = v_me.birth_date then null else v_t.birth_date < v_me.birth_date end;
  v_g := v_t.gender;

  -- 3. Blood relative of my spouse (mertua, ipar, anak tiri, ...)
  for v_spouse in select private.person_spouses(v_me.id) loop
    select * into b from private.blood_link(v_spouse, v_t.id);
    if b.up is not null then
      if b.up = 1 and b.down = 0 then
        v_ms := case v_g when 'male' then 'bapa mertua' else 'ibu mertua' end;
        v_en := case v_g when 'male' then 'father-in-law' else 'mother-in-law' end;
      elsif b.up = 2 and b.down = 0 then
        v_ms := case v_g when 'male' then 'datuk mertua' else 'nenek mertua' end;
        v_en := case v_g when 'male' then 'grandfather-in-law' else 'grandmother-in-law' end;
      elsif b.up = 1 and b.down = 1 then
        v_ms := case when v_older is false then 'adik ipar' when v_g = 'male' then 'abang ipar' else 'kakak ipar' end;
        v_en := case v_g when 'male' then 'brother-in-law' else 'sister-in-law' end;
      elsif b.up = 0 and b.down = 1 then
        v_ms := 'anak tiri';
        v_en := case v_g when 'male' then 'stepson' else 'stepdaughter' end;
      else
        v_ms := private.blood_term(b.up, b.down, v_g, v_older, null, 'ms') || ' kepada pasangan anda';
        v_en := 'your spouse''s ' || private.blood_term(b.up, b.down, v_g, v_older, null, 'en');
      end if;
      return jsonb_build_object('kind', 'marriage', 'ms', v_ms, 'en', v_en, 'via', v_spouse);
    end if;
  end loop;

  -- 4. Spouse of my blood relative (menantu, ipar, ibu/bapa tiri, ...)
  for v_spouse in select private.person_spouses(v_t.id) loop
    select * into b from private.blood_link(v_me.id, v_spouse);
    if b.up is not null then
      if b.up = 0 and b.down = 1 then
        v_ms := 'menantu';
        v_en := case v_g when 'male' then 'son-in-law' else 'daughter-in-law' end;
      elsif b.up = 0 and b.down = 2 then
        v_ms := 'cucu menantu';
        v_en := case v_g when 'male' then 'grandson-in-law' else 'granddaughter-in-law' end;
      elsif b.up = 1 and b.down = 1 then
        v_ms := case when v_older is false then 'adik ipar' when v_g = 'male' then 'abang ipar' else 'kakak ipar' end;
        v_en := case v_g when 'male' then 'brother-in-law' else 'sister-in-law' end;
      elsif b.up = 1 and b.down = 0 then
        v_ms := case v_g when 'male' then 'bapa tiri' else 'ibu tiri' end;
        v_en := case v_g when 'male' then 'stepfather' else 'stepmother' end;
      elsif b.up = 2 and b.down = 1 then
        v_ms := case v_g when 'male' then 'bapa saudara' else 'ibu saudara' end;
        v_en := (case v_g when 'male' then 'uncle' else 'aunt' end) || ' by marriage';
      else
        v_ms := 'pasangan kepada ' || private.blood_term(b.up, b.down, case v_g when 'male' then 'female' else 'male' end, null, null, 'ms') || ' anda';
        v_en := 'spouse of your ' || private.blood_term(b.up, b.down, case v_g when 'male' then 'female' else 'male' end, null, null, 'en');
      end if;
      return jsonb_build_object('kind', 'marriage', 'ms', v_ms, 'en', v_en, 'via', v_spouse);
    end if;
  end loop;

  -- 5. Biras (spouses of siblings-in-law) and besan (parents of a child-in-law)
  for v_spouse in select private.person_spouses(v_me.id) loop
    if exists (select 1 from private.person_spouses(v_t.id) ts, private.blood_link(v_spouse, ts) bl
               where bl.up = 1 and bl.down = 1) then
      return jsonb_build_object('kind', 'marriage', 'ms', 'biras', 'en', 'co-sibling-in-law', 'via', v_spouse);
    end if;
  end loop;
  if exists (
    select 1
    from public.family_relations mc
    join public.family_relations tc on tc.kind = 'parent' and tc.person_a = v_t.id
     and tc.status = 'confirmed' and tc.deleted_at is null
    where mc.kind = 'parent' and mc.person_a = v_me.id and mc.status = 'confirmed' and mc.deleted_at is null
      and tc.person_b in (select private.person_spouses(mc.person_b))) then
    return jsonb_build_object('kind', 'marriage', 'ms', 'besan', 'en', 'co-parent-in-law');
  end if;

  return jsonb_build_object('kind', 'none');
end;
$$;

-- -----------------------------------------------------------------------------
-- Relations across families
-- -----------------------------------------------------------------------------
create or replace function public.propose_relation(
  p_id uuid,
  p_family_id uuid,
  p_kind text,
  p_person_a uuid,
  p_person_b uuid,
  p_parent_type text default 'biological')
returns public.family_relations
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_rel public.family_relations%rowtype;
  v_fam_a uuid;
  v_fam_b uuid;
  v_need uuid[];
  v_admins uuid[];
  v_actor text;
  v_f uuid;
begin
  if p_id is null or p_kind not in ('parent', 'spouse') or p_person_a is null or p_person_b is null
     or p_person_a = p_person_b or (p_kind = 'parent' and p_parent_type not in ('biological', 'adoptive')) then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  if not private.is_family_member(p_family_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_rel from public.family_relations where id = p_id;
  if v_rel.id is not null then
    if not (v_rel.family_id in (select c.family_id from private.family_clan(p_family_id) c)) then
      raise exception 'forbidden' using errcode = '42501';
    end if;
    return v_rel;  -- idempotent replay
  end if;
  perform private.enforce_rate_limit('propose_relation', 200, interval '1 hour');

  v_rel.id := p_id;
  v_rel.kind := p_kind;
  v_rel.person_a := case when p_kind = 'spouse' then least(p_person_a, p_person_b) else p_person_a end;
  v_rel.person_b := case when p_kind = 'spouse' then greatest(p_person_a, p_person_b) else p_person_b end;
  v_rel.parent_type := case when p_kind = 'parent' then p_parent_type end;
  select family_id into v_fam_a from public.family_persons where id = v_rel.person_a and deleted_at is null;
  select family_id into v_fam_b from public.family_persons where id = v_rel.person_b and deleted_at is null;
  if v_fam_a is null or v_fam_b is null
     or not (v_fam_a in (select c.family_id from private.family_clan(p_family_id) c))
     or not (v_fam_b in (select c.family_id from private.family_clan(p_family_id) c)) then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  v_rel.family_id := v_fam_a;
  v_rel.other_family_id := nullif(v_fam_b, v_fam_a);
  v_rel.family_ok := private.has_family_role(v_fam_a, array['owner', 'admin']::public.family_role[]);
  v_rel.other_ok := v_rel.other_family_id is null
                    or private.has_family_role(v_fam_b, array['owner', 'admin']::public.family_role[]);
  if v_rel.other_family_id is null then
    v_rel.other_ok := true;
  end if;
  perform private.validate_relation(v_rel, v_rel.family_ok and v_rel.other_ok);

  insert into public.family_relations (id, family_id, other_family_id, kind, person_a, person_b, parent_type, status,
                                       family_ok, other_ok, proposed_by, reviewed_by, reviewed_at)
  values (v_rel.id, v_rel.family_id, v_rel.other_family_id, p_kind, v_rel.person_a, v_rel.person_b, v_rel.parent_type,
          case when v_rel.family_ok and v_rel.other_ok then 'confirmed' else 'pending' end,
          v_rel.family_ok, v_rel.other_ok, v_uid,
          case when v_rel.family_ok and v_rel.other_ok then v_uid end,
          case when v_rel.family_ok and v_rel.other_ok then now() end)
  returning * into v_rel;

  -- tell the admins whose approval is still missing
  v_need := array_remove(array[case when not v_rel.family_ok then v_rel.family_id end,
                               case when not v_rel.other_ok then v_rel.other_family_id end], null);
  v_actor := private.display_name(v_uid);
  foreach v_f in array v_need loop
    select array_agg(user_id) into v_admins from public.family_members
     where family_id = v_f and status = 'active' and role in ('owner', 'admin');
    perform private.notify(
      v_admins, v_f, 'family_request', 'tree-proposal:' || v_rel.id,
      jsonb_build_object(
        'ms', jsonb_build_object('title', 'Salasilah', 'body', v_actor || ' mencadangkan hubungan baharu untuk disahkan'),
        'en', jsonb_build_object('title', 'Family tree', 'body', v_actor || ' proposed a new relation to confirm')),
      jsonb_build_object('route', '/family-tree', 'tag', 'tree', 'channel', 'family'),
      v_uid);
  end loop;
  return v_rel;
end;
$$;

-- An owner/admin approves their family's side (or rejects). The relation is
-- confirmed once every involved family approved.
create or replace function public.review_relation(p_id uuid, p_approve boolean)
returns public.family_relations
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_rel public.family_relations%rowtype;
  v_admin_a boolean;
  v_admin_b boolean;
begin
  select * into v_rel from public.family_relations where id = p_id for update;
  if v_rel.id is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_admin_a := private.has_family_role(v_rel.family_id, array['owner', 'admin']::public.family_role[]);
  v_admin_b := v_rel.other_family_id is not null
               and private.has_family_role(v_rel.other_family_id, array['owner', 'admin']::public.family_role[]);
  if not (v_admin_a or v_admin_b) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_rel.deleted_at is not null or v_rel.status <> 'pending' then
    if v_rel.status = (case when p_approve then 'confirmed' else 'rejected' end) then
      return v_rel;
    end if;
    raise exception 'not_pending' using errcode = '22023';
  end if;
  if not p_approve then
    update public.family_relations set status = 'rejected', reviewed_by = v_uid, reviewed_at = now()
     where id = p_id returning * into v_rel;
    return v_rel;
  end if;
  v_rel.family_ok := v_rel.family_ok or v_admin_a;
  v_rel.other_ok := v_rel.other_ok or v_admin_b;
  if v_rel.family_ok and v_rel.other_ok then
    perform private.validate_relation(v_rel, true);
  end if;
  update public.family_relations
     set family_ok = v_rel.family_ok, other_ok = v_rel.other_ok,
         status = case when v_rel.family_ok and v_rel.other_ok then 'confirmed' else 'pending' end,
         reviewed_by = v_uid, reviewed_at = now()
   where id = p_id
  returning * into v_rel;
  return v_rel;
end;
$$;

-- Owner/admin of either family removes a relation; the proposer may withdraw
-- their own pending proposal.
create or replace function public.delete_relation(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_rel public.family_relations%rowtype;
begin
  select * into v_rel from public.family_relations where id = p_id for update;
  if v_rel.id is null or not (v_rel.family_id in (select private.my_clan_family_ids())) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_rel.deleted_at is not null then
    return;
  end if;
  if not (private.has_family_role(v_rel.family_id, array['owner', 'admin']::public.family_role[])
          or (v_rel.other_family_id is not null
              and private.has_family_role(v_rel.other_family_id, array['owner', 'admin']::public.family_role[]))
          or (v_rel.proposed_by is not distinct from v_uid and v_rel.status = 'pending')) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.family_relations set deleted_at = now() where id = p_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Merging duplicate records
-- -----------------------------------------------------------------------------
create table public.person_merges (
  id            uuid primary key default gen_random_uuid(),
  keep_id       uuid not null references public.family_persons (id) on delete cascade,
  remove_id     uuid not null references public.family_persons (id) on delete cascade,
  status        text not null default 'pending' check (status in ('pending', 'done', 'rejected')),
  requested_by  uuid references public.profiles (id) on delete set null,
  reviewed_by   uuid references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now(),
  check (keep_id <> remove_id)
);
create unique index person_merges_pending_uq on public.person_merges (keep_id, remove_id) where status = 'pending';
create index person_merges_remove_idx on public.person_merges (remove_id);
create index person_merges_requested_by_idx on public.person_merges (requested_by);
create index person_merges_reviewed_by_idx on public.person_merges (reviewed_by);
alter table public.person_merges enable row level security;
revoke all on public.person_merges from anon, authenticated;
grant select on public.person_merges to authenticated;
create policy person_merges_select on public.person_merges for select to authenticated
  using (exists (select 1 from public.family_persons p where p.id = keep_id
                  and p.family_id in (select private.my_clan_family_ids())));

-- Moves every relation of p_remove onto p_keep, then retires p_remove.
create or replace function private.apply_person_merge(p_keep uuid, p_remove uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_keep public.family_persons%rowtype;
  v_rm public.family_persons%rowtype;
  r record;
  v_a uuid;
  v_b uuid;
begin
  select * into v_keep from public.family_persons where id = p_keep for update;
  select * into v_rm from public.family_persons where id = p_remove for update;
  for r in select * from public.family_relations where (person_a = p_remove or person_b = p_remove) and deleted_at is null loop
    v_a := case when r.person_a = p_remove then p_keep else r.person_a end;
    v_b := case when r.person_b = p_remove then p_keep else r.person_b end;
    if r.kind = 'spouse' then
      select least(v_a, v_b), greatest(v_a, v_b) into v_a, v_b;
    end if;
    if v_a = v_b or exists (
         select 1 from public.family_relations x
         where x.kind = r.kind and x.person_a = v_a and x.person_b = v_b and x.deleted_at is null
           and x.status <> 'rejected' and x.id <> r.id) then
      update public.family_relations set deleted_at = now() where id = r.id;
    else
      update public.family_relations
         set person_a = v_a, person_b = v_b,
             family_id = (select family_id from public.family_persons where id = v_a),
             other_family_id = nullif((select family_id from public.family_persons where id = v_b),
                                      (select family_id from public.family_persons where id = v_a))
       where id = r.id;
    end if;
  end loop;
  -- retire the duplicate first (frees its account link), then fill gaps on the kept record
  update public.family_persons set deleted_at = now(), user_id = null, revision = revision + 1 where id = p_remove;
  update public.family_persons
     set user_id = coalesce(v_keep.user_id,
                            case when v_rm.user_id is not null and not exists (
                                   select 1 from public.family_persons x
                                   where x.family_id = v_keep.family_id and x.user_id = v_rm.user_id
                                     and x.deleted_at is null and x.id <> p_keep)
                                 then v_rm.user_id end),
         photo_path = coalesce(v_keep.photo_path, v_rm.photo_path),
         notes = coalesce(v_keep.notes, v_rm.notes),
         revision = revision + 1
   where id = p_keep;
end;
$$;
revoke all on function private.apply_person_merge(uuid, uuid) from public;

-- Merge p_remove into p_keep. The caller must administer p_remove's family.
-- Same family: done at once. Across families: a request that an owner/admin
-- of p_keep's family must approve (review_person_merge). Returns the status.
create or replace function public.merge_persons(p_keep uuid, p_remove uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_keep public.family_persons%rowtype;
  v_rm public.family_persons%rowtype;
  v_merge uuid;
  v_admins uuid[];
begin
  select * into v_keep from public.family_persons where id = p_keep and deleted_at is null;
  select * into v_rm from public.family_persons where id = p_remove and deleted_at is null;
  if v_keep.id is null or v_rm.id is null or v_keep.id = v_rm.id
     or not private.has_family_role(v_rm.family_id, array['owner', 'admin']::public.family_role[])
     or not (v_keep.family_id in (select c.family_id from private.family_clan(v_rm.family_id) c)) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_keep.gender <> v_rm.gender or v_keep.birth_date <> v_rm.birth_date then
    raise exception 'not_same_person' using errcode = '22023';
  end if;
  if v_keep.family_id = v_rm.family_id
     or private.has_family_role(v_keep.family_id, array['owner', 'admin']::public.family_role[]) then
    perform private.apply_person_merge(p_keep, p_remove);
    insert into public.person_merges (keep_id, remove_id, status, requested_by, reviewed_by)
    values (p_keep, p_remove, 'done', v_uid, v_uid);
    return 'done';
  end if;
  insert into public.person_merges (keep_id, remove_id, requested_by)
  values (p_keep, p_remove, v_uid)
  on conflict (keep_id, remove_id) where status = 'pending' do nothing
  returning id into v_merge;
  select array_agg(user_id) into v_admins from public.family_members
   where family_id = v_keep.family_id and status = 'active' and role in ('owner', 'admin');
  perform private.notify(
    v_admins, v_keep.family_id, 'family_request', 'tree-merge:' || coalesce(v_merge::text, p_keep::text || ':' || p_remove::text),
    jsonb_build_object(
      'ms', jsonb_build_object('title', 'Salasilah', 'body', private.display_name(v_uid) || ' mahu menggabungkan rekod "' || v_rm.full_name || '" dengan rekod keluarga anda'),
      'en', jsonb_build_object('title', 'Family tree', 'body', private.display_name(v_uid) || ' wants to merge "' || v_rm.full_name || '" with your family''s record')),
    jsonb_build_object('route', '/family-tree', 'tag', 'tree', 'channel', 'family'),
    v_uid);
  return 'pending';
end;
$$;

create or replace function public.review_person_merge(p_merge_id uuid, p_approve boolean)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_m public.person_merges%rowtype;
  v_keep public.family_persons%rowtype;
begin
  select * into v_m from public.person_merges where id = p_merge_id for update;
  select * into v_keep from public.family_persons where id = v_m.keep_id;
  if v_m.id is null or not private.has_family_role(v_keep.family_id, array['owner', 'admin']::public.family_role[]) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_m.status <> 'pending' then
    return v_m.status;
  end if;
  if p_approve then
    if exists (select 1 from public.family_persons where id = v_m.remove_id and deleted_at is null) then
      perform private.apply_person_merge(v_m.keep_id, v_m.remove_id);
    end if;
    update public.person_merges set status = 'done', reviewed_by = v_uid where id = p_merge_id;
    return 'done';
  end if;
  update public.person_merges set status = 'rejected', reviewed_by = v_uid where id = p_merge_id;
  return 'rejected';
end;
$$;

-- Likely duplicates in the clan of p_family_id: same gender and birth date and
-- either the same account or the same first name. remove = a record of a
-- family the caller administers.
create or replace function public.merge_suggestions(p_family_id uuid)
returns table (keep_id uuid, keep_name text, keep_family text, remove_id uuid, remove_name text, remove_family text)
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
    select k.id, k.full_name, fk.name, r.id, r.full_name, fr.name
    from public.family_persons r
    join public.families fr on fr.id = r.family_id
    join public.family_persons k on k.id <> r.id and k.deleted_at is null
     and k.gender = r.gender and k.birth_date = r.birth_date
     and k.family_id in (select c.family_id from private.family_clan(p_family_id) c)
     and ((k.user_id is not null and k.user_id = r.user_id)
          or lower(split_part(btrim(k.full_name), ' ', 1)) = lower(split_part(btrim(r.full_name), ' ', 1)))
    join public.families fk on fk.id = k.family_id
    where r.deleted_at is null
      and r.family_id in (select c.family_id from private.family_clan(p_family_id) c)
      and private.has_family_role(r.family_id, array['owner', 'admin']::public.family_role[])
      -- keep the record of the family higher in the clan (or the older record)
      and ((select depth from private.family_clan(p_family_id) where family_id = k.family_id)
             < (select depth from private.family_clan(p_family_id) where family_id = r.family_id)
           or (k.family_id = r.family_id and k.created_at < r.created_at)
           or (k.family_id <> r.family_id
               and (select depth from private.family_clan(p_family_id) where family_id = k.family_id)
                   = (select depth from private.family_clan(p_family_id) where family_id = r.family_id)
               and k.id < r.id))
      and not exists (select 1 from public.person_merges m where m.keep_id = k.id and m.remove_id = r.id
                       and m.status in ('pending', 'rejected'))
    order by r.full_name;
end;
$$;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('propose_relation', 'review_relation', 'delete_relation', 'relationship_between',
                        'merge_persons', 'review_person_merge', 'merge_suggestions')
  loop
    execute format('revoke all on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated', r.sig);
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- Birthdays (4a): the person's home family, plus every family the person
-- (if they have an account) belongs to.
-- -----------------------------------------------------------------------------
create or replace function private.dispatch_birthdays(p_today date default (now() at time zone 'Asia/Kuala_Lumpur')::date)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_fam uuid;
  v_count int := 0;
  v_members uuid[];
  v_year int := extract(year from p_today)::int;
  v_leap boolean := (extract(year from p_today)::int % 4 = 0 and extract(year from p_today)::int % 100 <> 0)
                    or extract(year from p_today)::int % 400 = 0;
  v_age int;
  v_key text;
begin
  for r in
    select p.* from public.family_persons p
    join public.families f on f.id = p.family_id and f.deleted_at is null
    where p.deleted_at is null and p.death_date is null
      and (
        (extract(month from p.birth_date) = extract(month from p_today) and extract(day from p.birth_date) = extract(day from p_today))
        or (not v_leap and extract(month from p.birth_date) = 2 and extract(day from p.birth_date) = 29
            and extract(month from p_today) = 2 and extract(day from p_today) = 28))
  loop
    v_age := v_year - extract(year from r.birth_date)::int;
    v_key := 'bday:' || r.id || ':' || v_year;
    for v_fam in
      select r.family_id
      union
      select fm.family_id from public.family_members fm
       where r.user_id is not null and fm.user_id = r.user_id and fm.status = 'active'
    loop
      select array_agg(user_id) into v_members from public.family_members
       where family_id = v_fam and status = 'active' and user_id is distinct from r.user_id;
      v_count := v_count + private.notify(
        v_members, v_fam, 'family_event', v_key,
        jsonb_build_object(
          'ms', jsonb_build_object('title', 'Hari jadi hari ini 🎂', 'body', r.full_name || ' berumur ' || v_age || ' tahun hari ini'),
          'en', jsonb_build_object('title', 'Birthday today 🎂', 'body', r.full_name || ' turns ' || v_age || ' today')),
        jsonb_build_object('route', '/family-tree/' || r.id, 'tag', 'bday:' || r.id, 'channel', 'family'),
        null);
    end loop;
    if r.user_id is not null then
      v_count := v_count + private.notify(
        array[r.user_id], r.family_id, 'family_event', v_key,
        jsonb_build_object(
          'ms', jsonb_build_object('title', 'Selamat hari jadi! 🎉', 'body', 'Selamat hari jadi ke-' || v_age || ', ' || r.full_name || '!'),
          'en', jsonb_build_object('title', 'Happy birthday! 🎉', 'body', 'Happy birthday, ' || r.full_name || '! You are ' || v_age || ' today.')),
        jsonb_build_object('route', '/family-tree/' || r.id, 'tag', 'bday:' || r.id, 'channel', 'family'),
        null);
    end if;
  end loop;
  return v_count;
end;
$$;
revoke all on function private.dispatch_birthdays(date) from public;

alter publication supabase_realtime add table public.person_merges;
