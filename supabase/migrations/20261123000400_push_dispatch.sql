-- =============================================================================
-- FamilySync — Migration 20261123000400: push dispatch + housekeeping
--
-- * New notification_queue rows "kick" the send-push Edge Function through
--   pg_net (fire-and-forget HTTP). A pg_cron job kicks again every minute so
--   retries (exponential backoff) and missed kicks are picked up.
-- * The webhook secret lives in Supabase Vault ('push_webhook_secret'). The
--   Edge Function never stores it: it asks the database to verify the header
--   via verify_push_secret(), callable only by the service role.
-- * The function URL is configured per project in private.push_config.
-- * Daily housekeeping prunes rate-limit events, invitation attempts and old
--   push queue rows.
-- Both extensions are optional: without them nothing is dispatched, but no
-- statement fails (local test databases).
-- =============================================================================

do $$
begin
  create extension if not exists pg_net with schema extensions;
exception when others then
  raise notice 'pg_net not available: %', sqlerrm;
end;
$$;

create table if not exists private.push_config (
  id            int primary key default 1 check (id = 1),
  function_url  text check (function_url is null or function_url like 'https://%'),
  updated_at    timestamptz not null default now()
);
insert into private.push_config (id) values (1) on conflict do nothing;

create or replace function private.push_webhook_secret()
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v text;
begin
  begin
    execute 'select decrypted_secret from vault.decrypted_secrets where name = $1 limit 1' into v
      using 'push_webhook_secret';
  exception when others then
    return null;
  end;
  return v;
end;
$$;
revoke all on function private.push_webhook_secret() from public;

-- Fire-and-forget call to send-push when there is due work.
create or replace function private.kick_push_dispatch()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
  v_secret text;
begin
  select function_url into v_url from private.push_config where id = 1;
  if v_url is null or not exists (select 1 from pg_extension where extname = 'pg_net') then
    return;
  end if;
  if not exists (select 1 from public.notification_queue
                 where (status = 'pending' and next_attempt_at <= now())
                    or (status = 'sending' and claimed_at < now() - interval '5 minutes')) then
    return;
  end if;
  v_secret := private.push_webhook_secret();
  if v_secret is null then
    return;
  end if;
  execute 'select net.http_post(url := $1, body := $2, headers := $3, timeout_milliseconds := 5000)'
    using v_url, '{}'::jsonb, jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret);
exception when others then
  raise warning 'push dispatch kick failed: %', sqlerrm;
end;
$$;
revoke all on function private.kick_push_dispatch() from public;

create or replace function private.on_queue_insert_kick()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.kick_push_dispatch();
  return null;
end;
$$;

drop trigger if exists notification_queue_kick on public.notification_queue;
create trigger notification_queue_kick after insert on public.notification_queue
  for each statement execute function private.on_queue_insert_kick();

-- Service role only: does the request header carry the current secret?
create or replace function public.verify_push_secret(p_secret text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v text := private.push_webhook_secret();
begin
  return v is not null and p_secret is not null and length(p_secret) >= 32 and p_secret = v;
end;
$$;
revoke all on function public.verify_push_secret(text) from public, anon, authenticated;
grant execute on function public.verify_push_secret(text) to service_role;

-- Housekeeping
create or replace function private.housekeeping()
returns void
language sql
security definer
set search_path = ''
as $$
  delete from private.rate_limit_events where created_at < now() - interval '2 days';
  delete from private.invitation_attempts where created_at < now() - interval '2 days';
  delete from public.notification_queue
   where status in ('sent', 'failed', 'skipped') and created_at < now() - interval '14 days';
  delete from public.notifications where read_at is not null and created_at < now() - interval '180 days';
$$;
revoke all on function private.housekeeping() from public;

do $$
begin
  create extension if not exists pg_cron;
  perform cron.unschedule(jobid) from cron.job where jobname in ('familysync-push', 'familysync-housekeeping');
  perform cron.schedule('familysync-push', '* * * * *', 'select private.kick_push_dispatch()');
  perform cron.schedule('familysync-housekeeping', '17 3 * * *', 'select private.housekeeping()');
exception when others then
  raise notice 'pg_cron not available: %', sqlerrm;
end;
$$;
