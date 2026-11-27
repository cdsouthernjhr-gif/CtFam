-- =============================================================================
-- FamilySync — Migration 20261127000100: To-Do photos
--
-- * Before/after photos on a To-Do item (optional, up to 4 of each kind).
-- * A cover photo on a To-Do list (optional).
--
-- Private bucket todo-photos (5 MB, JPEG/PNG/WebP):
--   {family_id}/{list_id}/cover/{file}      list cover
--   {family_id}/{list_id}/{item_id}/{file}  item photo
-- Read: whoever can read the list (private lists stay private).
-- Write: cover = list creator or family owner/admin (like the list settings);
--        item photos = anyone who can work on the list (like editing items).
-- The database records which files belong where (todo_item_photos,
-- todo_lists.cover_path); rows are written only through RPCs, which check
-- the file exists in the right folder.
-- =============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('todo-photos', 'todo-photos', false, 5 * 1024 * 1024, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

alter table public.todo_lists
  add column if not exists cover_path text check (cover_path is null or char_length(cover_path) <= 300);

create table public.todo_item_photos (
  id          uuid primary key,  -- client-generated for idempotent adding
  item_id     uuid not null references public.todo_items (id) on delete cascade,
  list_id     uuid not null references public.todo_lists (id) on delete cascade,
  family_id   uuid not null references public.families (id) on delete cascade,
  kind        text not null check (kind in ('before', 'after')),
  path        text not null unique check (char_length(path) <= 300),
  created_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now()
);
create index todo_item_photos_item_idx on public.todo_item_photos (item_id, kind, created_at);
create index todo_item_photos_list_idx on public.todo_item_photos (list_id);
create index todo_item_photos_family_idx on public.todo_item_photos (family_id);
create index todo_item_photos_created_by_idx on public.todo_item_photos (created_by);

alter table public.todo_item_photos enable row level security;
create policy "todo_item_photos: read with the list"
  on public.todo_item_photos for select to authenticated
  using (list_id in (select private.readable_todo_list_ids()));
-- No insert/update/delete policies: RPCs only.
revoke all on public.todo_item_photos from anon, authenticated;
grant select on public.todo_item_photos to authenticated;

alter publication supabase_realtime add table public.todo_item_photos;

-- -----------------------------------------------------------------------------
-- Storage access
-- -----------------------------------------------------------------------------
create or replace function private.path_part_uuid(p_name text, p_part int)
returns uuid
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := split_part(p_name, '/', p_part);
begin
  if v ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    return v::uuid;
  end if;
  return null;
end;
$$;
revoke all on function private.path_part_uuid(text, int) from public;
grant execute on function private.path_part_uuid(text, int) to authenticated;

-- The list a storage path belongs to, if the path is well formed:
-- {family}/{list}/{cover|item}/{file} with the list in that family.
create or replace function private.todo_photo_list(p_name text)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select l.id
  from public.todo_lists l
  where l.id = private.path_part_uuid(p_name, 2)
    and l.family_id = private.path_part_uuid(p_name, 1)
    and split_part(p_name, '/', 4) <> ''
    and split_part(p_name, '/', 5) = '';
$$;
revoke all on function private.todo_photo_list(text) from public;
grant execute on function private.todo_photo_list(text) to authenticated;

-- May the caller add/replace/delete the file at this path?
create or replace function private.can_edit_todo_photo(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_list uuid := private.todo_photo_list(p_name);
  v_folder text := split_part(p_name, '/', 3);
begin
  if v_list is null then
    return false;
  end if;
  if v_folder = 'cover' then
    return private.can_manage_todo_list(v_list);
  end if;
  return private.can_access_todo_list(v_list) and exists (
    select 1 from public.todo_items i
    where i.id = private.path_part_uuid(p_name, 3) and i.list_id = v_list and i.deleted_at is null);
end;
$$;
revoke all on function private.can_edit_todo_photo(text) from public;
grant execute on function private.can_edit_todo_photo(text) to authenticated;

create or replace function private.can_read_todo_photo(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(private.can_read_todo_list(private.todo_photo_list(p_name)), false);
$$;
revoke all on function private.can_read_todo_photo(text) from public;
grant execute on function private.can_read_todo_photo(text) to authenticated;

create policy "todo-photos: read with the list"
  on storage.objects for select to authenticated
  using (bucket_id = 'todo-photos' and (select private.can_read_todo_photo(name)));

create policy "todo-photos: upload"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'todo-photos' and (select private.can_edit_todo_photo(name)));

create policy "todo-photos: replace"
  on storage.objects for update to authenticated
  using (bucket_id = 'todo-photos' and (select private.can_edit_todo_photo(name)))
  with check (bucket_id = 'todo-photos' and (select private.can_edit_todo_photo(name)));

create policy "todo-photos: delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'todo-photos' and (select private.can_edit_todo_photo(name)));

-- -----------------------------------------------------------------------------
-- RPCs
-- -----------------------------------------------------------------------------

-- Records an uploaded before/after photo. Idempotent on p_id (a retry after a
-- lost response returns the same row). At most 4 photos of each kind.
create or replace function public.add_todo_item_photo(p_id uuid, p_item_id uuid, p_kind text, p_path text)
returns public.todo_item_photos
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_item public.todo_items%rowtype;
  v_photo public.todo_item_photos%rowtype;
begin
  if p_id is null or p_kind is null or p_kind not in ('before', 'after') or p_path is null then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  select * into v_photo from public.todo_item_photos where id = p_id;
  if v_photo.id is not null then
    if v_photo.item_id <> p_item_id or v_photo.path <> p_path or v_photo.kind <> p_kind then
      raise exception 'invalid_input' using errcode = '22023';
    end if;
    return v_photo;  -- replay
  end if;

  -- Lock the item so two uploads cannot both pass the limit check.
  select * into v_item from public.todo_items where id = p_item_id for update;
  if v_item.id is null or v_item.deleted_at is not null or not private.can_access_todo_list(v_item.list_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_path not like v_item.family_id || '/' || v_item.list_id || '/' || v_item.id || '/%'
     or split_part(p_path, '/', 5) <> ''
     or not exists (select 1 from storage.objects o where o.bucket_id = 'todo-photos' and o.name = p_path) then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  if (select count(*) from public.todo_item_photos where item_id = p_item_id and kind = p_kind) >= 4 then
    raise exception 'photo_limit' using errcode = 'P0001', hint = 'max 4 per kind';
  end if;
  perform private.enforce_rate_limit('add_todo_item_photo', 200, interval '1 hour');

  insert into public.todo_item_photos (id, item_id, list_id, family_id, kind, path, created_by)
  values (p_id, v_item.id, v_item.list_id, v_item.family_id, p_kind, p_path, v_uid)
  returning * into v_photo;
  perform private.todo_log(v_item.family_id, v_item.list_id, v_item.id, 'item.photo_added',
    jsonb_build_object('title', v_item.title, 'kind', p_kind));
  return v_photo;
end;
$$;

-- Removes a photo record and returns its storage path, so the client can
-- delete the file (allowed by the storage policy above). Idempotent: an
-- unknown id returns null.
create or replace function public.delete_todo_item_photo(p_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_photo public.todo_item_photos%rowtype;
  v_title text;
begin
  perform private.require_uid();
  select * into v_photo from public.todo_item_photos where id = p_id for update;
  if v_photo.id is null then
    return null;
  end if;
  if not private.can_access_todo_list(v_photo.list_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  delete from public.todo_item_photos where id = p_id;
  select title into v_title from public.todo_items where id = v_photo.item_id;
  perform private.todo_log(v_photo.family_id, v_photo.list_id, v_photo.item_id, 'item.photo_removed',
    jsonb_build_object('title', v_title, 'kind', v_photo.kind));
  return v_photo.path;
end;
$$;

-- Sets (or clears, with null) a list's cover photo. Returns the previous
-- path so the client can delete the old file.
create or replace function public.set_todo_list_cover(p_list_id uuid, p_path text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_list public.todo_lists%rowtype;
  v_old text;
begin
  perform private.require_uid();
  select * into v_list from public.todo_lists where id = p_list_id for update;
  if v_list.id is null or not private.can_manage_todo_list(p_list_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_path is not null and (
       p_path not like v_list.family_id || '/' || v_list.id || '/cover/%'
       or split_part(p_path, '/', 5) <> ''
       or not exists (select 1 from storage.objects o where o.bucket_id = 'todo-photos' and o.name = p_path)) then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  v_old := v_list.cover_path;
  if v_old is not distinct from p_path then
    return null;
  end if;
  update public.todo_lists set cover_path = p_path where id = p_list_id;
  return v_old;
end;
$$;

-- List summaries now include the cover photo (return type changed).
drop function public.todo_list_summaries(uuid);
create function public.todo_list_summaries(p_family_id uuid)
returns table (
  id uuid, name text, description text, category text, custom_category_id uuid, visibility text,
  created_by uuid, revision int, created_at timestamptz, updated_at timestamptz,
  total_items int, completed_items int, overdue_items int, due_today_items int, cover_path text)
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
                                   and i.due_at < date_trunc('day', now()) + interval '1 day')::int,
         l.cover_path
  from public.todo_lists l
  left join public.todo_items i on i.list_id = l.id and i.deleted_at is null
  where l.family_id = p_family_id and l.deleted_at is null
  group by l.id
  order by l.updated_at desc;
$$;

revoke all on function public.add_todo_item_photo(uuid, uuid, text, text) from public, anon;
revoke all on function public.delete_todo_item_photo(uuid) from public, anon;
revoke all on function public.set_todo_list_cover(uuid, text) from public, anon;
revoke all on function public.todo_list_summaries(uuid) from public, anon;
grant execute on function public.add_todo_item_photo(uuid, uuid, text, text) to authenticated;
grant execute on function public.delete_todo_item_photo(uuid) to authenticated;
grant execute on function public.set_todo_list_cover(uuid, text) to authenticated;
grant execute on function public.todo_list_summaries(uuid) to authenticated;
