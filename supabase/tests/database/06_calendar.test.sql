-- FamilySync — Calendar: RLS, visibility, RPC permissions, idempotency,
-- revision conflicts, recurrence expansion, RSVP, reminders, notifications.
begin;
select no_plan();

select tests.create_user('ca@test.local', 'Aminah') as ua \gset
select tests.create_user('cb@test.local', 'Badrul') as ub \gset
select tests.create_user('cc@test.local', 'Chong') as uc \gset
select tests.create_user('cd@test.local', 'Dina') as ud \gset
select tests.create_user('ce@test.local', 'Ehsan') as ue \gset

select tests.authenticate_as(:'ua');
select public.create_family('Keluarga Kalendar') as f1 \gset
select code as inv from public.create_invitation(:'f1', 5, 24) \gset
select tests.authenticate_as(:'ub'); select public.redeem_invitation(:'inv');
select tests.authenticate_as(:'uc'); select public.redeem_invitation(:'inv');
select tests.authenticate_as(:'ud'); select public.redeem_invitation(:'inv');
select tests.authenticate_as(:'ue'); select public.create_family('Lain') as f2 \gset
select tests.clear_authentication();
-- D is a plain member, promote nobody; A = owner
delete from public.notifications;

select gen_random_uuid() as ev1, gen_random_uuid() as ev2, gen_random_uuid() as ev3, gen_random_uuid() as ev4 \gset

-- ---------------------------------------------------------------------------
-- Create (idempotent), validation, cross-family
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'ub');
select lives_ok(format($$ select public.upsert_family_event(%L, %L, 'Kenduri', '2027-01-10 04:00+00', '2027-01-10 08:00+00',
  false, 'Asia/Kuala_Lumpur', 'Bawa lauk', 'Rumah Tok', 'family', 'none', null, 'family', array[%L, %L]::uuid[], array[60]) $$,
  :'ev1', :'f1', :'uc', :'ud'), 'member creates an event with participants');
select lives_ok(format($$ select public.upsert_family_event(%L, %L, 'Kenduri', '2027-01-10 04:00+00', '2027-01-10 08:00+00',
  false, 'Asia/Kuala_Lumpur', 'Bawa lauk', 'Rumah Tok', 'family', 'none', null, 'family', array[%L, %L]::uuid[], array[60]) $$,
  :'ev1', :'f1', :'uc', :'ud'), 'replaying the same create is idempotent');
select is((select count(*)::int from public.family_events where id = :'ev1'), 1, 'one row after replay');
select is((select revision from public.family_events where id = :'ev1'), 1, 'replay does not bump revision');
select is((select count(*)::int from public.event_participants where event_id = :'ev1'), 3, 'creator + 2 participants');
select is((select rsvp from public.event_participants where event_id = :'ev1' and user_id = :'ub'), 'going', 'creator is going');
select is((select array_agg(minutes_before) from public.event_reminders where event_id = :'ev1'), array[60],
  'caller sees only own reminders (RLS)');

select throws_ok(format($$ select public.upsert_family_event(%L, %L, 'Salah', '2027-01-10 08:00+00', '2027-01-10 04:00+00') $$,
  gen_random_uuid(), :'f1'), '22023', null, 'end before start rejected');
select throws_ok(format($$ select public.upsert_family_event(%L, %L, 'TZ', '2027-01-10 04:00+00', '2027-01-10 05:00+00', false, 'Mars/Olympus') $$,
  gen_random_uuid(), :'f1'), '22023', null, 'invalid time zone rejected');
select throws_ok(format($$ select public.upsert_family_event(%L, %L, 'Rem', '2027-01-10 04:00+00', '2027-01-10 05:00+00',
  false, 'Asia/Kuala_Lumpur', null, null, 'family', 'none', null, 'family', null, array[1,2,3,4,5,6]) $$,
  gen_random_uuid(), :'f1'), '22023', null, 'more than 5 reminders rejected');
