-- FamilySync — Offline replay guarantees (Phase 6).
-- The app's outbox re-sends a write when it does not know whether the first
-- attempt reached the server. Every replayed RPC must therefore be idempotent,
-- and a queued edit based on an old revision must be rejected, not applied.
begin;
select no_plan();

select tests.create_user('oa@test.local', 'Aminah') as ua \gset
select tests.create_user('ob@test.local', 'Badrul') as ub \gset
select tests.authenticate_as(:'ua');
select public.create_family('Keluarga Luar Talian') as f1 \gset
select code as inv from public.create_invitation(:'f1', 5, 24) \gset
select tests.authenticate_as(:'ub'); select public.redeem_invitation(:'inv');

select tests.authenticate_as(:'ua');
select gen_random_uuid() as l1, gen_random_uuid() as i1, gen_random_uuid() as m1, gen_random_uuid() as e1 \gset
select public.create_todo_list(:'l1', :'f1', 'Dapur');

-- To-Do create replayed 3x -> one item, revision 1
select public.upsert_todo_item(:'i1', :'l1', 'Beli beras') from generate_series(1, 3);
select is((select count(*)::int from public.todo_items where id = :'i1'), 1, 'replayed create stores one item');
select is((select revision from public.todo_items where id = :'i1'), 1, 'replayed create does not bump revision');

-- Status replayed -> applied once (set semantics, no toggle)
select public.set_todo_item_status(:'i1', true) from generate_series(1, 3);
select is((select status::text from public.todo_items where id = :'i1'), 'completed', 'replayed status stays completed');
select is((select revision from public.todo_items where id = :'i1'), 2, 'status replay bumps revision once');

-- Offline edit carrying an old revision after someone else edited -> conflict
select tests.authenticate_as(:'ub');
select public.upsert_todo_item(:'i1', :'l1', 'Beli beras 5kg', null, 'normal', null, 'none', null, 2);
select tests.authenticate_as(:'ua');
select throws_ok(format($$ select public.upsert_todo_item(%L, %L, 'Beli beras wangi', null, 'normal', null, 'none', null, 2) $$,
  :'i1', :'l1'), 'P0409', null, 'stale queued edit is rejected (revision_conflict)');
select is((select title from public.todo_items where id = :'i1'), 'Beli beras 5kg', 'the other edit is kept');
-- Queued follow-up edits without a revision (own chained offline edits) apply
select lives_ok(format($$ select public.upsert_todo_item(%L, %L, 'Beli beras wangi') $$, :'i1', :'l1'),
  'edit without expected revision applies');

-- Delete replayed -> no error
select lives_ok(format($$ select public.delete_todo_item(%L) from generate_series(1, 3) $$, :'i1'), 'replayed delete is harmless');

-- Message replayed -> one message
select public.get_or_create_direct_conversation(:'f1', :'ub') as dm \gset
select public.send_message(:'m1', :'dm', 'Dari kereta api') from generate_series(1, 3);
select is((select count(*)::int from public.messages where id = :'m1'), 1, 'replayed message stored once');
select tests.clear_authentication();
select is((select count(*)::int from public.notifications where dedupe_key = 'msg:' || :'m1'), 1, 'and notified once');

-- RSVP replayed -> one participant row, same answer
select tests.authenticate_as(:'ub');
select public.upsert_family_event(:'e1', :'f1', 'Kenduri', now() + interval '1 day', now() + interval '1 day 2 hours');
select tests.authenticate_as(:'ua');
select public.set_event_rsvp(:'e1', 'going') from generate_series(1, 3);
select is((select count(*)::int from public.event_participants where event_id = :'e1' and user_id = :'ua'), 1,
  'replayed RSVP keeps one participant row');

select * from finish();
rollback;
