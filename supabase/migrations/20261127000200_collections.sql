-- =============================================================================
-- FamilySync — Migration 20261127000200: money collections (kutipan)
--
-- A collection has a title and a purpose, and one of three modes:
--   open        no target, collect as long as it is open
--   lump        one target amount for everyone together
--   per_member  a target per member (the total target is their sum)
-- Members record their own payments (pending) and a treasurer confirms or
-- rejects them; only confirmed payments count. Treasurers (the creator, the
-- treasurers they name, and the home family's owner/admin) can also record
-- payments for others (confirmed at once) and expenses (money out), so the
-- balance is visible. Everyone who can see a collection sees all amounts.
-- A collection can be shared with the linked families (rumpun); their
-- members can then see and pay too.
--
-- The app only RECORDS money; it does not move it.
--
-- Receipts: private bucket collection-receipts,
--   {family_id}/{collection_id}/{file}
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Tables
-- -----------------------------------------------------------------------------
create table public.collections (
  id               uuid primary key,  -- client-generated for idempotent creation
  family_id        uuid not null references public.families (id) on delete cascade,
  title            text not null check (char_length(btrim(title)) between 1 and 80),
  purpose          text not null check (char_length(btrim(purpose)) between 1 and 500),
  mode             text not null check (mode in ('open', 'lump', 'per_member')),
  target_amount    numeric(12, 2) check (target_amount is null or (target_amount > 0 and target_amount <= 10000000)),
  due_date         date,
  share_with_clan  boolean not null default false,
  status           text not null default 'open' check (status in ('open', 'closed')),
  closed_at        timestamptz,
  created_by       uuid references public.profiles (id) on delete set null,
  revision         int not null default 1,
  deleted_at       timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check ((mode = 'lump') = (target_amount is not null)),
  check ((status = 'closed') = (closed_at is not null))
);
create index collections_family_idx on public.collections (family_id, created_at desc) where deleted_at is null;
create index collections_created_by_idx on public.collections (created_by);
create trigger collections_set_updated_at before update on public.collections
  for each row execute function private.set_updated_at();

create table public.collection_treasurers (
  collection_id  uuid not null references public.collections (id) on delete cascade,
  user_id        uuid not null references public.profiles (id) on delete cascade,
  created_at     timestamptz not null default now(),
  primary key (collection_id, user_id)
);
create index collection_treasurers_user_idx on public.collection_treasurers (user_id);

create table public.collection_targets (
  collection_id  uuid not null references public.collections (id) on delete cascade,
  user_id        uuid not null references public.profiles (id) on delete cascade,
  amount         numeric(12, 2) not null check (amount > 0 and amount <= 10000000),
  created_at     timestamptz not null default now(),
  primary key (collection_id, user_id)
);
create index collection_targets_user_idx on public.collection_targets (user_id);

create table public.collection_payments (
  id             uuid primary key,  -- client-generated for idempotent recording
  collection_id  uuid not null references public.collections (id) on delete cascade,
  payer_id       uuid references public.profiles (id) on delete set null,
  amount         numeric(12, 2) not null check (amount > 0 and amount <= 10000000),
  paid_on        date not null,
  note           text check (note is null or char_length(note) <= 300),
  receipt_path   text check (receipt_path is null or char_length(receipt_path) <= 300),
  status         text not null default 'pending' check (status in ('pending', 'confirmed', 'rejected')),
  reject_reason  text check (reject_reason is null or char_length(reject_reason) <= 300),
  recorded_by    uuid references public.profiles (id) on delete set null,
  reviewed_by    uuid references public.profiles (id) on delete set null,
  reviewed_at    timestamptz,
  created_at     timestamptz not null default now()
);
create index collection_payments_collection_idx on public.collection_payments (collection_id, created_at desc);
create index collection_payments_payer_idx on public.collection_payments (payer_id);
create index collection_payments_recorded_by_idx on public.collection_payments (recorded_by);
create index collection_payments_reviewed_by_idx on public.collection_payments (reviewed_by);

create table public.collection_expenses (
  id             uuid primary key,
  collection_id  uuid not null references public.collections (id) on delete cascade,
  amount         numeric(12, 2) not null check (amount > 0 and amount <= 10000000),
  spent_on       date not null,
  description    text not null check (char_length(btrim(description)) between 1 and 300),
  receipt_path   text check (receipt_path is null or char_length(receipt_path) <= 300),
  recorded_by    uuid references public.profiles (id) on delete set null,
  created_at     timestamptz not null default now()
);
create index collection_expenses_collection_idx on public.collection_expenses (collection_id, spent_on desc);
create index collection_expenses_recorded_by_idx on public.collection_expenses (recorded_by);

-- -----------------------------------------------------------------------------
-- Access helpers
-- -----------------------------------------------------------------------------

-- Collections the caller can see: their families' own, and clan-shared ones
-- of linked families. Set-based for RLS (evaluated once per query).
create or replace function private.readable_collection_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select c.id
  from public.collections c
  where c.deleted_at is null
    and (private.is_family_member(c.family_id)
         or (c.share_with_clan and c.family_id in (select private.my_clan_family_ids())));
$$;

create or replace function private.can_read_collection(p_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from private.readable_collection_ids() r where r = p_id);
$$;

-- Treasurer: named treasurer, creator, or owner/admin of the home family.
create or replace function private.is_collection_treasurer(p_id uuid, p_user uuid default null)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.collections c
    where c.id = p_id and c.deleted_at is null
      and (
        c.created_by is not distinct from coalesce(p_user, (select auth.uid()))
        or exists (select 1 from public.collection_treasurers t
                   where t.collection_id = c.id and t.user_id = coalesce(p_user, (select auth.uid())))
        or coalesce(private.family_role_of(c.family_id, coalesce(p_user, (select auth.uid())))
                    in ('owner', 'admin'), false)
      )
      -- still able to see it (left the family = no longer a treasurer)
      and (private.family_role_of(c.family_id, coalesce(p_user, (select auth.uid()))) is not null
           or (c.share_with_clan and private.is_clan_member(c.family_id, coalesce(p_user, (select auth.uid())))))
  );
