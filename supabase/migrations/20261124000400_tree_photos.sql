-- =============================================================================
-- FamilySync — Migration 20261124000400: family tree photos
--
-- Private bucket tree-photos (5 MB, JPEG/PNG/WebP):
--   {family_id}/{person_id}/{file}   photo of one person
--   {family_id}/cover/{file}         cover photo of the whole tree
-- Read: active members of that family.
-- Write/delete: family owner/admin for any file; a member only inside the
-- folder of the person record linked to their own account.
-- The database keeps the current path (family_persons.photo_path,
-- families.tree_photo_path); set through RPCs that check the file exists in
-- the right folder.
-- =============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('tree-photos', 'tree-photos', false, 5 * 1024 * 1024, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

alter table public.family_persons
  add column if not exists photo_path text check (photo_path is null or char_length(photo_path) <= 300);
alter table public.families
  add column if not exists tree_photo_path text check (tree_photo_path is null or char_length(tree_photo_path) <= 300);

-- May the caller change files at this storage path?
create or replace function private.can_edit_tree_photo(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_family uuid := private.path_uuid(p_name);
  v_second text := split_part(p_name, '/', 2);
begin
  if v_family is null or split_part(p_name, '/', 3) = '' or split_part(p_name, '/', 4) <> '' then
    return false;  -- exactly {family}/{folder}/{file}
  end if;
  if private.is_family_admin(v_family) then
    return v_second = 'cover' or exists (
      select 1 from public.family_persons p
      where p.family_id = v_family and p.id::text = v_second and p.deleted_at is null);
  end if;
  return private.is_family_member(v_family) and exists (
    select 1 from public.family_persons p
    where p.family_id = v_family and p.id::text = v_second and p.deleted_at is null
      and p.user_id = (select auth.uid()));
end;
$$;
revoke all on function private.can_edit_tree_photo(text) from public;
grant execute on function private.can_edit_tree_photo(text) to authenticated;

create policy "tree-photos: read members"
  on storage.objects for select to authenticated
  using (bucket_id = 'tree-photos' and (select private.is_family_member(private.path_uuid(name))));

create policy "tree-photos: upload"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'tree-photos' and (select private.can_edit_tree_photo(name)));

create policy "tree-photos: replace"
  on storage.objects for update to authenticated
  using (bucket_id = 'tree-photos' and (select private.can_edit_tree_photo(name)))
  with check (bucket_id = 'tree-photos' and (select private.can_edit_tree_photo(name)));

create policy "tree-photos: delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'tree-photos' and (select private.can_edit_tree_photo(name)));

-- Sets (or clears, with null) a person's photo. Admins: anyone; members:
-- only their own record.
create or replace function public.set_person_photo(p_person_id uuid, p_path text)
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
  if v_p.id is null or not private.is_family_member(v_p.family_id)
     or not (private.is_family_admin(v_p.family_id) or v_p.user_id is not distinct from v_uid) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_path is not null and (
       p_path not like v_p.family_id || '/' || v_p.id || '/%'
       or not exists (select 1 from storage.objects o where o.bucket_id = 'tree-photos' and o.name = p_path)) then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  if v_p.photo_path is not distinct from p_path then
    return v_p;
  end if;
  update public.family_persons set photo_path = p_path, updated_by = v_uid, revision = revision + 1
   where id = p_person_id
  returning * into v_p;
  return v_p;
end;
$$;

-- Sets (or clears) the tree cover photo. Owner/admin only.
create or replace function public.set_tree_photo(p_family_id uuid, p_path text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_uid();
  if not private.is_family_admin(p_family_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_path is not null and (
       p_path not like p_family_id || '/cover/%'
       or not exists (select 1 from storage.objects o where o.bucket_id = 'tree-photos' and o.name = p_path)) then
    raise exception 'invalid_input' using errcode = '22023';
  end if;
  update public.families set tree_photo_path = p_path where id = p_family_id and deleted_at is null;
  return p_path;
end;
$$;

revoke all on function public.set_person_photo(uuid, text) from public, anon;
revoke all on function public.set_tree_photo(uuid, text) from public, anon;
grant execute on function public.set_person_photo(uuid, text) to authenticated;
grant execute on function public.set_tree_photo(uuid, text) to authenticated;
