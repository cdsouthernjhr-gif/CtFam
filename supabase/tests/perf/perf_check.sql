-- FamilySync — performance check at family scale (Phase 7).
-- Seeds one large family (100 members, ~25k messages, 2k tasks, 500 events,
-- 20k notifications) and times the queries the app runs most, as a signed-in
-- member through RLS. Prints median timings and fails when a budget is broken.
-- Run: scripts/perf_check.sh (needs the test DB from KEEP_DB=1 scripts/db_test.sh)
\set ON_ERROR_STOP 1
set client_min_messages = warning;
begin;  -- everything is rolled back at the end

create schema if not exists perf;
grant usage on schema perf to authenticated;

-- Median wall time (ms) of p_runs executions of p_sql, as the current role.
create or replace function perf.median_ms(p_sql text, p_runs int default 15)
returns numeric
language plpgsql
as $$
declare
  t timestamptz;
  samples numeric[] := '{}';
begin
  execute p_sql;  -- warm-up
  for i in 1..p_runs loop
    t := clock_timestamp();
    execute p_sql;
    samples := samples || (extract(epoch from clock_timestamp() - t) * 1000)::numeric;
  end loop;
  return (select percentile_cont(0.5) within group (order by s) from unnest(samples) s)::numeric(10, 2);
end;
$$;
grant execute on function perf.median_ms(text, int) to authenticated;

create table if not exists perf.results (label text primary key, median_ms numeric, budget_ms numeric);
grant all on perf.results to authenticated;
truncate perf.results;

-- ---------------------------------------------------------------------------
-- Seed
-- ---------------------------------------------------------------------------
select tests.create_user('perf-owner@test.local', 'Pemilik') as owner \gset
select tests.authenticate_as(:'owner');
select public.create_family('Keluarga Besar') as fam \gset
select code as inv from public.create_invitation(:'fam', 200, 24) \gset
select tests.clear_authentication();

create temp table perf_users as
  select tests.create_user('perf-' || g || '@test.local', 'Ahli ' || g) as id, g from generate_series(1, 99) g;
-- join everyone through the real RPC (rate limits are per user)
select set_config('perf.inv', :'inv', true);
do $$
declare r record;
begin
  for r in select id from perf_users loop
    perform tests.authenticate_as(r.id);
    perform public.redeem_invitation(current_setting('perf.inv'));
    perform tests.clear_authentication();
  end loop;
end $$;
grant select on perf_users to authenticated;
select count(*) as members from public.family_members where family_id = :'fam' and status = 'active' \gset
\echo seeded members: :members

-- group with everyone + 19 direct chats of the owner
select tests.authenticate_as(:'owner');
select public.create_group_conversation(gen_random_uuid(), :'fam', 'Semua', null,
  (select array_agg(id) from perf_users)) as grp \gset
select public.get_or_create_direct_conversation(:'fam', id) from perf_users where g <= 19;
select tests.clear_authentication();

-- bulk data without triggers (notifications are measured separately below)
set session_replication_role = replica;
insert into public.messages (id, conversation_id, family_id, sender_id, body, created_at)
select gen_random_uuid(), :'grp', :'fam', (select id from perf_users where g = 1 + (i % 99)),
       'Mesej ujian nombor ' || i, now() - make_interval(mins => 20000 - i)
from generate_series(1, 20000) i;
insert into public.messages (id, conversation_id, family_id, sender_id, body, created_at)
select gen_random_uuid(), c.id, :'fam', :'owner', 'Hai ' || i, now() - make_interval(mins => 300 - i)
from public.conversations c, generate_series(1, 263) i
where c.family_id = :'fam' and c.kind = 'direct';

insert into public.todo_lists (id, family_id, name, created_by)
select gen_random_uuid(), :'fam', 'Senarai ' || l, :'owner' from generate_series(1, 5) l;
insert into public.todo_items (id, list_id, family_id, title, due_at, created_by, status, completed_at)
select gen_random_uuid(), l.id, :'fam', 'Tugasan ' || i, now() + make_interval(days => i % 30 - 10), :'owner',
       case when i % 3 = 0 then 'completed'::public.todo_status else 'open' end,
       case when i % 3 = 0 then now() end
from public.todo_lists l, generate_series(1, 400) i where l.family_id = :'fam';
insert into public.todo_assignments (item_id, user_id, list_id, family_id)
select i.id, (select id from perf_users where g = 1 + (abs(hashtext(i.id::text)) % 99)), i.list_id, :'fam'
from public.todo_items i where i.family_id = :'fam';

insert into public.family_events (id, family_id, title, starts_at, ends_at, recurrence, created_by)
select gen_random_uuid(), :'fam', 'Acara ' || i,
       date_trunc('day', now()) + make_interval(days => i % 120 - 30, hours => 9),
       date_trunc('day', now()) + make_interval(days => i % 120 - 30, hours => 11),
       case when i % 10 = 0 then 'weekly' else 'none' end, :'owner'