$$;

-- May p_user take part (pay / be given a target / be a treasurer)?
create or replace function private.can_join_collection(p_id uuid, p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.collections c
    where c.id = p_id and c.deleted_at is null
      and (private.family_role_of(c.family_id, p_user) is not null
           or (c.share_with_clan and private.is_clan_member(c.family_id, p_user))));
$$;

-- Everyone who can see the collection (for notifications).
create or replace function private.collection_audience(p_id uuid)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select distinct fm.user_id
  from public.collections c
  join public.family_members fm
    on fm.status = 'active'
   and (fm.family_id = c.family_id
        or (c.share_with_clan and fm.family_id in (select f.family_id from private.family_clan(c.family_id) f)))
  where c.id = p_id;
$$;

create or replace function private.collection_treasurer_ids(p_id uuid)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select a from private.collection_audience(p_id) a where private.is_collection_treasurer(p_id, a);
$$;

revoke all on function private.readable_collection_ids() from public;
revoke all on function private.can_read_collection(uuid) from public;
revoke all on function private.is_collection_treasurer(uuid, uuid) from public;
revoke all on function private.can_join_collection(uuid, uuid) from public;
revoke all on function private.collection_audience(uuid) from public;
revoke all on function private.collection_treasurer_ids(uuid) from public;
grant execute on function private.readable_collection_ids() to authenticated;
grant execute on function private.can_read_collection(uuid) to authenticated;
grant execute on function private.is_collection_treasurer(uuid, uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- RLS: read with the collection; all writes through RPCs.
-- -----------------------------------------------------------------------------
alter table public.collections enable row level security;
alter table public.collection_treasurers enable row level security;
alter table public.collection_targets enable row level security;
alter table public.collection_payments enable row level security;
alter table public.collection_expenses enable row level security;

create policy "collections: read visible"
  on public.collections for select to authenticated
  using (id in (select private.readable_collection_ids()));
create policy "collection_treasurers: read with the collection"
  on public.collection_treasurers for select to authenticated
  using (collection_id in (select private.readable_collection_ids()));
create policy "collection_targets: read with the collection"
  on public.collection_targets for select to authenticated
  using (collection_id in (select private.readable_collection_ids()));
create policy "collection_payments: read with the collection"
  on public.collection_payments for select to authenticated
  using (collection_id in (select private.readable_collection_ids()));
create policy "collection_expenses: read with the collection"
  on public.collection_expenses for select to authenticated
  using (collection_id in (select private.readable_collection_ids()));

revoke all on public.collections, public.collection_treasurers, public.collection_targets,
  public.collection_payments, public.collection_expenses from anon, authenticated;
grant select on public.collections, public.collection_treasurers, public.collection_targets,
  public.collection_payments, public.collection_expenses to authenticated;

alter publication supabase_realtime add table public.collections;
alter publication supabase_realtime add table public.collection_payments;
alter publication supabase_realtime add table public.collection_expenses;

-- -----------------------------------------------------------------------------
-- Receipts storage
-- -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('collection-receipts', 'collection-receipts', false, 5 * 1024 * 1024,
        array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- The collection a receipt path belongs to: {family}/{collection}/{file}.
create or replace function private.receipt_collection(p_name text)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select c.id from public.collections c
  where c.id = private.path_part_uuid(p_name, 2)
    and c.family_id = private.path_part_uuid(p_name, 1)
    and split_part(p_name, '/', 3) <> ''
    and split_part(p_name, '/', 4) = '';
$$;
revoke all on function private.receipt_collection(text) from public;
grant execute on function private.receipt_collection(text) to authenticated;

create or replace function private.can_use_receipt(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(private.can_read_collection(private.receipt_collection(p_name)), false);
$$;
revoke all on function private.can_use_receipt(text) from public;
grant execute on function private.can_use_receipt(text) to authenticated;

create policy "collection-receipts: read"
  on storage.objects for select to authenticated
  using (bucket_id = 'collection-receipts' and (select private.can_use_receipt(name)));
-- Anyone taking part may upload a receipt; files are only deleted by their
-- uploader (or a treasurer, below).
create policy "collection-receipts: upload"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'collection-receipts' and (select private.can_use_receipt(name)));
create policy "collection-receipts: delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'collection-receipts'
         and (owner = (select auth.uid())
              or (select private.is_collection_treasurer(private.receipt_collection(name)))));

-- -----------------------------------------------------------------------------
-- Notifications: new type 'collection', also reaching clan members of a
-- clan-shared collection (recipients are chosen by the RPCs below).
-- -----------------------------------------------------------------------------
alter table public.notifications drop constraint notifications_type_check;
alter table public.notifications add constraint notifications_type_check check (type in (
  'private_message', 'group_message', 'task_created', 'task_assigned', 'task_completed',
  'family_request', 'member_joined', 'family_event', 'announcement', 'collection'));

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
           -- clan events and clan-shared collections also reach members of linked families
           or (p_type in ('family_event', 'collection') and private.is_clan_member(p_family_id, u.uid)))
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

