-- LOCAL TEST SHIM ONLY — never applied to a real Supabase project.
-- The Realtime service creates realtime.messages and realtime.topic() on hosted
-- projects (definitions copied from a hosted project, 2026-11-23). Recreated
-- here so Realtime Authorization policies can be tested with plain Postgres.
create schema if not exists realtime;
create table if not exists realtime.messages (
  id uuid not null default gen_random_uuid(),
  topic text not null,
  extension text not null,
  payload jsonb,
  event text,
  private boolean default false,
  inserted_at timestamp not null default now(),
  updated_at timestamp not null default now(),
  primary key (id, inserted_at)
);
alter table realtime.messages enable row level security;
alter table realtime.messages owner to postgres;
grant usage on schema realtime to authenticated, anon, postgres;
grant select, insert on realtime.messages to authenticated;

create or replace function realtime.topic() returns text language sql stable as $$
  select nullif(current_setting('realtime.topic', true), '')::text;
$$;
grant execute on function realtime.topic() to authenticated, anon;