select throws_ok(format($$ select public.upsert_family_event(%L, %L, 'Luar', '2027-01-10 04:00+00', '2027-01-10 05:00+00',
  false, 'Asia/Kuala_Lumpur', null, null, 'family', 'none', null, 'family', array[%L]::uuid[]) $$,
  gen_random_uuid(), :'f1', :'ue'), '22023', null, 'non-member cannot be invited');

select tests.authenticate_as(:'ue');
select throws_ok(format($$ select public.upsert_family_event(%L, %L, 'Ceroboh', '2027-01-10 04:00+00', '2027-01-10 05:00+00') $$,
  gen_random_uuid(), :'f1'), '42501', null, 'outsider cannot create in another family');
select is((select count(*)::int from public.family_events), 0, 'outsider sees no events of other families');
select is((select count(*)::int from public.event_participants), 0, 'outsider sees no participants');
select throws_ok(format($$ select public.set_event_rsvp(%L, 'going') $$, :'ev1'), '42501', null, 'outsider cannot RSVP');
select throws_ok(format($$ select public.upsert_family_event(%L, %L, 'Hijack', '2027-01-10 04:00+00', '2027-01-10 05:00+00') $$,
  :'ev1', :'f2'), '42501', null, 'existing id in another family cannot be hijacked');

-- ---------------------------------------------------------------------------
-- Invitation notifications
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
select is((select count(*)::int from public.notifications where type = 'family_event' and dedupe_key like 'event-invite:%'), 2,
  'invited participants notified (creator not)');
select is((select data ->> 'route' from public.notifications where user_id = :'uc' and type = 'family_event'), '/calendar/' || :'ev1',
  'invite routes to the event');
select ok((select body like 'Badrul menjemput anda ke "Kenduri" · 10/01/2027 12:00' from public.notifications
           where user_id = :'uc' and type = 'family_event'), 'invite text in the event time zone');

-- ---------------------------------------------------------------------------
-- Update: permissions, revision conflict, change notification
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'uc');
select throws_ok(format($$ select public.upsert_family_event(%L, %L, 'Diubah C', '2027-01-10 04:00+00', '2027-01-10 08:00+00') $$,
  :'ev1', :'f1'), '42501', null, 'participant (not creator/admin) cannot edit');
select throws_ok(format($$ select public.delete_family_event(%L) $$, :'ev1'), '42501', null, 'participant cannot delete');

select tests.authenticate_as(:'ua');
select lives_ok(format($$ select public.upsert_family_event(%L, %L, 'Kenduri Besar', '2027-01-10 05:00+00', '2027-01-10 09:00+00',
  false, 'Asia/Kuala_Lumpur', 'Bawa lauk', 'Rumah Tok', 'family', 'none', null, 'family', null, null, 1) $$, :'ev1', :'f1'),
  'owner edits with the current revision');
select is((select revision from public.family_events where id = :'ev1'), 2, 'revision bumped');
select throws_ok(format($$ select public.upsert_family_event(%L, %L, 'Stale', '2027-01-10 05:00+00', '2027-01-10 09:00+00',
  false, 'Asia/Kuala_Lumpur', null, null, 'family', 'none', null, 'family', null, null, 1) $$, :'ev1', :'f1'),
  'P0409', null, 'stale revision raises revision_conflict');
select tests.clear_authentication();
select is((select count(*)::int from public.notifications where dedupe_key = 'event-upd:' || :'ev1' || ':2'), 3,
  'time change notifies all participants except the editor (B, C, D)');

-- ---------------------------------------------------------------------------
-- Visibility 'participants'
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'ub');
select public.upsert_family_event(:'ev2', :'f1', 'Hadiah rahsia', '2027-02-01 02:00+00', '2027-02-01 03:00+00',
  false, 'Asia/Kuala_Lumpur', null, null, 'birthday', 'none', null, 'participants', array[:'uc']::uuid[]);