create or replace function private.money(p numeric)
returns text
language sql
immutable
set search_path = ''
as $$ select 'RM' || to_char(p, 'FM999G999G990D00'); $$;
revoke all on function private.money(numeric) from public;

-- -----------------------------------------------------------------------------
-- RPCs
-- -----------------------------------------------------------------------------

-- Create (any active member of the family) or edit (treasurers).
-- p_member_targets: [{"user_id": uuid, "amount": number}] for per_member;
-- null = leave targets unchanged on edit. p_treasurer_ids: extra treasurers
-- (null = unchanged on edit).
create or replace function public.upsert_collection(
  p_id uuid,
  p_family_id uuid,
  p_title text,
  p_purpose text,
  p_mode text,
  p_target_amount numeric default null,
  p_due_date date default null,
  p_share_with_clan boolean default false,
  p_treasurer_ids uuid[] default null,
  p_member_targets jsonb default null,
  p_expected_revision int default null)
returns public.collections
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_c public.collections%rowtype;
  v_new boolean;
  t record;
begin
  if p_id is null or p_mode is null or p_mode not in ('open', 'lump', 'per_member')
     or (p_mode = 'lump') <> (p_target_amount is not null)
     or (p_mode = 'per_member' and p_member_targets is not null and jsonb_typeof(p_member_targets) <> 'array') then
    raise exception 'invalid_input' using errcode = '22023';
  end if;

  select * into v_c from public.collections where id = p_id for update;
  v_new := v_c.id is null;
  if v_new then
    if not private.is_family_member(p_family_id) then
      raise exception 'forbidden' using errcode = '42501';
    end if;
    perform private.enforce_rate_limit('upsert_collection', 30, interval '1 hour');
    insert into public.collections (id, family_id, title, purpose, mode, target_amount, due_date, share_with_clan,
                                    created_by)
    values (p_id, p_family_id, btrim(p_title), btrim(p_purpose), p_mode, p_target_amount, p_due_date,
            coalesce(p_share_with_clan, false), v_uid)
    returning * into v_c;
  else
    if v_c.deleted_at is not null or not private.is_collection_treasurer(p_id) then
      raise exception 'forbidden' using errcode = '42501';
    end if;
    if p_family_id is distinct from v_c.family_id then
      raise exception 'invalid_input' using errcode = '22023';
    end if;
    if p_expected_revision is not null and p_expected_revision <> v_c.revision then
      raise exception 'revision_conflict' using errcode = 'P0409';
    end if;
    update public.collections
       set title = btrim(p_title), purpose = btrim(p_purpose), mode = p_mode, target_amount = p_target_amount,
           due_date = p_due_date, share_with_clan = coalesce(p_share_with_clan, false), revision = revision + 1
     where id = p_id
    returning * into v_c;
  end if;

  if p_treasurer_ids is not null then
    if exists (select 1 from unnest(p_treasurer_ids) u(id) where not private.can_join_collection(p_id, u.id)) then
      raise exception 'invalid_input' using errcode = '22023', hint = 'treasurer cannot see the collection';
    end if;
    delete from public.collection_treasurers where collection_id = p_id and user_id <> all (p_treasurer_ids);
    insert into public.collection_treasurers (collection_id, user_id)
    select p_id, u.id from (select distinct unnest(p_treasurer_ids) id) u
    on conflict do nothing;
  end if;

  if p_mode <> 'per_member' then
    delete from public.collection_targets where collection_id = p_id;
  elsif p_member_targets is not null then
    delete from public.collection_targets where collection_id = p_id;
    for t in
      select (e ->> 'user_id')::uuid as uid, (e ->> 'amount')::numeric(12, 2) as amount
      from jsonb_array_elements(p_member_targets) e
    loop
      if t.uid is null or t.amount is null or t.amount <= 0 or not private.can_join_collection(p_id, t.uid) then
        raise exception 'invalid_input' using errcode = '22023', hint = 'bad member target';
      end if;
      insert into public.collection_targets (collection_id, user_id, amount) values (p_id, t.uid, t.amount)
      on conflict (collection_id, user_id) do update set amount = excluded.amount;
    end loop;
  end if;
  if p_mode = 'per_member' and not exists (select 1 from public.collection_targets where collection_id = p_id) then
    raise exception 'invalid_input' using errcode = '22023', hint = 'per_member needs targets';
  end if;

  if v_new then
    perform private.notify(
      array(select private.collection_audience(p_id)), v_c.family_id, 'collection', 'collection:new:' || p_id,
      jsonb_build_object(
        'ms', jsonb_build_object('title', 'Kutipan baharu: ' || v_c.title, 'body', v_c.purpose),
        'en', jsonb_build_object('title', 'New collection: ' || v_c.title, 'body', v_c.purpose)),
      jsonb_build_object('route', '/collections/' || p_id), v_uid);
  end if;
  return v_c;
