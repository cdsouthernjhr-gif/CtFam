-- =============================================================================
-- FamilySync — Migration 20261123000500: Family calendar (Phase 5)
--
--   family_events        events (client UUID ids), optional recurrence
--   event_participants   invited members + RSVP (pending/going/maybe/declined)
--   event_reminders      per-participant reminders (minutes before start)
--
-- Design
--   * Visibility 'family' = every active family member can see the event;
--     'participants' = only the creator, participants and family owner/admin.
--   * Recurrence (daily/weekly/monthly/yearly) is expanded on the server by
--     private.event_occurrences() in the event's own time zone, always from the
--     first occurrence (no drift; DST-correct; Jan 31 + 1 month = Feb 28/29).
--     Single occurrences can be cancelled (cancelled_occurrences).
--   * Writes go through SECURITY DEFINER RPCs with idempotent creation and
--     revision-based conflict detection (P0409), like To-Do.
--   * Reminders are sent by pg_cron every minute through private.notify()
--     (preferences, quiet hours, dedupe, push queue from Phase 4).
-- =============================================================================

create table public.family_events (
  id                     uuid primary key,  -- client-generated for idempotent creation
  family_id              uuid not null references public.families (id) on delete cascade,
  title                  text not null check (char_length(btrim(title)) between 1 and 120),
  description            text check (description is null or char_length(description) <= 2000),
  location               text check (location is null or char_length(location) <= 200),
  category               text not null default 'family' check (category in
                           ('family', 'birthday', 'school', 'appointment', 'holiday', 'religious', 'work', 'other')),
  all_day                boolean not null default false,
  starts_at              timestamptz not null,
  ends_at                timestamptz not null,
  timezone               text not null default 'Asia/Kuala_Lumpur' check (char_length(timezone) between 1 and 64),
  recurrence             text not null default 'none' check (recurrence in ('none', 'daily', 'weekly', 'monthly', 'yearly')),
  recurrence_until       date,
  cancelled_occurrences  timestamptz[] not null default '{}',
  default_reminders      int[] not null default '{}',
  visibility             text not null default 'family' check (visibility in ('family', 'participants')),
  created_by             uuid references public.profiles (id) on delete set null,
  updated_by             uuid references public.profiles (id) on delete set null,
  revision               int not null default 1,
  deleted_at             timestamptz,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  check (ends_at >= starts_at),
  check (ends_at - starts_at <= interval '366 days'),
  check (recurrence <> 'none' or recurrence_until is null),
  check (cardinality(cancelled_occurrences) <= 500),
  check (cardinality(default_reminders) <= 5)
);
create index family_events_family_start_idx on public.family_events (family_id, starts_at) where deleted_at is null;
create index family_events_recurring_idx on public.family_events (family_id) where deleted_at is null and recurrence <> 'none';
create index family_events_created_by_idx on public.family_events (created_by);
create index family_events_updated_by_idx on public.family_events (updated_by);
create trigger family_events_set_updated_at before update on public.family_events
  for each row execute function private.set_updated_at();

create table public.event_participants (
  event_id      uuid not null references public.family_events (id) on delete cascade,
  user_id       uuid not null references public.profiles (id) on delete cascade,
  family_id     uuid not null references public.families (id) on delete cascade,
  rsvp          text not null default 'pending' check (rsvp in ('pending', 'going', 'maybe', 'declined')),
  responded_at  timestamptz,
  added_by      uuid references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now(),
  primary key (event_id, user_id)
);
create index event_participants_user_idx on public.event_participants (user_id);
create index event_participants_family_idx on public.event_participants (family_id);
create index event_participants_added_by_idx on public.event_participants (added_by);

create table public.event_reminders (
  event_id        uuid not null,
  user_id         uuid not null,
  minutes_before  int not null check (minutes_before between 0 and 40320),  -- up to 4 weeks
  created_at      timestamptz not null default now(),
  primary key (event_id, user_id, minutes_before),
  foreign key (event_id, user_id) references public.event_participants (event_id, user_id) on delete cascade
);
create index event_reminders_user_idx on public.event_reminders (user_id);

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------
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
      and private.family_role_of(e.family_id, p_user) is not null
      and (
        e.visibility = 'family'
        or e.created_by = p_user
        or private.family_role_of(e.family_id, p_user) in ('owner', 'admin')
        or exists (select 1 from public.event_participants p where p.event_id = e.id and p.user_id = p_user)
      )
  );
