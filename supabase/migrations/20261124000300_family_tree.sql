-- =============================================================================
-- FamilySync — Migration 20261124000300: family tree (salasilah)
--
--   family_persons    people in the tree; optionally linked to an app account
--                     (deceased relatives and children can be added without one)
--   family_relations  the ONLY stored facts: parent -> child and spouse links
--
-- Every other relationship (abang, anak saudara, cucu saudara, sepupu, ipar,
-- mertua, menantu, biras, besan, ...) is COMPUTED by
-- public.relationship_between() from the closest common ancestor:
--   up   = generations from "me" to the common ancestor
--   down = generations from the common ancestor to the other person
--   e.g. (1, 2) = anak saudara, (1, 3) = cucu saudara, (2, 2) = sepupu.
-- Older/younger (abang vs adik) comes from the required birth date.
--
-- Permissions (owner decisions):
--   * family owner/admin add and edit anyone, including people without an
--     account, link a person to a member account, and confirm relations;
--   * a member may create/edit only their own person record and PROPOSE
--     relations; proposals stay "pending" (ignored by the computation) until
--     an owner/admin confirms them.
-- Birth dates are required and drive birthday notifications (daily cron).
-- =============================================================================

create table public.family_persons (
  id          uuid primary key,  -- client-generated for idempotent creation
  family_id   uuid not null references public.families (id) on delete cascade,
  user_id     uuid references public.profiles (id) on delete set null,
  full_name   text not null check (char_length(btrim(full_name)) between 1 and 100),
  gender      text not null check (gender in ('male', 'female')),
  birth_date  date not null,
  death_date  date,
  notes       text check (notes is null or char_length(notes) <= 500),
  created_by  uuid references public.profiles (id) on delete set null,
  updated_by  uuid references public.profiles (id) on delete set null,
  revision    int not null default 1,
  deleted_at  timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (death_date is null or death_date >= birth_date)
);
create unique index family_persons_account_uq on public.family_persons (family_id, user_id)
  where user_id is not null and deleted_at is null;
create index family_persons_family_idx on public.family_persons (family_id) where deleted_at is null;
create index family_persons_user_idx on public.family_persons (user_id);
create index family_persons_created_by_idx on public.family_persons (created_by);
create index family_persons_updated_by_idx on public.family_persons (updated_by);
create index family_persons_birthday_idx on public.family_persons (extract(month from birth_date), extract(day from birth_date))
  where deleted_at is null and death_date is null;
create trigger family_persons_set_updated_at before update on public.family_persons
  for each row execute function private.set_updated_at();

create table public.family_relations (
  id           uuid primary key,  -- client-generated for idempotent creation
  family_id    uuid not null references public.families (id) on delete cascade,
  kind         text not null check (kind in ('parent', 'spouse')),
  -- parent: person_a is the parent of person_b; spouse: person_a < person_b
  person_a     uuid not null references public.family_persons (id) on delete cascade,
  person_b     uuid not null references public.family_persons (id) on delete cascade,
  parent_type  text check (parent_type in ('biological', 'adoptive')),
  status       text not null default 'pending' check (status in ('pending', 'confirmed', 'rejected')),
  proposed_by  uuid references public.profiles (id) on delete set null,
  reviewed_by  uuid references public.profiles (id) on delete set null,
  reviewed_at  timestamptz,
  deleted_at   timestamptz,
  created_at   timestamptz not null default now(),
  check (person_a <> person_b),
  check ((kind = 'parent') = (parent_type is not null)),
  check (kind <> 'spouse' or person_a < person_b)
);
create unique index family_relations_uq on public.family_relations (kind, person_a, person_b)
  where deleted_at is null and status <> 'rejected';
