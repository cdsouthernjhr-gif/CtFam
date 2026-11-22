-- =============================================================================
-- FamilySync — Migration 0100: Foundation
--   * private helper schema (not exposed through the Data API)
--   * profiles, families, family_members
--   * invitations, invitation_uses, invitation_attempts
--   * audit_logs, device_tokens, user_preferences
--   * rate limiting
--   * transactional SECURITY DEFINER RPCs for every privileged operation
--
-- Security model
--   * RLS is enabled on every table in `public`.
--   * Membership / role changes are NEVER made with direct table writes from the
--     client. There are no INSERT/UPDATE/DELETE policies on family_members,
--     invitations or invitation_uses; all such writes go through the RPCs below,
--     which verify the caller's role from the database (never from JWT
--     user_metadata).
--   * All SECURITY DEFINER functions use `set search_path = ''` and fully
--     qualified names, and EXECUTE is revoked from PUBLIC/anon.
-- =============================================================================

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Enumerations
-- -----------------------------------------------------------------------------
create type public.family_role as enum ('owner', 'admin', 'moderator', 'member');
create type public.member_status as enum ('pending', 'active', 'suspended', 'removed', 'left');

-- -----------------------------------------------------------------------------
-- Generic helpers
-- -----------------------------------------------------------------------------
create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- Numeric rank used for "may act on" comparisons. Higher = more privileged.
create or replace function private.role_rank(r public.family_role)
returns int
language sql
immutable
set search_path = ''
as $$
  select case r
    when 'owner' then 4
    when 'admin' then 3
    when 'moderator' then 2
    when 'member' then 1
  end;
$$;

-- -----------------------------------------------------------------------------
-- profiles
-- -----------------------------------------------------------------------------
create table public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  display_name  text not null check (char_length(btrim(display_name)) between 1 and 60),
  avatar_path   text check (avatar_path is null or char_length(avatar_path) <= 512),
  phone         text check (phone is null or phone ~ '^\+?[0-9 ()-]{6,20}$'),
  bio           text check (bio is null or char_length(bio) <= 280),
  locale        text not null default 'ms' check (locale in ('ms', 'en')),
  last_seen_at  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function private.set_updated_at();

-- Create a profile automatically for each new auth user.
-- display_name from raw_user_meta_data is ONLY used as a cosmetic default; it is
-- never used for authorization.
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text;
begin
  v_name := left(btrim(coalesce(new.raw_user_meta_data ->> 'display_name', '')), 60);
  if v_name = '' then
    v_name := left(split_part(coalesce(new.email, 'Ahli'), '@', 1), 60);
  end if;
  insert into public.profiles (id, display_name)
  values (new.id, v_name)
  on conflict (id) do nothing;
  insert into public.user_preferences (user_id) values (new.id)
  on conflict (user_id) do nothing;
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- families
-- -----------------------------------------------------------------------------
create table public.families (
  id                         uuid primary key default gen_random_uuid(),
  name                       text not null check (char_length(btrim(name)) between 2 and 80),
  description                text check (description is null or char_length(description) <= 500),
  image_path                 text check (image_path is null or char_length(image_path) <= 512),
  created_by                 uuid references auth.users (id) on delete set null,
  require_invite_approval    boolean not null default false,
  allow_admin_invites        boolean not null default true,
  max_members                int not null default 200 check (max_members between 2 and 1000),
  deleted_at                 timestamptz,
  created_at                 timestamptz not null default now(),
  updated_at                 timestamptz not null default now()
);

