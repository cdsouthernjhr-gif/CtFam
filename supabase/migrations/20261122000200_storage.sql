-- =============================================================================
-- FamilySync — Migration 0200: Storage buckets and policies
--
-- All buckets are PRIVATE. Clients obtain short-lived signed URLs
-- (createSignedUrl, default 1 hour) which Storage only issues when the SELECT
-- policy below allows the caller to read the object.
--
-- Path conventions (first folder segment is the authorization key):
--   avatars/{user_id}/{uuid}.{ext}
--   family-media/{family_id}/{uuid}.{ext}
-- =============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('avatars', 'avatars', false, 5 * 1024 * 1024,
   array['image/jpeg', 'image/png', 'image/webp']),
  ('family-media', 'family-media', false, 5 * 1024 * 1024,
   array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Safely parse a uuid from the first folder of an object path.
create or replace function private.path_uuid(p_name text)
returns uuid
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := split_part(p_name, '/', 1);
begin
  if v ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
    return v::uuid;
  end if;
  return null;
end;
$$;
grant execute on function private.path_uuid(text) to authenticated;

-- avatars ---------------------------------------------------------------------
create policy "avatars: read own or family"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'avatars'
    and (
      private.path_uuid(name) = (select auth.uid())
      or (select private.shares_family_with(private.path_uuid(name)))
    )
  );

create policy "avatars: insert own folder"
  on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and private.path_uuid(name) = (select auth.uid()));

create policy "avatars: update own folder"
  on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and private.path_uuid(name) = (select auth.uid()))
  with check (bucket_id = 'avatars' and private.path_uuid(name) = (select auth.uid()));

create policy "avatars: delete own folder"
  on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and private.path_uuid(name) = (select auth.uid()));

-- family-media ----------------------------------------------------------------
create policy "family-media: read members"
  on storage.objects for select to authenticated
  using (bucket_id = 'family-media' and (select private.is_family_member(private.path_uuid(name))));

create policy "family-media: insert admins"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'family-media'
    and (select private.has_family_role(private.path_uuid(name), array['owner', 'admin']::public.family_role[]))
  );

create policy "family-media: update admins"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'family-media'
    and (select private.has_family_role(private.path_uuid(name), array['owner', 'admin']::public.family_role[]))
  )
  with check (
    bucket_id = 'family-media'
    and (select private.has_family_role(private.path_uuid(name), array['owner', 'admin']::public.family_role[]))
  );

create policy "family-media: delete admins"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'family-media'
    and (select private.has_family_role(private.path_uuid(name), array['owner', 'admin']::public.family_role[]))
  );