create index family_relations_family_idx on public.family_relations (family_id);
create index family_relations_a_idx on public.family_relations (person_a) where deleted_at is null and status = 'confirmed';
create index family_relations_b_idx on public.family_relations (person_b) where deleted_at is null and status = 'confirmed';
create index family_relations_proposed_by_idx on public.family_relations (proposed_by);
create index family_relations_reviewed_by_idx on public.family_relations (reviewed_by);

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------
create or replace function private.is_family_admin(p_family_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.has_family_role(p_family_id, array['owner', 'admin']::public.family_role[]);
$$;
revoke all on function private.is_family_admin(uuid) from public;

-- Confirmed ancestors of p_person (depth 0 = the person), with the path
-- (person first, ancestor last) and whether an adoptive link was used.
create or replace function private.tree_ancestors(p_person uuid, p_include_pending boolean default false)
returns table (person uuid, depth int, adoptive boolean, path uuid[])
language sql
stable
security definer
set search_path = ''
as $$
  with recursive a(person, depth, adoptive, path) as (
    select p_person, 0, false, array[p_person]
    union all
    select r.person_a, a.depth + 1, a.adoptive or r.parent_type = 'adoptive', a.path || r.person_a
    from a
    join public.family_relations r
      on r.kind = 'parent' and r.person_b = a.person and r.deleted_at is null
     and (r.status = 'confirmed' or (p_include_pending and r.status = 'pending'))
    join public.family_persons p on p.id = r.person_a and p.deleted_at is null
    where a.depth < 25 and not (r.person_a = any (a.path))
  )
  select person, depth, adoptive, path from a;
$$;
revoke all on function private.tree_ancestors(uuid, boolean) from public;

-- Closest blood link between two people: (up, down) to the common ancestor.
create or replace function private.blood_link(p_from uuid, p_to uuid)
returns table (up int, down int, ancestor uuid, adoptive boolean, from_path uuid[], to_path uuid[])
language sql
stable
security definer
set search_path = ''
as $$
  select a.depth, b.depth, a.person, a.adoptive or b.adoptive, a.path, b.path
  from private.tree_ancestors(p_from) a
  join private.tree_ancestors(p_to) b on b.person = a.person
  order by a.depth + b.depth, a.depth
  limit 1;
$$;
revoke all on function private.blood_link(uuid, uuid) from public;

-- Malay / English name for a blood link. p_gender is the OTHER person's gender;
-- p_older: the other person was born before "me" (null = same day).
create or replace function private.blood_term(
  p_up int, p_down int, p_gender text, p_older boolean, p_half text, p_lang text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_lang when 'en' then
    case
      when p_up = 0 and p_down = 0 then 'you'
      when p_up = 0 and p_down = 1 then case p_gender when 'male' then 'son' else 'daughter' end
      when p_up = 0 and p_down = 2 then 'grandchild'
      when p_up = 0 and p_down = 3 then 'great-grandchild'
      when p_up = 0 and p_down = 4 then 'great-great-grandchild'
      when p_up = 0 then 'descendant'
      when p_down = 0 and p_up = 1 then case p_gender when 'male' then 'father' else 'mother' end
      when p_down = 0 and p_up = 2 then case p_gender when 'male' then 'grandfather' else 'grandmother' end
      when p_down = 0 and p_up = 3 then case p_gender when 'male' then 'great-grandfather' else 'great-grandmother' end
      when p_down = 0 then 'ancestor'
      when p_up = 1 and p_down = 1 then
        case when p_older is null then 'twin ' when p_older then 'older ' else 'younger ' end ||
        case when p_half is not null then 'half-' else '' end ||
        case p_gender when 'male' then 'brother' else 'sister' end
      when p_up = 1 and p_down = 2 then case p_gender when 'male' then 'nephew' else 'niece' end
      when p_up = 1 and p_down = 3 then case p_gender when 'male' then 'grandnephew' else 'grandniece' end
      when p_up = 1 and p_down = 4 then case p_gender when 'male' then 'great-grandnephew' else 'great-grandniece' end
      when p_up = 2 and p_down = 1 then case p_gender when 'male' then 'uncle' else 'aunt' end
      when p_up = 3 and p_down = 1 then case p_gender when 'male' then 'great-uncle' else 'great-aunt' end
      when p_up = 4 and p_down = 1 then case p_gender when 'male' then 'great-great-uncle' else 'great-great-aunt' end
      when p_up = 2 and p_down = 2 then 'first cousin'
      when p_up = 3 and p_down = 3 then 'second cousin'
      when p_up = 4 and p_down = 4 then 'third cousin'
      when abs(p_up - p_down) = 1 and least(p_up, p_down) = 2 then 'first cousin once removed'
      else 'relative'
    end
  else
    case
      when p_up = 0 and p_down = 0 then 'diri anda'
      when p_up = 0 and p_down = 1 then case p_gender when 'male' then 'anak lelaki' else 'anak perempuan' end
      when p_up = 0 and p_down = 2 then 'cucu'
      when p_up = 0 and p_down = 3 then 'cicit'
      when p_up = 0 and p_down = 4 then 'piut'
      when p_up = 0 then 'keturunan'
      when p_down = 0 and p_up = 1 then case p_gender when 'male' then 'bapa' else 'ibu' end
      when p_down = 0 and p_up = 2 then case p_gender when 'male' then 'datuk' else 'nenek' end
      when p_down = 0 and p_up = 3 then 'moyang'
      when p_down = 0 then 'nenek moyang'
      when p_up = 1 and p_down = 1 then
        case
          when p_older is null then 'adik-beradik kembar'
          when p_older then case p_gender when 'male' then 'abang' else 'kakak' end
          else case p_gender when 'male' then 'adik lelaki' else 'adik perempuan' end
        end || coalesce(' ' || p_half, '')
      when p_up = 1 and p_down = 2 then 'anak saudara'
      when p_up = 1 and p_down = 3 then 'cucu saudara'
      when p_up = 1 and p_down = 4 then 'cicit saudara'
      when p_up = 2 and p_down = 1 then case p_gender when 'male' then 'bapa saudara' else 'ibu saudara' end
      when p_up = 3 and p_down = 1 then case p_gender when 'male' then 'datuk saudara' else 'nenek saudara' end
      when p_up = 4 and p_down = 1 then 'moyang saudara'
      when p_up = 2 and p_down = 2 then 'sepupu'
      when p_up = 3 and p_down = 3 then 'sepupu dua pupu'
      when p_up = 4 and p_down = 4 then 'sepupu tiga pupu'
      when p_up = 2 and p_down = 3 then 'anak sepupu'
      when p_up = 3 and p_down = 2 then 'sepupu kepada ibu/bapa anda'
      else 'saudara'
    end
  end;
$$;

-- "seibu" / "sebapa" when two siblings share exactly one confirmed parent.
create or replace function private.half_sibling_kind(p_a uuid, p_b uuid, p_lang text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  with pa as (select person_a from public.family_relations
               where kind = 'parent' and person_b = p_a and status = 'confirmed' and deleted_at is null),
       pb as (select person_a from public.family_relations
               where kind = 'parent' and person_b = p_b and status = 'confirmed' and deleted_at is null),
       shared as (select person_a from pa intersect select person_a from pb)
  select case
    when (select count(*) from shared) = 1 and ((select count(*) from pa) > 1 or (select count(*) from pb) > 1) then
      case p_lang
        when 'en' then 'half'
        else case (select p.gender from public.family_persons p where p.id = (select person_a from shared))
               when 'male' then 'sebapa' else 'seibu' end
      end
  end;
$$;
revoke all on function private.half_sibling_kind(uuid, uuid, text) from public;

create or replace function private.person_spouses(p_person uuid)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select case when r.person_a = p_person then r.person_b else r.person_a end
  from public.family_relations r
  join public.family_persons p on p.id = case when r.person_a = p_person then r.person_b else r.person_a end
   and p.deleted_at is null
  where r.kind = 'spouse' and r.status = 'confirmed' and r.deleted_at is null
    and (r.person_a = p_person or r.person_b = p_person);
$$;
revoke all on function private.person_spouses(uuid) from public;

-- -----------------------------------------------------------------------------
-- relationship_between: how p_target is related to p_from (default: me).
-- Returns {kind: self|blood|marriage|none, ms, en, up, down, via, adoptive}.
-- "via" is the person that explains the link (e.g. the target's parent on the
-- path: "anak kepada Hasan", or the spouse for in-laws).
-- -----------------------------------------------------------------------------
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
    select id into v_from from public.family_persons
     where family_id = p_family_id and user_id = auth.uid() and deleted_at is null;
    if v_from is null then
      return jsonb_build_object('kind', 'no_profile');
    end if;
  end if;
  select * into v_me from public.family_persons where id = v_from and family_id = p_family_id and deleted_at is null;
  select * into v_t from public.family_persons where id = p_target and family_id = p_family_id and deleted_at is null;
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
-- RLS: family members read; writes through RPCs only
-- -----------------------------------------------------------------------------
alter table public.family_persons   enable row level security;
alter table public.family_relations enable row level security;
revoke all on public.family_persons, public.family_relations from anon, authenticated;

grant select on public.family_persons to authenticated;
create policy family_persons_select on public.family_persons for select to authenticated
  using ((select private.is_family_member(family_id)));

grant select on public.family_relations to authenticated;
create policy family_relations_select on public.family_relations for select to authenticated
  using ((select private.is_family_member(family_id)));

-- -----------------------------------------------------------------------------
-- RPCs
-- -----------------------------------------------------------------------------

-- Checks that parent/child birth dates stay consistent for p_person.
create or replace function private.check_tree_dates(p_person uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1 from public.family_relations r
    join public.family_persons parent on parent.id = r.person_a
    join public.family_persons child on child.id = r.person_b
    where r.kind = 'parent' and r.deleted_at is null and r.status <> 'rejected' and r.parent_type = 'biological'
      and (r.person_a = p_person or r.person_b = p_person)
      and parent.birth_date >= child.birth_date) then
    raise exception 'invalid_dates' using errcode = '22023';
  end if;
end;
$$;
revoke all on function private.check_tree_dates(uuid) from public;

-- upsert_person: admins add/edit anyone (with or without an account);
-- a member may create (p_link_self) and edit only their own record.
create or replace function public.upsert_person(
  p_id uuid,
  p_family_id uuid,
  p_full_name text,
  p_gender text,
  p_birth_date date,
  p_death_date date default null,
  p_notes text default null,
  p_link_self boolean default false,
  p_expected_revision int default null)
returns public.family_persons
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_p public.family_persons%rowtype;
  v_admin boolean;
begin
  if p_id is null or p_gender not in ('male', 'female') or p_birth_date is null
     or p_birth_date > current_date or p_birth_date < date '1800-01-01'
     or (p_death_date is not null and (p_death_date < p_birth_date or p_death_date > current_date))
     or char_length(btrim(coalesce(p_full_name, ''))) not between 1 and 100 then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  if not private.is_family_member(p_family_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_admin := private.is_family_admin(p_family_id);

  select * into v_p from public.family_persons where id = p_id for update;
  if v_p.id is null then
    if not v_admin and not p_link_self then
      raise exception 'forbidden' using errcode = '42501';  -- only admins add other people
    end if;
    if p_link_self and exists (select 1 from public.family_persons
                                where family_id = p_family_id and user_id = v_uid and deleted_at is null) then
      raise exception 'already_linked' using errcode = '22023';
    end if;
    perform private.enforce_rate_limit('upsert_person', 200, interval '1 hour');
    insert into public.family_persons (id, family_id, user_id, full_name, gender, birth_date, death_date, notes,
                                       created_by, updated_by)
    values (p_id, p_family_id, case when p_link_self then v_uid end, btrim(p_full_name), p_gender, p_birth_date,
            p_death_date, nullif(btrim(p_notes), ''), v_uid, v_uid)
    on conflict (id) do nothing
    returning * into v_p;
    if v_p.id is null then  -- concurrent replay of the same create
      select * into v_p from public.family_persons where id = p_id;
      if v_p.family_id is distinct from p_family_id then
        raise exception 'forbidden' using errcode = '42501';
      end if;
      return v_p;
    end if;
    perform private.audit(p_family_id, 'tree.person_added', 'person', v_p.id,
      jsonb_build_object('name', v_p.full_name), 'members');
    return v_p;
  end if;

  if v_p.deleted_at is not null or v_p.family_id <> p_family_id
     or not (v_admin or v_p.user_id is not distinct from v_uid) then  -- NULL-safe: unlinked people are admin-only
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_expected_revision is not null and p_expected_revision <> v_p.revision then
    raise exception 'revision_conflict' using errcode = 'P0409';
  end if;
  if (btrim(p_full_name), p_gender, p_birth_date, p_death_date, nullif(btrim(p_notes), ''))
     is not distinct from (v_p.full_name, v_p.gender, v_p.birth_date, v_p.death_date, v_p.notes) then
    return v_p;  -- idempotent replay / no change
  end if;
  update public.family_persons
     set full_name = btrim(p_full_name), gender = p_gender, birth_date = p_birth_date, death_date = p_death_date,
         notes = nullif(btrim(p_notes), ''), updated_by = v_uid, revision = revision + 1
   where id = p_id
  returning * into v_p;
  perform private.check_tree_dates(v_p.id);
  return v_p;
end;
$$;

-- Admin: link a person to a member's account (null unlinks).
create or replace function public.link_person_account(p_person_id uuid, p_user_id uuid)
returns public.family_persons
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_p public.family_persons%rowtype;
begin
  select * into v_p from public.family_persons where id = p_person_id and deleted_at is null for update;
  if v_p.id is null or not private.is_family_admin(v_p.family_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_user_id is not null then
    if private.family_role_of(v_p.family_id, p_user_id) is null then
      raise exception 'not_family_member' using errcode = '22023';
    end if;
    if exists (select 1 from public.family_persons where family_id = v_p.family_id and user_id = p_user_id
                and deleted_at is null and id <> v_p.id) then
      raise exception 'already_linked' using errcode = '22023';
    end if;
  end if;
  update public.family_persons set user_id = p_user_id, updated_by = v_uid, revision = revision + 1
   where id = p_person_id returning * into v_p;
  return v_p;
end;
$$;

-- Admin: soft-delete a person and every relation they are part of.
create or replace function public.delete_person(p_person_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_p public.family_persons%rowtype;
begin
  select * into v_p from public.family_persons where id = p_person_id for update;
  if v_p.id is null or not private.is_family_admin(v_p.family_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_p.deleted_at is not null then
    return;
  end if;
  update public.family_relations set deleted_at = now()
   where (person_a = p_person_id or person_b = p_person_id) and deleted_at is null;
  update public.family_persons set deleted_at = now(), user_id = null, updated_by = v_uid, revision = revision + 1
   where id = p_person_id;
  perform private.audit(v_p.family_id, 'tree.person_removed', 'person', v_p.id,
    jsonb_build_object('name', v_p.full_name), 'members');
end;
$$;

-- Validation shared by proposing and confirming a relation.
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
  select * into v_a from public.family_persons where id = p_rel.person_a and family_id = p_rel.family_id and deleted_at is null;
  select * into v_b from public.family_persons where id = p_rel.person_b and family_id = p_rel.family_id and deleted_at is null;
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
revoke all on function private.validate_relation(public.family_relations, boolean) from public;

-- Propose (member: pending) or add (owner/admin: confirmed) a relation.
-- kind 'parent': p_person_a is the parent of p_person_b.
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
  v_admin boolean;
  v_admins uuid[];
  v_actor text;
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
    if v_rel.family_id <> p_family_id then
      raise exception 'forbidden' using errcode = '42501';
    end if;
    return v_rel;  -- idempotent replay
  end if;
  v_admin := private.is_family_admin(p_family_id);
  perform private.enforce_rate_limit('propose_relation', 200, interval '1 hour');

  v_rel.id := p_id;
  v_rel.family_id := p_family_id;
  v_rel.kind := p_kind;
  v_rel.person_a := case when p_kind = 'spouse' then least(p_person_a, p_person_b) else p_person_a end;
  v_rel.person_b := case when p_kind = 'spouse' then greatest(p_person_a, p_person_b) else p_person_b end;
  v_rel.parent_type := case when p_kind = 'parent' then p_parent_type end;
  perform private.validate_relation(v_rel, v_admin);

  insert into public.family_relations (id, family_id, kind, person_a, person_b, parent_type, status, proposed_by,
                                       reviewed_by, reviewed_at)
  values (v_rel.id, p_family_id, p_kind, v_rel.person_a, v_rel.person_b, v_rel.parent_type,
          case when v_admin then 'confirmed' else 'pending' end, v_uid,
          case when v_admin then v_uid end, case when v_admin then now() end)
  returning * into v_rel;

  if not v_admin then
    select array_agg(user_id) into v_admins from public.family_members
     where family_id = p_family_id and status = 'active' and role in ('owner', 'admin');
    v_actor := private.display_name(v_uid);
    perform private.notify(
      v_admins, p_family_id, 'family_request', 'tree-proposal:' || v_rel.id,
      jsonb_build_object(
        'ms', jsonb_build_object('title', 'Salasilah', 'body', v_actor || ' mencadangkan hubungan baharu untuk disahkan'),
        'en', jsonb_build_object('title', 'Family tree', 'body', v_actor || ' proposed a new relation to confirm')),
      jsonb_build_object('route', '/family-tree', 'tag', 'tree', 'channel', 'family'),
      v_uid);
  end if;
  return v_rel;
end;
$$;

-- Owner/admin confirms or rejects a pending relation.
create or replace function public.review_relation(p_id uuid, p_approve boolean)
returns public.family_relations
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_rel public.family_relations%rowtype;
begin
  select * into v_rel from public.family_relations where id = p_id for update;
  if v_rel.id is null or not private.is_family_admin(v_rel.family_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_rel.deleted_at is not null or v_rel.status <> 'pending' then
    if v_rel.status = (case when p_approve then 'confirmed' else 'rejected' end) then
      return v_rel;  -- idempotent
    end if;
    raise exception 'not_pending' using errcode = '22023';
  end if;
  if p_approve then
    perform private.validate_relation(v_rel, true);
  end if;
  update public.family_relations
     set status = case when p_approve then 'confirmed' else 'rejected' end, reviewed_by = v_uid, reviewed_at = now()
   where id = p_id
  returning * into v_rel;
  return v_rel;
end;
$$;

-- Owner/admin removes any relation; a member may withdraw their own pending proposal.
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
  if v_rel.id is null or not private.is_family_member(v_rel.family_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_rel.deleted_at is not null then
    return;
  end if;
  if not (private.is_family_admin(v_rel.family_id)
          or (v_rel.proposed_by is not distinct from v_uid and v_rel.status = 'pending')) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.family_relations set deleted_at = now() where id = p_id;
end;
$$;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('upsert_person', 'link_person_account', 'delete_person', 'propose_relation',
                        'review_relation', 'delete_relation', 'relationship_between')
  loop
    execute format('revoke all on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated', r.sig);
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- Birthdays (daily, 08:05 Malaysia time): everyone in the family is told,
-- the person gets a greeting. Feb 29 birthdays are celebrated on Feb 28 in
-- common years. Uses the "events" notification preference.
-- -----------------------------------------------------------------------------
create or replace function private.dispatch_birthdays(p_today date default (now() at time zone 'Asia/Kuala_Lumpur')::date)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_count int := 0;
  v_members uuid[];
  v_leap boolean := (extract(year from p_today)::int % 4 = 0 and extract(year from p_today)::int % 100 <> 0)
                    or extract(year from p_today)::int % 400 = 0;
  v_age int;
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
    v_age := extract(year from p_today)::int - extract(year from r.birth_date)::int;
    select array_agg(user_id) into v_members from public.family_members
     where family_id = r.family_id and status = 'active' and user_id is distinct from r.user_id;
    v_count := v_count + private.notify(
      v_members, r.family_id, 'family_event', 'bday:' || r.id || ':' || extract(year from p_today)::int,
      jsonb_build_object(
        'ms', jsonb_build_object('title', 'Hari jadi hari ini 🎂', 'body', r.full_name || ' berumur ' || v_age || ' tahun hari ini'),
        'en', jsonb_build_object('title', 'Birthday today 🎂', 'body', r.full_name || ' turns ' || v_age || ' today')),
      jsonb_build_object('route', '/family-tree/' || r.id, 'tag', 'bday:' || r.id, 'channel', 'family'),
      null);
    if r.user_id is not null then
      v_count := v_count + private.notify(
        array[r.user_id], r.family_id, 'family_event', 'bday:' || r.id || ':' || extract(year from p_today)::int,
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

alter publication supabase_realtime add table public.family_persons;
alter publication supabase_realtime add table public.family_relations;

do $$
begin
  perform cron.schedule('familysync-birthdays', '5 0 * * *', 'select private.dispatch_birthdays()');
exception when others then
  raise notice 'pg_cron not available: %', sqlerrm;
end;
$$;