select tests.authenticate_as(:'ud');
select is((select count(*)::int from public.family_events where id = :'ev2'), 0, 'non-participant cannot see a private event');
select throws_ok(format($$ select public.set_event_rsvp(%L, 'going') $$, :'ev2'), '42501', null, 'non-participant cannot join a private event');
select tests.authenticate_as(:'uc');
select is((select count(*)::int from public.family_events where id = :'ev2'), 1, 'participant sees the private event');
select tests.authenticate_as(:'ua');
select is((select count(*)::int from public.family_events where id = :'ev2'), 1, 'owner sees the private event');

-- ---------------------------------------------------------------------------
-- RSVP and reminders
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'uc');
select is((public.set_event_rsvp(:'ev1', 'maybe')).rsvp, 'maybe', 'participant RSVPs maybe');
select throws_ok(format($$ select public.set_event_rsvp(%L, 'yes') $$, :'ev1'), '22023', null, 'invalid RSVP value rejected');
select is(public.set_event_reminders(:'ev1', array[1440, 10, 10]), array[10, 1440], 'reminders cleaned and sorted');
select is((select count(*)::int from public.event_reminders where event_id = :'ev1'), 2, 'C has 2 reminders');
select throws_ok(format($$ select public.set_event_reminders(%L, array[-5]) $$, :'ev1'), '22023', null, 'negative reminder rejected');
select throws_ok(format($$ insert into public.event_reminders (event_id, user_id, minutes_before) values (%L, %L, 5) $$, :'ev1', :'uc'),
  '42501', null, 'no direct writes to reminders');
select throws_ok(format($$ update public.family_events set title = 'x' where id = %L $$, :'ev1'), '42501', null,
  'no direct writes to events');

select tests.authenticate_as(:'ua');
select throws_ok(format($$ select public.set_event_reminders(%L, array[5]) $$, :'ev1'), '22023', null,
  'owner who is not a participant cannot set reminders');
select is((public.set_event_rsvp(:'ev1', 'going')).rsvp, 'going', 'any member can join a family event by RSVP');
select is((select array_agg(minutes_before) from public.event_reminders where event_id = :'ev1'), array[60],
  'joining copies the event default reminders');

-- ---------------------------------------------------------------------------
-- Recurrence expansion
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'ub');
-- Monthly on Jan 31, 09:00 Kuala Lumpur
select public.upsert_family_event(:'ev3', :'f1', 'Bayar sewa', '2027-01-31 01:00+00', '2027-01-31 02:00+00',
  false, 'Asia/Kuala_Lumpur', null, null, 'other', 'monthly', '2027-05-31', 'family');
select is((select array_agg(occurrence_start order by occurrence_start)
           from public.calendar_occurrences(:'f1', '2027-01-01', '2027-12-31') where event_id = :'ev3'),
  array['2027-01-31 01:00+00', '2027-02-28 01:00+00', '2027-03-31 01:00+00', '2027-04-30 01:00+00', '2027-05-31 01:00+00']::timestamptz[],
  'monthly: clamps to month end without drift, stops at recurrence_until');

-- Weekly across a DST change (Europe/London): local time stays 18:00
select public.upsert_family_event(:'ev4', :'f1', 'Kelas', '2027-03-21 18:00+00', '2027-03-21 19:00+00',
  false, 'Europe/London', null, null, 'school', 'weekly', null, 'family');
select is((select array_agg(occurrence_start order by occurrence_start)
           from public.calendar_occurrences(:'f1', '2027-03-20', '2027-04-05') where event_id = :'ev4'),
  array['2027-03-21 18:00+00', '2027-03-28 17:00+00', '2027-04-04 17:00+00']::timestamptz[],
  'weekly: wall-clock time kept across DST');
select is((select count(*)::int from public.calendar_occurrences(:'f1', '2030-01-01', '2030-03-01') where event_id = :'ev4'), 8,
  'open-ended weekly series still expands years later');

select lives_ok(format($$ select public.cancel_event_occurrence(%L, '2027-03-28 17:00+00') $$, :'ev4'), 'cancel one occurrence');
select lives_ok(format($$ select public.cancel_event_occurrence(%L, '2027-03-28 17:00+00') $$, :'ev4'), 'cancel is idempotent');
select is((select count(*)::int from public.calendar_occurrences(:'f1', '2027-03-20', '2027-04-05') where event_id = :'ev4'), 2,
  'cancelled occurrence hidden');