from generate_series(1, 500) i;
insert into public.event_participants (event_id, user_id, family_id, rsvp)
select e.id, u.id, :'fam', 'going' from public.family_events e
join perf_users u on u.g <= 10 where e.family_id = :'fam';
insert into public.event_reminders (event_id, user_id, minutes_before)
select event_id, user_id, 60 from public.event_participants where family_id = :'fam';

insert into public.notifications (user_id, family_id, type, title, body, dedupe_key, read_at)
select :'owner', :'fam', 'group_message', 'FamilySync', 'Mesej ' || i, 'perf:' || i,
       case when i % 4 = 0 then null else now() end
from generate_series(1, 20000) i;
set session_replication_role = origin;
analyze public.messages, public.conversations, public.conversation_members, public.todo_items, public.todo_assignments, public.todo_lists, public.family_events, public.event_participants, public.event_reminders, public.notifications, public.family_members;

-- ---------------------------------------------------------------------------
-- Measure as the owner (member of everything) through RLS
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'owner');

insert into perf.results values
 ('chat list (conversation_summaries)',
   perf.median_ms(format($q$select * from public.conversation_summaries(%L)$q$, :'fam')), 150),
 ('message page (40 newest, 20k-message group)',
   perf.median_ms(format($q$select m.*, (select json_agg(a) from public.message_attachments a where a.message_id = m.id)
     from public.messages m where conversation_id = %L order by created_at desc, id desc limit 40$q$, :'grp')), 50),
 ('older page (offset 10k messages back)',
   perf.median_ms(format($q$select * from public.messages where conversation_id = %L
     and created_at < now() - interval '10000 minutes' order by created_at desc, id desc limit 40$q$, :'grp')), 50),
 ('message search',
   perf.median_ms(format($q$select * from public.search_messages(%L, 'nombor 1999')$q$, :'fam')), 300),
 ('To-Do overview (todo_list_summaries)',
   perf.median_ms(format($q$select * from public.todo_list_summaries(%L)$q$, :'fam')), 100),
 ('To-Do list items (400 + assignees)',
   perf.median_ms(format($q$select i.*, (select array_agg(user_id) from public.todo_assignments a where a.item_id = i.id)
     from public.todo_items i where list_id = (select id from public.todo_lists where family_id = %L limit 1)
     and deleted_at is null order by position$q$, :'fam')), 100),
 ('dashboard open tasks (200)',
   perf.median_ms(format($q$select * from public.todo_items where family_id = %L and status = 'open'
     and deleted_at is null order by due_at limit 200$q$, :'fam')), 100),
 ('calendar month grid (calendar_occurrences, 42 days)',
   perf.median_ms(format($q$select * from public.calendar_occurrences(%L, date_trunc('month', now()), date_trunc('month', now()) + interval '42 days')$q$, :'fam')), 150),
 ('family members + profiles (100)',
   perf.median_ms(format($q$select m.*, p.display_name from public.family_members m join public.profiles p on p.id = m.user_id
     where m.family_id = %L$q$, :'fam')), 50),
 ('notification inbox (100 of 20k)',
   perf.median_ms($q$select * from public.notifications where user_id = auth.uid() order by created_at desc limit 100$q$), 50),
 ('unread notification count',
   perf.median_ms($q$select count(*) from public.notifications where user_id = auth.uid() and read_at is null$q$), 50);

-- Writes with their triggers (fan-out to 99 recipients)
insert into perf.results values
 ('send message to 100-member group (+99 notifications)',
   perf.median_ms(format($q$select public.send_message(gen_random_uuid(), %L, 'Pengumuman penting')$q$, :'grp'), 10), 150),
 ('complete a task',
   perf.median_ms(format($q$select public.set_todo_item_status(id, true) from public.todo_items
     where family_id = %L and status = 'open' limit 1$q$, :'fam'), 10), 100);
select tests.clear_authentication();

insert into perf.results values
 ('reminder dispatch run (500 events, 5000 reminders)',
   perf.median_ms($q$select private.dispatch_event_reminders()$q$, 5), 1000);

\echo
select rpad(label, 56) as query, median_ms as "median ms", budget_ms as "budget ms",
       case when median_ms <= budget_ms then 'ok' else 'SLOW' end as result
from perf.results order by label;

select count(*) filter (where median_ms > budget_ms) as slow_count, count(*) filter (where median_ms > budget_ms) > 0 as slow from perf.results \gset
rollback;
\if :slow
  \echo PERF FAIL: :slow_count queries over budget
  select 1/0;
\else
  \echo PERF OK
\endif