$$;

-- Read access includes soft-deleted rows so Realtime delivers deletions.
create or replace function private.can_read_event(p_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.event_visible_to(p_event_id, (select auth.uid()), true);
$$;

create or replace function private.can_access_event(p_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.event_visible_to(p_event_id, (select auth.uid()), false);
$$;

-- Edit / delete: creator or family owner/admin.
create or replace function private.can_manage_event(p_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.family_events e
    where e.id = p_event_id and e.deleted_at is null
      and private.is_family_member(e.family_id)
      and (e.created_by = (select auth.uid())
           or private.has_family_role(e.family_id, array['owner', 'admin']::public.family_role[]))
  );
$$;

revoke all on function private.event_visible_to(uuid, uuid, boolean) from public;
revoke all on function private.can_read_event(uuid) from public;
revoke all on function private.can_access_event(uuid) from public;
revoke all on function private.can_manage_event(uuid) from public;
grant execute on function private.can_read_event(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- Occurrence expansion. Returns occurrences overlapping [p_from, p_to).
-- n is bounded with conservative step lengths (DST, month lengths) and then
-- filtered exactly; at most 1000 candidates per call.
-- -----------------------------------------------------------------------------
create or replace function private.event_occurrences(
  p_starts_at timestamptz, p_ends_at timestamptz, p_tz text, p_rule text, p_until date,
  p_cancelled timestamptz[], p_from timestamptz, p_to timestamptz)
returns table (occurrence_start timestamptz, occurrence_end timestamptz)
language sql
stable
set search_path = ''
as $$
  with p as (
    select p_ends_at - p_starts_at as dur,
           p_starts_at at time zone p_tz as local_start,
           case p_rule when 'daily' then interval '1 day' when 'weekly' then interval '7 days'
                       when 'monthly' then interval '1 month' when 'yearly' then interval '1 year' end as step,
           case p_rule when 'daily' then 82800 when 'weekly' then 601200
                       when 'monthly' then 2415600 when 'yearly' then 31532400 end as min_s,
           case p_rule when 'daily' then 90000 when 'weekly' then 608400
                       when 'monthly' then 2682000 when 'yearly' then 31626000 end as max_s
  ), bounds as (
    select p.*,
           greatest(0, floor(extract(epoch from (p_from - p_starts_at - p.dur)) / p.max_s)::int - 1) as n0,
           ceil(extract(epoch from (p_to - p_starts_at)) / p.min_s)::int + 1 as n1
    from p where p_rule <> 'none'
  ), candidates as (
    select p_starts_at as s, p_ends_at - p_starts_at as dur where p_rule = 'none'
    union all
    select (b.local_start + b.step * n) at time zone p_tz, b.dur
    from bounds b, generate_series(b.n0, least(b.n1, b.n0 + 1000)) n
  )
  select c.s, c.s + c.dur
  from candidates c
  where c.s < p_to
    and (c.s + c.dur > p_from or c.s >= p_from)
    and (p_until is null or (c.s at time zone p_tz)::date <= p_until)
    and not (c.s = any (coalesce(p_cancelled, '{}')))
  order by c.s;
$$;
revoke all on function private.event_occurrences(timestamptz, timestamptz, text, text, date, timestamptz[], timestamptz, timestamptz) from public;
grant execute on function private.event_occurrences(timestamptz, timestamptz, text, text, date, timestamptz[], timestamptz, timestamptz) to authenticated;

create or replace function private.valid_timezone(p_tz text)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (select 1 from pg_catalog.pg_timezone_names where name = p_tz);
$$;

create or replace function private.clean_reminders(p_minutes int[])
returns int[]
language plpgsql
immutable
set search_path = ''
as $$
declare v int[];
begin
  select coalesce(array_agg(distinct m order by m), '{}') into v from unnest(coalesce(p_minutes, '{}')) m;
  if cardinality(v) > 5 or exists (select 1 from unnest(v) m where m is null or m < 0 or m > 40320) then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  return v;
end;
$$;

-- Adds/removes participants (manager only, called from upsert). The creator is
-- always kept. New participants get the event's default reminders.
create or replace function private.set_event_participants(p_event public.family_events, p_user_ids uuid[])
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_wanted uuid[];
  v_added uuid[];
  v_changed boolean := false;
  v_n int;
begin
  select coalesce(array_agg(distinct u), '{}') into v_wanted from unnest(coalesce(p_user_ids, '{}')) u where u is not null;
  if p_event.created_by is not null and not (p_event.created_by = any (v_wanted)) then
    v_wanted := v_wanted || p_event.created_by;
  end if;
  if cardinality(v_wanted) > 200 then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(v_wanted) u where private.family_role_of(p_event.family_id, u) is null) then
    raise exception 'not_family_member' using errcode = '22023';
  end if;

  delete from public.event_participants where event_id = p_event.id and not (user_id = any (v_wanted));
  get diagnostics v_n = row_count;
  v_changed := v_n > 0;

  with ins as (
    insert into public.event_participants (event_id, user_id, family_id, rsvp, responded_at, added_by)
    select p_event.id, u, p_event.family_id,
           case when u = v_uid then 'going' else 'pending' end,
           case when u = v_uid then now() end, v_uid
    from unnest(v_wanted) u
    on conflict (event_id, user_id) do nothing
    returning user_id
  )
  select coalesce(array_agg(user_id), '{}') into v_added from ins;
  if cardinality(v_added) > 0 then
    v_changed := true;
    insert into public.event_reminders (event_id, user_id, minutes_before)
    select p_event.id, a, m from unnest(v_added) a, unnest(p_event.default_reminders) m
    on conflict do nothing;
  end if;
  return v_changed;
end;
$$;
revoke all on function private.set_event_participants(public.family_events, uuid[]) from public;

-- =============================================================================
-- ROW LEVEL SECURITY
-- =============================================================================
alter table public.family_events      enable row level security;
alter table public.event_participants enable row level security;
alter table public.event_reminders    enable row level security;
revoke all on public.family_events, public.event_participants, public.event_reminders from anon, authenticated;

grant select on public.family_events to authenticated;
create policy family_events_select on public.family_events for select to authenticated
  using ((select private.can_read_event(id)));

grant select on public.event_participants to authenticated;
create policy event_participants_select on public.event_participants for select to authenticated
  using ((select private.can_read_event(event_id)));

grant select on public.event_reminders to authenticated;
create policy event_reminders_select on public.event_reminders for select to authenticated
  using (user_id = (select auth.uid()));

-- =============================================================================
-- RPCs
-- =============================================================================

-- upsert_family_event
--   * unknown p_id -> create (idempotent replay returns the existing row)
--   * known p_id   -> update (creator or owner/admin); stale p_expected_revision
--                     raises revision_conflict (P0409)
--   * p_participant_ids null = unchanged; p_reminder_minutes null = unchanged
--     (sets the event default and the caller's own reminders)
create or replace function public.upsert_family_event(
  p_id uuid,
  p_family_id uuid,
  p_title text,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_all_day boolean default false,
  p_timezone text default 'Asia/Kuala_Lumpur',
  p_description text default null,
  p_location text default null,
  p_category text default 'family',
  p_recurrence text default 'none',
  p_recurrence_until date default null,
  p_visibility text default 'family',
  p_participant_ids uuid[] default null,
  p_reminder_minutes int[] default null,
  p_expected_revision int default null)
returns public.family_events
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_ev public.family_events%rowtype;
  v_rem int[];
  v_changed boolean := false;
  v_tz text := coalesce(nullif(btrim(p_timezone), ''), 'Asia/Kuala_Lumpur');
  v_rule text := coalesce(p_recurrence, 'none');
  v_until date := case when coalesce(p_recurrence, 'none') = 'none' then null else p_recurrence_until end;
begin
  if p_id is null or p_starts_at is null or p_ends_at is null or p_ends_at < p_starts_at
     or char_length(btrim(coalesce(p_title, ''))) not between 1 and 120
     or not private.valid_timezone(v_tz)
     or (v_until is not null and v_until < (p_starts_at at time zone v_tz)::date) then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  v_rem := case when p_reminder_minutes is null then null else private.clean_reminders(p_reminder_minutes) end;

  select * into v_ev from public.family_events where id = p_id for update;

  if v_ev.id is null then
    if not private.is_family_member(p_family_id) then
      raise exception 'forbidden' using errcode = '42501';
    end if;
    perform private.enforce_rate_limit('create_event', 300, interval '1 hour');
    insert into public.family_events (id, family_id, title, description, location, category, all_day, starts_at,
                                      ends_at, timezone, recurrence, recurrence_until, visibility,
                                      default_reminders, created_by, updated_by)
    values (p_id, p_family_id, btrim(p_title), nullif(btrim(p_description), ''), nullif(btrim(p_location), ''),
            coalesce(p_category, 'family'), coalesce(p_all_day, false), p_starts_at, p_ends_at, v_tz, v_rule, v_until,
            coalesce(p_visibility, 'family'), coalesce(v_rem, '{}'), v_uid, v_uid)
    on conflict (id) do nothing
    returning * into v_ev;
    if v_ev.id is null then
      -- lost a race against a concurrent replay of the same create
      select * into v_ev from public.family_events where id = p_id;
      if v_ev.family_id is distinct from p_family_id or not private.can_read_event(p_id) then
        raise exception 'forbidden' using errcode = '42501';
      end if;
      return v_ev;
    end if;
    perform private.set_event_participants(v_ev, coalesce(p_participant_ids, '{}'));
    perform private.audit(v_ev.family_id, 'event.created', 'event', v_ev.id,
      jsonb_build_object('title', v_ev.title), 'members');
    return v_ev;
  end if;

  if v_ev.deleted_at is not null or not private.can_manage_event(v_ev.id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_family_id is distinct from v_ev.family_id then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  if p_expected_revision is not null and p_expected_revision <> v_ev.revision then
    raise exception 'revision_conflict' using errcode = 'P0409';
  end if;

  v_changed := (btrim(p_title), nullif(btrim(p_description), ''), nullif(btrim(p_location), ''),
                coalesce(p_category, 'family'), coalesce(p_all_day, false), p_starts_at, p_ends_at, v_tz, v_rule,
                v_until, coalesce(p_visibility, 'family'), coalesce(v_rem, v_ev.default_reminders))
               is distinct from
               (v_ev.title, v_ev.description, v_ev.location, v_ev.category, v_ev.all_day, v_ev.starts_at,
                v_ev.ends_at, v_ev.timezone, v_ev.recurrence, v_ev.recurrence_until, v_ev.visibility,
                v_ev.default_reminders);
  if v_changed then
    update public.family_events
       set title = btrim(p_title), description = nullif(btrim(p_description), ''),
           location = nullif(btrim(p_location), ''), category = coalesce(p_category, 'family'),
           all_day = coalesce(p_all_day, false), starts_at = p_starts_at, ends_at = p_ends_at, timezone = v_tz,
           recurrence = v_rule, recurrence_until = v_until, visibility = coalesce(p_visibility, 'family'),
           default_reminders = coalesce(v_rem, default_reminders),
           -- a new start time invalidates cancelled occurrences of the old series
           cancelled_occurrences = case when p_starts_at = starts_at and v_rule = recurrence
                                        then cancelled_occurrences else '{}' end,
           updated_by = v_uid, revision = revision + 1
     where id = p_id
    returning * into v_ev;
  end if;
  if p_participant_ids is not null and private.set_event_participants(v_ev, p_participant_ids) and not v_changed then
    update public.family_events set updated_by = v_uid, revision = revision + 1 where id = p_id returning * into v_ev;
    v_changed := true;
  end if;
  if v_rem is not null and exists (select 1 from public.event_participants where event_id = p_id and user_id = v_uid) then
    perform public.set_event_reminders(p_id, v_rem);
  end if;
  if v_changed then
    perform private.audit(v_ev.family_id, 'event.updated', 'event', v_ev.id,
      jsonb_build_object('title', v_ev.title), 'members');
  end if;
  return v_ev;
end;
$$;

create or replace function public.delete_family_event(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_ev public.family_events%rowtype;
begin
  select * into v_ev from public.family_events where id = p_id for update;
  if v_ev.id is null or not private.can_read_event(p_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_ev.deleted_at is not null then
    return;  -- idempotent
  end if;
  if not private.can_manage_event(p_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.family_events set deleted_at = now(), updated_by = v_uid, revision = revision + 1 where id = p_id;
  perform private.audit(v_ev.family_id, 'event.deleted', 'event', v_ev.id,
    jsonb_build_object('title', v_ev.title), 'members');
end;
$$;

-- Cancels one occurrence of a recurring event (idempotent).
create or replace function public.cancel_event_occurrence(p_id uuid, p_occurrence_start timestamptz)
returns public.family_events
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_ev public.family_events%rowtype;
begin
  select * into v_ev from public.family_events where id = p_id for update;
  if v_ev.id is null or not private.can_manage_event(p_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_occurrence_start = any (v_ev.cancelled_occurrences) then
    return v_ev;
  end if;
  if v_ev.recurrence = 'none' or not exists (
       select 1 from private.event_occurrences(v_ev.starts_at, v_ev.ends_at, v_ev.timezone, v_ev.recurrence,
                                               v_ev.recurrence_until, v_ev.cancelled_occurrences,
                                               p_occurrence_start, p_occurrence_start + interval '1 second') o
       where o.occurrence_start = p_occurrence_start) then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  update public.family_events
     set cancelled_occurrences = array_append(cancelled_occurrences, p_occurrence_start),
         updated_by = v_uid, revision = revision + 1
   where id = p_id
  returning * into v_ev;
  return v_ev;
end;
$$;

-- RSVP. Any member who can see the event may respond (joining it if needed).
create or replace function public.set_event_rsvp(p_event_id uuid, p_rsvp text)
returns public.event_participants
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_ev public.family_events%rowtype;
  v_row public.event_participants%rowtype;
  v_existed boolean;
begin
  if p_rsvp not in ('going', 'maybe', 'declined') then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  select * into v_ev from public.family_events where id = p_event_id;
  if v_ev.id is null or not private.can_access_event(p_event_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_existed := exists (select 1 from public.event_participants where event_id = p_event_id and user_id = v_uid);
  insert into public.event_participants (event_id, user_id, family_id, rsvp, responded_at, added_by)
  values (p_event_id, v_uid, v_ev.family_id, p_rsvp, now(), v_uid)
  on conflict (event_id, user_id) do update
    set rsvp = excluded.rsvp,
        responded_at = case when event_participants.rsvp = excluded.rsvp then event_participants.responded_at
                            else excluded.responded_at end
  returning * into v_row;
  if not v_existed then
    insert into public.event_reminders (event_id, user_id, minutes_before)
    select p_event_id, v_uid, m from unnest(v_ev.default_reminders) m
    on conflict do nothing;
  end if;
  return v_row;
end;
$$;

-- Replaces the caller's own reminders for an event (participants only).
create or replace function public.set_event_reminders(p_event_id uuid, p_minutes int[])
returns int[]
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_rem int[] := private.clean_reminders(p_minutes);
begin
  if not private.can_access_event(p_event_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not exists (select 1 from public.event_participants where event_id = p_event_id and user_id = v_uid) then
    raise exception 'not_participant' using errcode = '22023';
  end if;
  delete from public.event_reminders where event_id = p_event_id and user_id = v_uid and not (minutes_before = any (v_rem));
  insert into public.event_reminders (event_id, user_id, minutes_before)
  select p_event_id, v_uid, m from unnest(v_rem) m on conflict do nothing;
  return v_rem;
end;
$$;

-- Occurrences of the caller's visible events in [p_from, p_to) (max 400 days).
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
    where e.family_id = p_family_id
      and e.deleted_at is null
      and e.starts_at < p_to
      and (e.recurrence <> 'none' or e.ends_at >= p_from)
      and (e.recurrence_until is null or e.recurrence_until >= (p_from - interval '1 day')::date)
    order by o.occurrence_start, e.id;
end;
$$;

revoke all on function public.upsert_family_event(uuid, uuid, text, timestamptz, timestamptz, boolean, text, text, text, text, text, date, text, uuid[], int[], int) from public, anon;
revoke all on function public.delete_family_event(uuid) from public, anon;
revoke all on function public.cancel_event_occurrence(uuid, timestamptz) from public, anon;
revoke all on function public.set_event_rsvp(uuid, text) from public, anon;
revoke all on function public.set_event_reminders(uuid, int[]) from public, anon;
revoke all on function public.calendar_occurrences(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.upsert_family_event(uuid, uuid, text, timestamptz, timestamptz, boolean, text, text, text, text, text, date, text, uuid[], int[], int) to authenticated;
grant execute on function public.delete_family_event(uuid) to authenticated;
grant execute on function public.cancel_event_occurrence(uuid, timestamptz) to authenticated;
grant execute on function public.set_event_rsvp(uuid, text) to authenticated;
grant execute on function public.set_event_reminders(uuid, int[]) to authenticated;
grant execute on function public.calendar_occurrences(uuid, timestamptz, timestamptz) to authenticated;

-- =============================================================================
-- Notifications
-- =============================================================================
create or replace function private.event_when_text(p_start timestamptz, p_tz text, p_all_day boolean)
returns text
language sql
stable
set search_path = ''
as $$
  select case when p_all_day then to_char(p_start at time zone p_tz, 'DD/MM/YYYY')
              else to_char(p_start at time zone p_tz, 'DD/MM/YYYY HH24:MI') end;
$$;

-- Invitation: a participant added by someone else.
create or replace function private.on_event_participant_notify()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ev public.family_events%rowtype;
  v_actor text := private.display_name(new.added_by);
  v_when text;
begin
  if new.added_by is null or new.added_by = new.user_id then
    return new;
  end if;
  select * into v_ev from public.family_events where id = new.event_id;
  v_when := private.event_when_text(v_ev.starts_at, v_ev.timezone, v_ev.all_day);
  perform private.notify(
    array[new.user_id], new.family_id, 'family_event', 'event-invite:' || new.event_id || ':' || new.user_id,
    jsonb_build_object(
      'ms', jsonb_build_object('title', 'Jemputan acara', 'body', v_actor || ' menjemput anda ke "' || v_ev.title || '" · ' || v_when),
      'en', jsonb_build_object('title', 'Event invitation', 'body', v_actor || ' invited you to "' || v_ev.title || '" · ' || v_when)),
    jsonb_build_object('route', '/calendar/' || new.event_id, 'tag', 'event:' || new.event_id, 'channel', 'family'),
    new.added_by);
  return new;
end;
$$;
create trigger event_participants_notify after insert on public.event_participants
  for each row execute function private.on_event_participant_notify();

-- Changed time/place/title, or cancelled: tell participants who did not decline.
create or replace function private.on_event_change_notify()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_recipients uuid[];
  v_actor text := private.display_name(new.updated_by);
  v_when text := private.event_when_text(new.starts_at, new.timezone, new.all_day);
  v_texts jsonb;
  v_key text;
begin
  if old.deleted_at is null and new.deleted_at is not null then
    v_key := 'event-del:' || new.id;
    v_texts := jsonb_build_object(
      'ms', jsonb_build_object('title', 'Acara dibatalkan', 'body', v_actor || ' membatalkan "' || new.title || '"'),
      'en', jsonb_build_object('title', 'Event cancelled', 'body', v_actor || ' cancelled "' || new.title || '"'));
  elsif new.deleted_at is null and (new.title, new.starts_at, new.ends_at, new.location, new.all_day, new.recurrence,
                                    new.recurrence_until, new.cancelled_occurrences)
        is distinct from (old.title, old.starts_at, old.ends_at, old.location, old.all_day, old.recurrence,
                          old.recurrence_until, old.cancelled_occurrences) then
    v_key := 'event-upd:' || new.id || ':' || new.revision;
    v_texts := jsonb_build_object(
      'ms', jsonb_build_object('title', 'Acara dikemas kini', 'body', v_actor || ' mengemas kini "' || new.title || '" · ' || v_when),
      'en', jsonb_build_object('title', 'Event updated', 'body', v_actor || ' updated "' || new.title || '" · ' || v_when));
  else
    return new;
  end if;
  select array_agg(user_id) into v_recipients from public.event_participants
   where event_id = new.id and rsvp <> 'declined';
  perform private.notify(
    v_recipients, new.family_id, 'family_event', v_key, v_texts,
    jsonb_build_object('route', case when new.deleted_at is null then '/calendar/' || new.id else '/calendar' end,
                       'tag', 'event:' || new.id, 'channel', 'family'),
    new.updated_by);
  return new;
end;
$$;
create trigger family_events_notify after update on public.family_events
  for each row execute function private.on_event_change_notify();

-- Reminders (pg_cron, every minute). A 10-minute look-back tolerates late
-- runs; the dedupe key makes every reminder fire at most once.
create or replace function private.dispatch_event_reminders(p_now timestamptz default now())
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_count int := 0;
  v_when text;
  v_loc text;
begin
  for r in
    select e.id, e.family_id, e.title, e.location, e.timezone, e.all_day, rem.user_id, rem.minutes_before,
           o.occurrence_start
    from public.event_reminders rem
    join public.event_participants ep on ep.event_id = rem.event_id and ep.user_id = rem.user_id and ep.rsvp <> 'declined'
    join public.family_events e on e.id = rem.event_id and e.deleted_at is null
    cross join lateral private.event_occurrences(
      e.starts_at, e.ends_at, e.timezone, e.recurrence, e.recurrence_until, e.cancelled_occurrences,
      p_now - interval '10 minutes' + make_interval(mins => rem.minutes_before),
      p_now + make_interval(mins => rem.minutes_before) + interval '1 second') o
    where e.starts_at <= p_now + interval '28 days 1 minute'
      and (e.recurrence <> 'none' or e.starts_at > p_now - interval '10 minutes')
      and (e.recurrence_until is null or e.recurrence_until >= (p_now - interval '1 day')::date)
      and o.occurrence_start > p_now - interval '10 minutes' + make_interval(mins => rem.minutes_before)
      and o.occurrence_start <= p_now + make_interval(mins => rem.minutes_before)
      and private.event_visible_to(e.id, rem.user_id, false)
  loop
    v_when := private.event_when_text(r.occurrence_start, r.timezone, r.all_day);
    v_loc := case when r.location is not null then ' · ' || r.location else '' end;
    v_count := v_count + private.notify(
      array[r.user_id], r.family_id, 'family_event',
      'remind:' || r.id || ':' || extract(epoch from r.occurrence_start)::bigint || ':' || r.minutes_before,
      jsonb_build_object(
        'ms', jsonb_build_object('title', 'Peringatan acara', 'body', r.title || ' · ' || v_when || v_loc),
        'en', jsonb_build_object('title', 'Event reminder', 'body', r.title || ' · ' || v_when || v_loc)),
      jsonb_build_object('route', '/calendar/' || r.id, 'tag', 'remind:' || r.id, 'channel', 'family'),
      null);
  end loop;
  return v_count;
end;
$$;
revoke all on function private.dispatch_event_reminders(timestamptz) from public;

-- =============================================================================
-- Realtime + schedule
-- =============================================================================
alter publication supabase_realtime add table public.family_events;
alter publication supabase_realtime add table public.event_participants;

do $$
begin
  perform cron.schedule('familysync-event-reminders', '* * * * *', 'select private.dispatch_event_reminders()');
exception when others then
  raise notice 'pg_cron not available: %', sqlerrm;
end;
$$;