select throws_ok(format($$ select public.cancel_event_occurrence(%L, '2027-03-29 17:00+00') $$, :'ev4'), '22023', null,
  'cannot cancel a time that is not an occurrence');
select throws_ok($$ select * from public.calendar_occurrences(null, '2027-01-01', '2029-01-01') $$, '22023', null,
  'range limited to 400 days');

-- Overlap: an event that started before the window but is still running is included
select is((select count(*)::int from public.calendar_occurrences(:'f1', '2027-01-10 06:00+00', '2027-01-10 07:00+00')
           where event_id = :'ev1'), 1, 'ongoing event overlaps the window');

-- ---------------------------------------------------------------------------
-- Reminder dispatch
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
delete from public.notifications;
-- ev1 starts 2027-01-10 05:00 UTC; B has 60 min, C has 10 + 1440, A has 60, D has 60 (pending)
select is(private.dispatch_event_reminders('2027-01-10 03:59+00'), 0, 'nothing due 61 minutes before');
select is(private.dispatch_event_reminders('2027-01-10 04:00+00'), 3, '60-minute reminders fire (A, B, D)');
select is(private.dispatch_event_reminders('2027-01-10 04:03+00'), 0, 'late re-run does not duplicate (dedupe)');
select is(private.dispatch_event_reminders('2027-01-10 04:50+00'), 1, '10-minute reminder fires for C');
select is((select body from public.notifications where user_id = :'uc' and dedupe_key like 'remind:%'),
  'Kenduri Besar · 10/01/2027 13:00 · Rumah Tok', 'reminder text: title, local time, place');

update public.event_participants set rsvp = 'declined' where event_id = :'ev3' and user_id = :'ub';
select is(private.dispatch_event_reminders('2027-03-31 00:00+00'), 0, 'no reminders for declined participants / none set');

-- Recurring reminder for each occurrence
update public.event_participants set rsvp = 'going' where event_id = :'ev4' and user_id = :'ub';
insert into public.event_reminders (event_id, user_id, minutes_before) values (:'ev4', :'ub', 30);
select is(private.dispatch_event_reminders('2027-04-04 16:30+00'), 1, 'reminder for a later occurrence of a weekly series');
select is(private.dispatch_event_reminders('2027-03-28 16:30+00'), 0, 'no reminder for a cancelled occurrence');

-- Member leaves the family: no more reminders, no access
update public.family_members set status = 'left' where family_id = :'f1' and user_id = :'ud';
select is(private.dispatch_event_reminders('2027-04-11 16:30+00'), 1, 'still fires for B');
select tests.authenticate_as(:'ud');
select is((select count(*)::int from public.family_events), 0, 'former member sees no events');

-- ---------------------------------------------------------------------------
-- Delete
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'ub');
select lives_ok(format($$ select public.delete_family_event(%L) $$, :'ev1'), 'creator deletes');
select lives_ok(format($$ select public.delete_family_event(%L) $$, :'ev1'), 'delete is idempotent');
select is((select deleted_at is not null from public.family_events where id = :'ev1'), true,
  'soft-deleted row stays readable (Realtime delivers the deletion)');
select is((select count(*)::int from public.calendar_occurrences(:'f1', '2027-01-01', '2027-02-01') where event_id = :'ev1'), 0,
  'deleted event has no occurrences');
select tests.clear_authentication();
select is((select count(*)::int from public.notifications where dedupe_key = 'event-del:' || :'ev1'), 2,
  'cancellation notifies remaining participants (A, C)');

select tests.authenticate_anon();
select throws_ok($$ select * from public.calendar_occurrences(gen_random_uuid(), now(), now() + interval '1 day') $$,
  '42501', null, 'anon cannot call calendar RPCs');

select tests.clear_authentication();
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public', 'private') and p.prosecdef
    and not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%')), 0,
  'every SECURITY DEFINER function pins search_path');

select * from finish();
rollback;