create trigger families_set_updated_at
  before update on public.families
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- family_members
-- -----------------------------------------------------------------------------
create table public.family_members (
  id            uuid primary key default gen_random_uuid(),
  family_id     uuid not null references public.families (id) on delete cascade,
  -- references profiles (which cascades from auth.users) so PostgREST can embed
  -- the member's profile in a single query.
  user_id       uuid not null references public.profiles (id) on delete cascade,
  role          public.family_role not null default 'member',
  status        public.member_status not null default 'active',
  nickname      text check (nickname is null or char_length(nickname) <= 40),
  invited_by    uuid references auth.users (id) on delete set null,
  joined_at     timestamptz,
  status_changed_at timestamptz not null default now(),
  status_changed_by uuid references auth.users (id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (family_id, user_id)
);

-- Exactly one active owner per family.
create unique index family_members_one_owner
  on public.family_members (family_id)
  where role = 'owner' and status = 'active';

create index family_members_user_active_idx
  on public.family_members (user_id, family_id)
  where status = 'active';

create index family_members_family_status_idx
  on public.family_members (family_id, status);

create trigger family_members_set_updated_at
  before update on public.family_members
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- Membership helper functions (used by RLS policies).
-- SECURITY DEFINER avoids recursive RLS evaluation on family_members.
-- -----------------------------------------------------------------------------
create or replace function private.is_family_member(p_family_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.family_members fm
    join public.families f on f.id = fm.family_id
    where fm.family_id = p_family_id
      and fm.user_id = (select auth.uid())
      and fm.status = 'active'
      and f.deleted_at is null
  );
$$;

create or replace function private.family_role_of(p_family_id uuid, p_user_id uuid)
returns public.family_role
language sql
stable
security definer
set search_path = ''
as $$
  select fm.role
  from public.family_members fm
  join public.families f on f.id = fm.family_id
  where fm.family_id = p_family_id
    and fm.user_id = p_user_id
    and fm.status = 'active'
    and f.deleted_at is null;
$$;

create or replace function private.has_family_role(p_family_id uuid, p_roles public.family_role[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(private.family_role_of(p_family_id, (select auth.uid())) = any (p_roles), false);
$$;

-- True when the caller and p_other share at least one active family.
create or replace function private.shares_family_with(p_other uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.family_members me
    join public.family_members other
      on other.family_id = me.family_id
     and other.user_id = p_other
     and other.status in ('active', 'pending')
    join public.families f on f.id = me.family_id and f.deleted_at is null
    where me.user_id = (select auth.uid())
      and me.status = 'active'
  );
$$;

create or replace function private.my_family_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select fm.family_id
  from public.family_members fm
  join public.families f on f.id = fm.family_id and f.deleted_at is null
  where fm.user_id = (select auth.uid())
    and fm.status = 'active';
$$;

revoke all on function private.is_family_member(uuid) from public;
revoke all on function private.family_role_of(uuid, uuid) from public;
revoke all on function private.has_family_role(uuid, public.family_role[]) from public;
revoke all on function private.shares_family_with(uuid) from public;
revoke all on function private.my_family_ids() from public;
grant execute on function private.is_family_member(uuid) to authenticated;
grant execute on function private.family_role_of(uuid, uuid) to authenticated;
grant execute on function private.has_family_role(uuid, public.family_role[]) to authenticated;
grant execute on function private.shares_family_with(uuid) to authenticated;
grant execute on function private.my_family_ids() to authenticated;

-- -----------------------------------------------------------------------------
-- invitations
-- The raw token is returned exactly once by create_invitation(); only its
-- SHA-256 hash is stored.
-- -----------------------------------------------------------------------------
create table public.invitations (
  id                 uuid primary key default gen_random_uuid(),
  family_id          uuid not null references public.families (id) on delete cascade,
  token_hash         bytea not null unique check (octet_length(token_hash) = 32),
  token_hint         text not null check (char_length(token_hint) = 4),
  created_by         uuid references auth.users (id) on delete set null,
  note               text check (note is null or char_length(note) <= 120),
  max_uses           int not null default 1 check (max_uses between 1 and 500),
  use_count          int not null default 0 check (use_count >= 0),
  requires_approval  boolean not null default false,
  expires_at         timestamptz not null,
  revoked_at         timestamptz,
  revoked_by         uuid references auth.users (id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  check (use_count <= max_uses),
  check (expires_at > created_at)
);

create index invitations_family_idx on public.invitations (family_id, created_at desc);

create trigger invitations_set_updated_at
  before update on public.invitations
  for each row execute function private.set_updated_at();

create table public.invitation_uses (
  id             uuid primary key default gen_random_uuid(),
  invitation_id  uuid not null references public.invitations (id) on delete cascade,
  family_id      uuid not null references public.families (id) on delete cascade,
  user_id        uuid not null references public.profiles (id) on delete cascade,
  outcome        text not null check (outcome in ('joined', 'pending_approval', 'rejoined')),
  created_at     timestamptz not null default now(),
  unique (invitation_id, user_id)
);

create index invitation_uses_family_idx on public.invitation_uses (family_id, created_at desc);

-- Every redemption attempt (successful or not) — used for brute-force limiting.
create table private.invitation_attempts (
  id          bigint generated always as identity primary key,
  user_id     uuid not null,
  success     boolean not null,
  created_at  timestamptz not null default now()
);
create index invitation_attempts_user_idx on private.invitation_attempts (user_id, created_at desc);

-- -----------------------------------------------------------------------------
-- Generic rate limiting (fixed-window counter per user + action)
-- -----------------------------------------------------------------------------
create table private.rate_limit_events (
  id          bigint generated always as identity primary key,
  user_id     uuid not null,
  action      text not null,
  created_at  timestamptz not null default now()
);
create index rate_limit_events_idx on private.rate_limit_events (user_id, action, created_at desc);

create or replace function private.enforce_rate_limit(p_action text, p_max int, p_window interval)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_count int;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  select count(*) into v_count
  from private.rate_limit_events
  where user_id = v_uid and action = p_action and created_at > now() - p_window;
  if v_count >= p_max then
    raise exception 'rate_limited' using errcode = 'P0429',
      hint = format('Too many %s requests; try again later.', p_action);
  end if;
  insert into private.rate_limit_events (user_id, action) values (v_uid, p_action);
end;
$$;
revoke all on function private.enforce_rate_limit(text, int, interval) from public;

-- -----------------------------------------------------------------------------
-- audit_logs (family activity history + administrative audit trail)
-- -----------------------------------------------------------------------------
create table public.audit_logs (
  id           uuid primary key default gen_random_uuid(),
  family_id    uuid references public.families (id) on delete cascade,
  actor_id     uuid references public.profiles (id) on delete set null,
  action       text not null check (char_length(action) between 1 and 64),
  target_type  text check (target_type is null or char_length(target_type) <= 40),
  target_id    uuid,
  details      jsonb not null default '{}'::jsonb,
  -- 'members' entries appear in the family activity feed; 'admins' entries are
  -- visible to owner/admin only.
  visibility   text not null default 'admins' check (visibility in ('members', 'admins')),
  created_at   timestamptz not null default now()
);
create index audit_logs_family_idx on public.audit_logs (family_id, created_at desc);

create or replace function private.audit(
  p_family_id uuid, p_action text, p_target_type text, p_target_id uuid,
  p_details jsonb default '{}'::jsonb, p_visibility text default 'admins')
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.audit_logs (family_id, actor_id, action, target_type, target_id, details, visibility)
  values (p_family_id, auth.uid(), p_action, p_target_type, p_target_id, coalesce(p_details, '{}'::jsonb), p_visibility);
$$;
revoke all on function private.audit(uuid, text, text, uuid, jsonb, text) from public;

-- -----------------------------------------------------------------------------
-- device_tokens (FCM)
-- -----------------------------------------------------------------------------
create table public.device_tokens (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  token         text not null unique check (char_length(token) between 20 and 4096),
  platform      text not null default 'android' check (platform in ('android')),
  device_name   text check (device_name is null or char_length(device_name) <= 100),
  app_version   text check (app_version is null or char_length(app_version) <= 40),
  last_seen_at  timestamptz not null default now(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index device_tokens_user_idx on public.device_tokens (user_id);

create trigger device_tokens_set_updated_at
  before update on public.device_tokens
  for each row execute function private.set_updated_at();

-- -----------------------------------------------------------------------------
-- user_preferences
-- -----------------------------------------------------------------------------
create table public.user_preferences (
  user_id                   uuid primary key references auth.users (id) on delete cascade,
  active_family_id          uuid references public.families (id) on delete set null,
  notify_private_messages   boolean not null default true,
  notify_group_messages     boolean not null default true,
  notify_tasks              boolean not null default true,
  notify_events             boolean not null default true,
  notify_announcements      boolean not null default true,
  -- Hide message content on the lock screen by default (privacy).
  show_message_preview      boolean not null default false,
  quiet_hours_start         time,
  quiet_hours_end           time,
  theme_mode                text not null default 'system' check (theme_mode in ('system', 'light', 'dark')),
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now()
);

create trigger user_preferences_set_updated_at
  before update on public.user_preferences
  for each row execute function private.set_updated_at();

-- Now that user_preferences exists, attach the auth trigger.
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

-- =============================================================================
-- ROW LEVEL SECURITY
-- =============================================================================
alter table public.profiles          enable row level security;
alter table public.families          enable row level security;
alter table public.family_members    enable row level security;
alter table public.invitations       enable row level security;
alter table public.invitation_uses   enable row level security;
alter table public.audit_logs        enable row level security;
alter table public.device_tokens     enable row level security;
alter table public.user_preferences  enable row level security;

-- Table privileges: start from nothing, grant only what policies need.
revoke all on public.profiles, public.families, public.family_members, public.invitations,
  public.invitation_uses, public.audit_logs, public.device_tokens, public.user_preferences
  from anon, authenticated;

-- profiles --------------------------------------------------------------------
grant select on public.profiles to authenticated;
grant update (display_name, avatar_path, phone, bio, locale, last_seen_at) on public.profiles to authenticated;

create policy profiles_select_self_or_family on public.profiles
  for select to authenticated
  using (id = (select auth.uid()) or (select private.shares_family_with(id)));

create policy profiles_update_self on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (
    id = (select auth.uid())
    -- avatar must live in the caller's own folder of the avatars bucket
    and (avatar_path is null or avatar_path like ((select auth.uid())::text || '/%'))
  );
-- No INSERT (trigger creates profiles) and no DELETE (cascade from auth.users).

-- families --------------------------------------------------------------------
grant select on public.families to authenticated;
grant update (name, description, image_path, require_invite_approval, allow_admin_invites) on public.families to authenticated;

create policy families_select_member on public.families
  for select to authenticated
  using (deleted_at is null and (select private.is_family_member(id)));

create policy families_update_admin on public.families
  for update to authenticated
  using (deleted_at is null and (select private.has_family_role(id, array['owner', 'admin']::public.family_role[])))
  with check (
    deleted_at is null
    and (select private.has_family_role(id, array['owner', 'admin']::public.family_role[]))
    and (image_path is null or image_path like (id::text || '/%'))
  );
-- INSERT via create_family(); DELETE via delete_family() (soft delete).

-- family_members --------------------------------------------------------------
grant select on public.family_members to authenticated;
grant update (nickname) on public.family_members to authenticated;

create policy family_members_select on public.family_members
  for select to authenticated
  using (
    user_id = (select auth.uid())
    or (select private.is_family_member(family_id))
  );

-- Members may only edit their own nickname. Role/status columns are not granted.
create policy family_members_update_own_nickname on public.family_members
  for update to authenticated
  using (user_id = (select auth.uid()) and status = 'active')
  with check (user_id = (select auth.uid()));

-- invitations -----------------------------------------------------------------
grant select on public.invitations to authenticated;

create policy invitations_select_managers on public.invitations
  for select to authenticated
  using ((select private.has_family_role(family_id, array['owner', 'admin']::public.family_role[])));

-- invitation_uses -------------------------------------------------------------
grant select on public.invitation_uses to authenticated;

create policy invitation_uses_select on public.invitation_uses
  for select to authenticated
  using (
    user_id = (select auth.uid())
    or (select private.has_family_role(family_id, array['owner', 'admin']::public.family_role[]))
  );

-- audit_logs ------------------------------------------------------------------
grant select on public.audit_logs to authenticated;

create policy audit_logs_select on public.audit_logs
  for select to authenticated
  using (
    family_id is not null and (
      (visibility = 'members' and (select private.is_family_member(family_id)))
      or (select private.has_family_role(family_id, array['owner', 'admin']::public.family_role[]))
    )
  );

-- device_tokens ---------------------------------------------------------------
grant select, delete on public.device_tokens to authenticated;

create policy device_tokens_select_own on public.device_tokens
  for select to authenticated using (user_id = (select auth.uid()));
create policy device_tokens_delete_own on public.device_tokens
  for delete to authenticated using (user_id = (select auth.uid()));
-- INSERT/UPDATE via register_device_token() so a token can move between
-- accounts on the same physical device.

-- user_preferences ------------------------------------------------------------
grant select, update (active_family_id, notify_private_messages, notify_group_messages, notify_tasks,
  notify_events, notify_announcements, show_message_preview, quiet_hours_start, quiet_hours_end, theme_mode)
  on public.user_preferences to authenticated;

create policy user_preferences_select_own on public.user_preferences
  for select to authenticated using (user_id = (select auth.uid()));
create policy user_preferences_update_own on public.user_preferences
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (
    user_id = (select auth.uid())
    and (active_family_id is null or (select private.is_family_member(active_family_id)))
  );

-- =============================================================================
-- RPCs (SECURITY DEFINER, transactional)
-- =============================================================================

-- Internal: raise when the caller is not authenticated. Returns the uid.
create or replace function private.require_uid()
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare v uuid := auth.uid();
begin
  if v is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  return v;
end;
$$;
revoke all on function private.require_uid() from public;

-- Generates a URL-safe invitation code: 16 chars of Crockford base32 (80 bits).
create or replace function private.generate_invite_code()
returns text
language plpgsql
volatile
set search_path = ''
as $$
declare
  alphabet constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  bytes bytea := extensions.gen_random_bytes(16);
  out text := '';
  i int;
begin
  -- 16 random bytes, each reduced mod 32: 256 is a multiple of 32 so there is
  -- no modulo bias. 16 symbols * 5 bits = 80 bits of entropy.
  for i in 0..15 loop
    out := out || substr(alphabet, (get_byte(bytes, i) % 32) + 1, 1);
  end loop;
  return out;
end;
$$;
revoke all on function private.generate_invite_code() from public;

-- Normalises user input: uppercase, strip separators, map ambiguous chars.
create or replace function private.normalize_invite_code(p_code text)
returns text
language sql
immutable
set search_path = ''
as $$
  select translate(upper(regexp_replace(coalesce(p_code, ''), '[^0-9A-Za-z]', '', 'g')), 'OIL', '011');
$$;

create or replace function private.hash_invite_code(p_code text)
returns bytea
language sql
immutable
set search_path = ''
as $$
  select sha256(convert_to('familysync:invite:' || private.normalize_invite_code(p_code), 'UTF8'));
$$;

-- ---------------------------------------------------------------------------
-- create_family(name, description) -> families row id
-- ---------------------------------------------------------------------------
create or replace function public.create_family(p_name text, p_description text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_family_id uuid;
begin
  perform private.enforce_rate_limit('create_family', 5, interval '1 day');

  insert into public.families (name, description, created_by)
  values (btrim(p_name), nullif(btrim(p_description), ''), v_uid)
  returning id into v_family_id;

  insert into public.family_members (family_id, user_id, role, status, joined_at, status_changed_by)
  values (v_family_id, v_uid, 'owner', 'active', now(), v_uid);

  update public.user_preferences set active_family_id = v_family_id
  where user_id = v_uid and active_family_id is null;

  perform private.audit(v_family_id, 'family.created', 'family', v_family_id,
    jsonb_build_object('name', btrim(p_name)), 'members');
  return v_family_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- delete_family(family_id, confirm_name): owner only, soft delete.
-- ---------------------------------------------------------------------------
create or replace function public.delete_family(p_family_id uuid, p_confirm_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_name text;
begin
  if not private.has_family_role(p_family_id, array['owner']::public.family_role[]) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select name into v_name from public.families where id = p_family_id for update;
  if v_name is distinct from btrim(p_confirm_name) then
    raise exception 'confirmation_mismatch' using errcode = '22023';
  end if;
  update public.families set deleted_at = now() where id = p_family_id;
  update public.invitations set revoked_at = now(), revoked_by = v_uid
    where family_id = p_family_id and revoked_at is null;
  update public.user_preferences set active_family_id = null where active_family_id = p_family_id;
  perform private.audit(p_family_id, 'family.deleted', 'family', p_family_id, '{}'::jsonb, 'admins');
end;
$$;

-- ---------------------------------------------------------------------------
-- create_invitation(...) -> (invitation_id, code, expires_at)
-- The plaintext code is returned ONCE and never stored.
-- ---------------------------------------------------------------------------
create or replace function public.create_invitation(
  p_family_id uuid,
  p_max_uses int default 1,
  p_expires_in_hours int default 72,
  p_requires_approval boolean default null,
  p_note text default null)
returns table (invitation_id uuid, code text, expires_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_role public.family_role;
  v_family public.families%rowtype;
  v_code text;
  v_id uuid;
  v_expires timestamptz;
begin
  v_role := private.family_role_of(p_family_id, v_uid);
  select * into v_family from public.families where id = p_family_id and deleted_at is null;
  if v_role is null or v_family.id is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not (v_role = 'owner' or (v_role = 'admin' and v_family.allow_admin_invites)) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_max_uses is null or p_max_uses < 1 or p_max_uses > 500 then
    raise exception 'invalid_max_uses' using errcode = '22023';
  end if;
  if p_expires_in_hours is null or p_expires_in_hours < 1 or p_expires_in_hours > 24 * 30 then
    raise exception 'invalid_expiry' using errcode = '22023';
  end if;

  perform private.enforce_rate_limit('create_invitation', 30, interval '1 hour');

  v_code := private.generate_invite_code();
  v_expires := now() + make_interval(hours => p_expires_in_hours);

  insert into public.invitations (family_id, token_hash, token_hint, created_by, note, max_uses,
    requires_approval, expires_at)
  values (p_family_id, private.hash_invite_code(v_code), right(v_code, 4), v_uid,
    nullif(btrim(p_note), ''), p_max_uses,
    coalesce(p_requires_approval, v_family.require_invite_approval), v_expires)
  returning id into v_id;

  perform private.audit(p_family_id, 'invitation.created', 'invitation', v_id,
    jsonb_build_object('max_uses', p_max_uses, 'expires_at', v_expires), 'admins');

  invitation_id := v_id;
  code := v_code;
  expires_at := v_expires;
  return next;
end;
$$;

-- ---------------------------------------------------------------------------
-- revoke_invitation(id)
-- ---------------------------------------------------------------------------
create or replace function public.revoke_invitation(p_invitation_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_family_id uuid;
begin
  select family_id into v_family_id from public.invitations where id = p_invitation_id for update;
  if v_family_id is null
     or not private.has_family_role(v_family_id, array['owner', 'admin']::public.family_role[]) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.invitations
     set revoked_at = coalesce(revoked_at, now()), revoked_by = coalesce(revoked_by, v_uid)
   where id = p_invitation_id;
  perform private.audit(v_family_id, 'invitation.revoked', 'invitation', p_invitation_id, '{}'::jsonb, 'admins');
end;
$$;

-- ---------------------------------------------------------------------------
-- preview_invitation(code): lets an authenticated user see which family a code
-- belongs to before joining. Reveals only the family name and member count.
-- ---------------------------------------------------------------------------
create or replace function public.preview_invitation(p_code text)
returns table (family_name text, member_count int, requires_approval boolean, expires_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
begin
  perform private.enforce_rate_limit('preview_invitation', 20, interval '15 minutes');
  return query
    select f.name,
           (select count(*)::int from public.family_members m where m.family_id = f.id and m.status = 'active'),
           i.requires_approval,
           i.expires_at
    from public.invitations i
    join public.families f on f.id = i.family_id and f.deleted_at is null
    where i.token_hash = private.hash_invite_code(p_code)
      and i.revoked_at is null
      and i.expires_at > now()
      and i.use_count < i.max_uses;
end;
$$;

-- ---------------------------------------------------------------------------
-- redeem_invitation(code) -> jsonb { status, family_id }
--
-- status is one of: joined | pending_approval | already_member | invalid |
--                   expired | exhausted | revoked | suspended | family_full |
--                   rate_limited
--
-- Errors are RETURNED rather than raised so that the attempt record (used for
-- brute-force protection) is committed even on failure.
--
-- Concurrency: the invitation row is locked with SELECT ... FOR UPDATE, so two
-- simultaneous redemptions of a single-use invitation serialize; the second
-- sees use_count = max_uses and receives 'exhausted'. The unique constraint on
-- invitation_uses(invitation_id, user_id) prevents replay by the same user.
-- ---------------------------------------------------------------------------
create or replace function public.redeem_invitation(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_inv public.invitations%rowtype;
  v_family public.families%rowtype;
  v_existing public.family_members%rowtype;
  v_failures int;
  v_active_count int;
  v_new_status public.member_status;
  v_outcome text;
begin
  -- Brute-force protection: max 10 failed attempts per 15 minutes per user.
  select count(*) into v_failures
  from private.invitation_attempts
  where user_id = v_uid and not success and created_at > now() - interval '15 minutes';
  if v_failures >= 10 then
    return jsonb_build_object('status', 'rate_limited');
  end if;

  if char_length(private.normalize_invite_code(p_code)) <> 16 then
    insert into private.invitation_attempts (user_id, success) values (v_uid, false);
    return jsonb_build_object('status', 'invalid');
  end if;

  select * into v_inv
  from public.invitations
  where token_hash = private.hash_invite_code(p_code)
  for update;

  if v_inv.id is null then
    insert into private.invitation_attempts (user_id, success) values (v_uid, false);
    return jsonb_build_object('status', 'invalid');
  end if;

  select * into v_family from public.families where id = v_inv.family_id for share;
  if v_family.deleted_at is not null or v_inv.revoked_at is not null then
    insert into private.invitation_attempts (user_id, success) values (v_uid, false);
    return jsonb_build_object('status', 'revoked');
  end if;
  if v_inv.expires_at <= now() then
    insert into private.invitation_attempts (user_id, success) values (v_uid, false);
    return jsonb_build_object('status', 'expired');
  end if;

  select * into v_existing from public.family_members
  where family_id = v_inv.family_id and user_id = v_uid
  for update;

  if v_existing.id is not null then
    if v_existing.status = 'active' then
      insert into private.invitation_attempts (user_id, success) values (v_uid, true);
      return jsonb_build_object('status', 'already_member', 'family_id', v_inv.family_id);
    elsif v_existing.status = 'pending' then
      insert into private.invitation_attempts (user_id, success) values (v_uid, true);
      return jsonb_build_object('status', 'pending_approval', 'family_id', v_inv.family_id);
    elsif v_existing.status = 'suspended' then
      insert into private.invitation_attempts (user_id, success) values (v_uid, false);
      return jsonb_build_object('status', 'suspended');
    end if;
  end if;

  if exists (select 1 from public.invitation_uses where invitation_id = v_inv.id and user_id = v_uid) then
    -- Same user replaying the same invitation after leaving/removal.
    insert into private.invitation_attempts (user_id, success) values (v_uid, false);
    return jsonb_build_object('status', 'exhausted');
  end if;

  if v_inv.use_count >= v_inv.max_uses then
    insert into private.invitation_attempts (user_id, success) values (v_uid, false);
    return jsonb_build_object('status', 'exhausted');
  end if;

  select count(*) into v_active_count from public.family_members
  where family_id = v_inv.family_id and status in ('active', 'pending');
  if v_active_count >= v_family.max_members then
    insert into private.invitation_attempts (user_id, success) values (v_uid, false);
    return jsonb_build_object('status', 'family_full');
  end if;

  v_new_status := case when v_inv.requires_approval then 'pending' else 'active' end;

  if v_existing.id is not null then
    -- Previously removed or left: rejoin as a plain member.
    update public.family_members
       set role = 'member', status = v_new_status, invited_by = v_inv.created_by,
           joined_at = case when v_new_status = 'active' then now() else null end,
           status_changed_at = now(), status_changed_by = v_uid
     where id = v_existing.id;
    v_outcome := case when v_new_status = 'active' then 'rejoined' else 'pending_approval' end;
  else
    insert into public.family_members (family_id, user_id, role, status, invited_by, joined_at, status_changed_by)
    values (v_inv.family_id, v_uid, 'member', v_new_status, v_inv.created_by,
            case when v_new_status = 'active' then now() else null end, v_uid);
    v_outcome := case when v_new_status = 'active' then 'joined' else 'pending_approval' end;
  end if;

  update public.invitations set use_count = use_count + 1 where id = v_inv.id;
  insert into public.invitation_uses (invitation_id, family_id, user_id, outcome)
  values (v_inv.id, v_inv.family_id, v_uid, v_outcome);
  insert into private.invitation_attempts (user_id, success) values (v_uid, true);

  if v_new_status = 'active' then
    update public.user_preferences set active_family_id = v_inv.family_id
    where user_id = v_uid and active_family_id is null;
  end if;

  perform private.audit(v_inv.family_id,
    case when v_new_status = 'active' then 'member.joined' else 'member.requested' end,
    'user', v_uid, jsonb_build_object('invitation_id', v_inv.id), 'members');

  return jsonb_build_object(
    'status', case when v_new_status = 'active' then 'joined' else 'pending_approval' end,
    'family_id', v_inv.family_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Internal guard: may the caller manage the target member?
--   owner  -> anyone except themselves
--   admin  -> moderators and members only
-- Returns the target row (locked).
-- ---------------------------------------------------------------------------
create or replace function private.lock_manageable_member(p_family_id uuid, p_user_id uuid)
returns public.family_members
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_my_role public.family_role := private.family_role_of(p_family_id, v_uid);
  v_target public.family_members%rowtype;
begin
  if v_my_role is null or v_my_role not in ('owner', 'admin') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_user_id = v_uid then
    raise exception 'cannot_manage_self' using errcode = '42501';
  end if;
  select * into v_target from public.family_members
  where family_id = p_family_id and user_id = p_user_id
  for update;
  if v_target.id is null then
    raise exception 'member_not_found' using errcode = 'P0002';
  end if;
  if private.role_rank(v_target.role) >= private.role_rank(v_my_role) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return v_target;
end;
$$;
revoke all on function private.lock_manageable_member(uuid, uuid) from public;

-- approve_member / reject pending membership request
create or replace function public.review_membership(p_family_id uuid, p_user_id uuid, p_approve boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target public.family_members;
begin
  v_target := private.lock_manageable_member(p_family_id, p_user_id);
  if v_target.status <> 'pending' then
    raise exception 'not_pending' using errcode = '22023';
  end if;
  update public.family_members
     set status = case when p_approve then 'active'::public.member_status else 'removed'::public.member_status end,
         joined_at = case when p_approve then now() else joined_at end,
         status_changed_at = now(), status_changed_by = auth.uid()
   where id = v_target.id;
  if p_approve then
    update public.user_preferences set active_family_id = p_family_id
    where user_id = p_user_id and active_family_id is null;
  end if;
  perform private.audit(p_family_id,
    case when p_approve then 'member.approved' else 'member.rejected' end,
    'user', p_user_id, '{}'::jsonb, case when p_approve then 'members' else 'admins' end);
end;
$$;

-- change role (owner: admin/moderator/member; admin: moderator/member)
create or replace function public.set_member_role(p_family_id uuid, p_user_id uuid, p_role public.family_role)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target public.family_members;
  v_my_role public.family_role;
begin
  if p_role = 'owner' then
    raise exception 'use_transfer_ownership' using errcode = '22023';
  end if;
  v_target := private.lock_manageable_member(p_family_id, p_user_id);
  v_my_role := private.family_role_of(p_family_id, auth.uid());
  if private.role_rank(p_role) >= private.role_rank(v_my_role) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_target.status <> 'active' then
    raise exception 'member_not_active' using errcode = '22023';
  end if;
  update public.family_members set role = p_role where id = v_target.id;
  perform private.audit(p_family_id, 'member.role_changed', 'user', p_user_id,
    jsonb_build_object('from', v_target.role, 'to', p_role), 'members');
end;
$$;

-- suspend / reactivate / remove
create or replace function public.set_member_status(p_family_id uuid, p_user_id uuid, p_status public.member_status)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_target public.family_members;
begin
  if p_status not in ('active', 'suspended', 'removed') then
    raise exception 'invalid_status' using errcode = '22023';
  end if;
  v_target := private.lock_manageable_member(p_family_id, p_user_id);
  if p_status = 'active' and v_target.status not in ('suspended') then
    raise exception 'invalid_transition' using errcode = '22023';
  end if;
  update public.family_members
     set status = p_status,
         role = case when p_status = 'removed' then 'member'::public.family_role else role end,
         status_changed_at = now(), status_changed_by = auth.uid()
   where id = v_target.id;
  if p_status <> 'active' then
    update public.user_preferences set active_family_id = null
    where user_id = p_user_id and active_family_id = p_family_id;
  end if;
  perform private.audit(p_family_id, 'member.' || p_status::text, 'user', p_user_id,
    jsonb_build_object('previous_status', v_target.status), 'admins');
end;
$$;

-- transfer ownership (owner only, target must be active)
create or replace function public.transfer_ownership(p_family_id uuid, p_new_owner uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
begin
  if not private.has_family_role(p_family_id, array['owner']::public.family_role[]) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_new_owner = v_uid then
    raise exception 'cannot_manage_self' using errcode = '22023';
  end if;
  perform 1 from public.family_members
   where family_id = p_family_id and user_id = p_new_owner and status = 'active' for update;
  if not found then
    raise exception 'member_not_found' using errcode = 'P0002';
  end if;
  -- demote first to satisfy the one-owner unique index
  update public.family_members set role = 'admin' where family_id = p_family_id and user_id = v_uid;
  update public.family_members set role = 'owner' where family_id = p_family_id and user_id = p_new_owner;
  perform private.audit(p_family_id, 'family.ownership_transferred', 'user', p_new_owner, '{}'::jsonb, 'members');
end;
$$;

-- leave family (owner must transfer first unless they are the last member)
create or replace function public.leave_family(p_family_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_me public.family_members%rowtype;
  v_others int;
begin
  select * into v_me from public.family_members
  where family_id = p_family_id and user_id = v_uid and status in ('active', 'pending')
  for update;
  if v_me.id is null then
    raise exception 'member_not_found' using errcode = 'P0002';
  end if;
  if v_me.role = 'owner' then
    select count(*) into v_others from public.family_members
    where family_id = p_family_id and status = 'active' and user_id <> v_uid;
    if v_others > 0 then
      raise exception 'owner_must_transfer' using errcode = '22023';
    end if;
    update public.families set deleted_at = now() where id = p_family_id;
  end if;
  update public.family_members
     set status = 'left', role = 'member', status_changed_at = now(), status_changed_by = v_uid
   where id = v_me.id;
  update public.user_preferences set active_family_id = null
   where user_id = v_uid and active_family_id = p_family_id;
  perform private.audit(p_family_id, 'member.left', 'user', v_uid, '{}'::jsonb, 'members');
end;
$$;

-- register / refresh an FCM device token for the caller
create or replace function public.register_device_token(
  p_token text, p_device_name text default null, p_app_version text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
begin
  if p_token is null or char_length(p_token) not between 20 and 4096 then
    raise exception 'invalid_token' using errcode = '22023';
  end if;
  perform private.enforce_rate_limit('register_device_token', 30, interval '1 hour');
  insert into public.device_tokens (user_id, token, device_name, app_version, last_seen_at)
  values (v_uid, p_token, left(p_device_name, 100), left(p_app_version, 40), now())
  on conflict (token) do update
    set user_id = excluded.user_id,           -- token moved to another account on this device
        device_name = excluded.device_name,
        app_version = excluded.app_version,
        last_seen_at = now();
end;
$$;

-- account deletion pre-check (the deletion itself runs in an Edge Function with
-- the service role, because auth.users cannot be deleted by the user).
create or replace function public.account_deletion_blockers()
returns table (family_id uuid, family_name text)
language sql
stable
security definer
set search_path = ''
as $$
  select f.id, f.name
  from public.family_members me
  join public.families f on f.id = me.family_id and f.deleted_at is null
  where me.user_id = auth.uid() and me.role = 'owner' and me.status = 'active'
    and exists (select 1 from public.family_members o
                where o.family_id = f.id and o.user_id <> me.user_id and o.status = 'active');
$$;

-- Lock down EXECUTE on all public RPCs.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('create_family', 'delete_family', 'create_invitation', 'revoke_invitation',
                        'preview_invitation', 'redeem_invitation', 'review_membership', 'set_member_role',
                        'set_member_status', 'transfer_ownership', 'leave_family', 'register_device_token',
                        'account_deletion_blockers')
  loop
    execute format('revoke all on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated', r.sig);
  end loop;
end;
$$;

revoke all on function private.handle_new_user() from public, anon, authenticated;