end;
$$;

create or replace function public.set_collection_status(p_id uuid, p_closed boolean)
returns public.collections
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_c public.collections%rowtype;
begin
  perform private.require_uid();
  select * into v_c from public.collections where id = p_id for update;
  if v_c.id is null or not private.is_collection_treasurer(p_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if (v_c.status = 'closed') = coalesce(p_closed, false) then
    return v_c;
  end if;
  update public.collections
     set status = case when p_closed then 'closed' else 'open' end,
         closed_at = case when p_closed then now() end,
         revision = revision + 1
   where id = p_id
  returning * into v_c;
  return v_c;
end;
$$;

create or replace function public.delete_collection(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_uid();
  if not exists (select 1 from public.collections where id = p_id) then
    return;
  end if;
  if not private.is_collection_treasurer(p_id) then
    if exists (select 1 from public.collections where id = p_id and deleted_at is not null) then
      return;  -- already deleted (replay)
    end if;
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.collections set deleted_at = now(), revision = revision + 1 where id = p_id and deleted_at is null;
end;
$$;

-- Records a payment. Members record their own (pending, to be confirmed);
-- treasurers may record for anyone taking part (confirmed at once).
-- Idempotent on p_id.
create or replace function public.record_collection_payment(
  p_id uuid,
  p_collection_id uuid,
  p_amount numeric,
  p_paid_on date default null,
  p_note text default null,
  p_receipt_path text default null,
  p_payer_id uuid default null)
returns public.collection_payments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_payer uuid := coalesce(p_payer_id, v_uid);
  v_c public.collections%rowtype;
  v_p public.collection_payments%rowtype;
  v_treasurer boolean;
  v_name text;
begin
  if p_id is null or p_amount is null or p_amount <= 0 then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  select * into v_p from public.collection_payments where id = p_id;
  if v_p.id is not null then
    if v_p.collection_id <> p_collection_id or v_p.amount <> p_amount or v_p.recorded_by is distinct from v_uid then
      raise exception 'invalid_input' using errcode = '22023';
    end if;
    return v_p;  -- replay
  end if;

  select * into v_c from public.collections where id = p_collection_id and deleted_at is null;
  if v_c.id is null or not private.can_read_collection(p_collection_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_c.status <> 'open' then
    raise exception 'collection_closed' using errcode = 'P0001';
  end if;
  v_treasurer := private.is_collection_treasurer(p_collection_id);
  if v_payer <> v_uid and not v_treasurer then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not private.can_join_collection(p_collection_id, v_payer) then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  if p_receipt_path is not null and (
       p_receipt_path not like v_c.family_id || '/' || v_c.id || '/%'
       or split_part(p_receipt_path, '/', 4) <> ''
       or not exists (select 1 from storage.objects o
                      where o.bucket_id = 'collection-receipts' and o.name = p_receipt_path)) then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  perform private.enforce_rate_limit('record_collection_payment', 120, interval '1 hour');

  insert into public.collection_payments (id, collection_id, payer_id, amount, paid_on, note, receipt_path, status,
                                          recorded_by, reviewed_by, reviewed_at)
  values (p_id, p_collection_id, v_payer, p_amount, coalesce(p_paid_on, current_date), nullif(btrim(p_note), ''),
          p_receipt_path, case when v_treasurer then 'confirmed' else 'pending' end, v_uid,
          case when v_treasurer then v_uid end, case when v_treasurer then now() end)
  returning * into v_p;

  select coalesce(display_name, '?') into v_name from public.profiles where id = v_payer;
  if v_p.status = 'pending' then
    perform private.notify(
      array(select private.collection_treasurer_ids(p_collection_id)), v_c.family_id, 'collection',
      'collection:pending:' || p_id,
      jsonb_build_object(
        'ms', jsonb_build_object('title', v_c.title || ': bayaran untuk disahkan',
                                 'body', v_name || ' merekod ' || private.money(p_amount)),
        'en', jsonb_build_object('title', v_c.title || ': payment to confirm',
                                 'body', v_name || ' recorded ' || private.money(p_amount))),
      jsonb_build_object('route', '/collections/' || p_collection_id), v_uid);
  elsif v_payer <> v_uid then
    perform private.notify(
      array[v_payer], v_c.family_id, 'collection', 'collection:recorded:' || p_id,
      jsonb_build_object(
        'ms', jsonb_build_object('title', v_c.title, 'body', 'Bayaran anda ' || private.money(p_amount) || ' telah direkod'),
        'en', jsonb_build_object('title', v_c.title, 'body', 'Your payment of ' || private.money(p_amount) || ' was recorded')),
      jsonb_build_object('route', '/collections/' || p_collection_id), v_uid);
  end if;
  return v_p;
end;
$$;

create or replace function public.review_collection_payment(p_id uuid, p_approve boolean, p_reason text default null)
returns public.collection_payments
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_p public.collection_payments%rowtype;
  v_c public.collections%rowtype;
begin
  select * into v_p from public.collection_payments where id = p_id for update;
  if v_p.id is null or not private.is_collection_treasurer(v_p.collection_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_p.status <> 'pending' then
    if v_p.status = (case when p_approve then 'confirmed' else 'rejected' end) then
      return v_p;  -- replay
    end if;
    raise exception 'already_reviewed' using errcode = 'P0001';
  end if;
  update public.collection_payments
     set status = case when p_approve then 'confirmed' else 'rejected' end,
         reject_reason = case when p_approve then null else nullif(btrim(p_reason), '') end,
         reviewed_by = v_uid, reviewed_at = now()
   where id = p_id
  returning * into v_p;
  select * into v_c from public.collections where id = v_p.collection_id;
  perform private.notify(
    array[v_p.payer_id], v_c.family_id, 'collection', 'collection:review:' || p_id,
    jsonb_build_object(
      'ms', jsonb_build_object('title', v_c.title,
        'body', case when p_approve then 'Bayaran ' || private.money(v_p.amount) || ' disahkan ✅'
                     else 'Bayaran ' || private.money(v_p.amount) || ' ditolak' ||
                          coalesce(': ' || v_p.reject_reason, '') end),
      'en', jsonb_build_object('title', v_c.title,
        'body', case when p_approve then 'Payment of ' || private.money(v_p.amount) || ' confirmed ✅'
                     else 'Payment of ' || private.money(v_p.amount) || ' rejected' ||
                          coalesce(': ' || v_p.reject_reason, '') end)),
    jsonb_build_object('route', '/collections/' || v_p.collection_id), v_uid);
  return v_p;
end;
$$;

-- Payer: own pending payment. Treasurer: any. Returns the receipt path for
-- cleanup; unknown id returns null.
create or replace function public.delete_collection_payment(p_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_p public.collection_payments%rowtype;
begin
  select * into v_p from public.collection_payments where id = p_id for update;
  if v_p.id is null then
    return null;
  end if;
  if not (private.is_collection_treasurer(v_p.collection_id)
          or (v_p.payer_id is not distinct from v_uid and v_p.status = 'pending'
              and private.can_read_collection(v_p.collection_id))) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  delete from public.collection_payments where id = p_id;
  return v_p.receipt_path;
end;
$$;

create or replace function public.record_collection_expense(
  p_id uuid,
  p_collection_id uuid,
  p_amount numeric,
  p_description text,
  p_spent_on date default null,
  p_receipt_path text default null)
returns public.collection_expenses
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_e public.collection_expenses%rowtype;
  v_c public.collections%rowtype;
begin
  if p_id is null or p_amount is null or p_amount <= 0 then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  select * into v_e from public.collection_expenses where id = p_id;
  if v_e.id is not null then
    if v_e.collection_id <> p_collection_id or v_e.amount <> p_amount then
      raise exception 'invalid_input' using errcode = '22023';
    end if;
    return v_e;
  end if;
  select * into v_c from public.collections where id = p_collection_id and deleted_at is null;
  if v_c.id is null or not private.is_collection_treasurer(p_collection_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_receipt_path is not null and (
       p_receipt_path not like v_c.family_id || '/' || v_c.id || '/%'
       or split_part(p_receipt_path, '/', 4) <> ''
       or not exists (select 1 from storage.objects o
                      where o.bucket_id = 'collection-receipts' and o.name = p_receipt_path)) then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  insert into public.collection_expenses (id, collection_id, amount, spent_on, description, receipt_path, recorded_by)
  values (p_id, p_collection_id, p_amount, coalesce(p_spent_on, current_date), btrim(p_description), p_receipt_path, v_uid)
  returning * into v_e;
  return v_e;
end;
$$;

create or replace function public.delete_collection_expense(p_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_e public.collection_expenses%rowtype;
begin
  perform private.require_uid();
  select * into v_e from public.collection_expenses where id = p_id for update;
  if v_e.id is null then
    return null;
  end if;
  if not private.is_collection_treasurer(v_e.collection_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  delete from public.collection_expenses where id = p_id;
  return v_e.receipt_path;
end;
$$;

-- Treasurer: remind everyone who still owes (per_member: below their
-- target; lump/open: everyone who has not paid yet). At most once per
-- collection per day. Returns how many were notified.
create or replace function public.remind_collection(p_id uuid)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_c public.collections%rowtype;
  v_ids uuid[];
begin
  select * into v_c from public.collections where id = p_id and deleted_at is null;
  if v_c.id is null or not private.is_collection_treasurer(p_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_c.status <> 'open' then
    raise exception 'collection_closed' using errcode = 'P0001';
  end if;
  if v_c.mode = 'per_member' then
    select array_agg(t.user_id) into v_ids
    from public.collection_targets t
    where t.collection_id = p_id
      and t.amount > coalesce((select sum(p.amount) from public.collection_payments p
                               where p.collection_id = p_id and p.payer_id = t.user_id
                                 and p.status = 'confirmed'), 0);
  else
    select array_agg(a) into v_ids
    from private.collection_audience(p_id) a
    where not exists (select 1 from public.collection_payments p
                      where p.collection_id = p_id and p.payer_id = a and p.status <> 'rejected');
  end if;
  return private.notify(
    coalesce(v_ids, '{}'), v_c.family_id, 'collection', 'collection:remind:' || p_id || ':' || current_date,
    jsonb_build_object(
      'ms', jsonb_build_object('title', 'Peringatan kutipan: ' || v_c.title, 'body', v_c.purpose),
      'en', jsonb_build_object('title', 'Collection reminder: ' || v_c.title, 'body', v_c.purpose)),
    jsonb_build_object('route', '/collections/' || p_id), v_uid);
end;
$$;

-- Overview of the collections visible from p_family_id: the family's own and
-- clan-shared ones of linked families. SECURITY INVOKER (RLS applies).
create or replace function public.collection_summaries(p_family_id uuid)
returns table (
  id uuid, family_id uuid, title text, purpose text, mode text, status text, due_date date,
  share_with_clan boolean, created_at timestamptz, target_total numeric, confirmed_total numeric,
  pending_total numeric, expense_total numeric, my_target numeric, my_paid numeric, my_pending numeric,
  is_treasurer boolean)
language sql
stable
security invoker
set search_path = ''
as $$
  select c.id, c.family_id, c.title, c.purpose, c.mode, c.status, c.due_date, c.share_with_clan, c.created_at,
         case c.mode when 'lump' then c.target_amount
                     when 'per_member' then (select sum(t.amount) from public.collection_targets t where t.collection_id = c.id)
         end,
         coalesce((select sum(p.amount) from public.collection_payments p where p.collection_id = c.id and p.status = 'confirmed'), 0),
         coalesce((select sum(p.amount) from public.collection_payments p where p.collection_id = c.id and p.status = 'pending'), 0),
         coalesce((select sum(e.amount) from public.collection_expenses e where e.collection_id = c.id), 0),
         (select t.amount from public.collection_targets t where t.collection_id = c.id and t.user_id = (select auth.uid())),
         coalesce((select sum(p.amount) from public.collection_payments p
                   where p.collection_id = c.id and p.payer_id = (select auth.uid()) and p.status = 'confirmed'), 0),
         coalesce((select sum(p.amount) from public.collection_payments p
                   where p.collection_id = c.id and p.payer_id = (select auth.uid()) and p.status = 'pending'), 0),
         private.is_collection_treasurer(c.id)
  from public.collections c
  where c.deleted_at is null
    and (c.family_id = p_family_id
         or (c.share_with_clan and c.family_id in (select private.clan_of_my_family(p_family_id))))
  order by (c.status = 'open') desc, c.created_at desc;
$$;

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('upsert_collection', 'set_collection_status', 'delete_collection',
                        'record_collection_payment', 'review_collection_payment', 'delete_collection_payment',
                        'record_collection_expense', 'delete_collection_expense', 'remind_collection',
                        'collection_summaries')
  loop
    execute format('revoke all on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated', r.sig);
  end loop;
end;
$$;
