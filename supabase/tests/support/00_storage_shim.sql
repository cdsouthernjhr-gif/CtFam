-- LOCAL TEST SHIM ONLY — never applied to a real Supabase project.
-- The supabase/postgres image does not include the tables that the Storage
-- service normally creates. This recreates the minimal columns our policies use
-- so RLS on storage.objects can be tested with plain Postgres.
create table if not exists storage.buckets (
  id text primary key,
  name text not null unique,
  owner uuid,
  public boolean default false,
  file_size_limit bigint,
  allowed_mime_types text[],
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets (id),
  name text not null,
  owner uuid default auth.uid(),
  metadata jsonb,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  unique (bucket_id, name)
);
alter table storage.objects enable row level security;
grant usage on schema storage to authenticated, anon;
grant select, insert, update, delete on storage.objects to authenticated;
grant select on storage.buckets to authenticated;

-- Newer Supabase auth.uid() reads request.jwt.claims; mirror that here.
create or replace function auth.uid() returns uuid language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid;
$$;

-- On hosted Supabase the `postgres` role can manage bucket rows and create
-- policies on storage.objects; mirror that capability locally.
alter table storage.buckets owner to postgres;
alter table storage.objects owner to postgres;
grant usage, create on schema storage to postgres;
