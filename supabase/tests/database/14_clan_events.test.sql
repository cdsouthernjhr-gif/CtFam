-- FamilySync — clan events (rumpun stage 3): visibility, RSVP and reminders
-- across linked families; organiser-only editing; notifications widen to the
-- clan for events ONLY.
begin;
select no_plan();

select tests.create_user('ea@test.local', 'Abdul Rahman') as ua \gset
select tests.create_user('eb@test.local', 'Anak Sulung') as ub \gset
select tests.create_user('ed@test.local', 'Cucu') as ud \gset
select tests.create_user('ee@test.local', 'Luar') as ue \gset

select tests.authenticate_as(:'ua');
select public.create_family('Induk') as p \gset
select code as inv_p from public.create_invitation(:'p', 10, 24) \gset
select tests.authenticate_as(:'ub');
select public.redeem_invitation(:'inv_p');
select public.create_family('Cabang') as c1 \gset
select code as inv_c from public.create_invitation(:'c1', 10, 24) \gset
select tests.authenticate_as(:'ud'); select public.redeem_invitation(:'inv_c');
select tests.authenticate_as(:'ue'); select public.create_family('Luar');
select tests.authenticate_as(:'ub');
select (public.request_family_link(:'p', :'c1')).id as link \gset
select tests.authenticate_as(:'ua'); select public.respond_family_link(:'link', true);

select gen_random_uuid() as raya, gen_random_uuid() as meet \gset
select public.upsert_family_event(:'raya', :'p', 'Hari Raya di rumah Tok', '2027-03-10 02:00+00', '2027-03-10 08:00+00',
  false, 'Asia/Kuala_Lumpur', null, 'Rumah Tok', 'religious', 'none', null, 'clan', null, array[60]);
select public.upsert_family_event(:'meet', :'p', 'Mesyuarat induk', '2027-03-11 02:00+00', '2027-03-11 03:00+00');

-- A branch member sees the clan event, not the family-only one
select tests.authenticate_as(:'ud');
select is((select array_agg(title order by title) from public.family_events), array['Hari Raya di rumah Tok'],
  'branch member sees the clan event only');
select is((select count(*)::int from public.calendar_occurrences(:'c1', '2027-03-01', '2027-04-01') where event_id = :'raya'), 1,
  'clan event appears in the branch family''s calendar');
select is((select count(*)::int from public.calendar_occurrences(:'c1', '2027-03-01', '2027-04-01') where event_id = :'meet'), 0,
  'family-only events of the parent do not');
select is((public.set_event_rsvp(:'raya', 'going')).rsvp, 'going', 'branch member RSVPs');
select is((select array_agg(minutes_before) from public.event_reminders where event_id = :'raya'), array[60],
  'and gets the event''s default reminder');
select throws_ok(format($$ select public.upsert_family_event(%L, %L, 'Ubah', '2027-03-10 02:00+00', '2027-03-10 08:00+00') $$,
  :'raya', :'p'), '42501', null, 'only the organiser''s family edits');
select throws_ok(format($$ select public.delete_family_event(%L) $$, :'raya'), '42501', null, 'or deletes');

select tests.authenticate_as(:'ue');
select is((select count(*)::int from public.family_events), 0, 'outsiders see no clan events');
select throws_ok(format($$ select public.set_event_rsvp(%L, 'going') $$, :'raya'), '42501', null, 'and cannot RSVP');

-- Reminders and change notices reach the branch participant
select tests.clear_authentication();
delete from public.notifications;
select is(private.dispatch_event_reminders('2027-03-10 01:00+00'), 2, 'reminder for A (organiser) and D (branch)');
select is((select count(*)::int from public.notifications where user_id = :'ud' and dedupe_key like 'remind:%'), 1, 'D is reminded');
select tests.authenticate_as(:'ua');
select public.upsert_family_event(:'raya', :'p', 'Hari Raya di rumah Tok', '2027-03-10 03:00+00', '2027-03-10 08:00+00',
  false, 'Asia/Kuala_Lumpur', null, 'Rumah Tok', 'religious', 'none', null, 'clan', null, null, 1);
select tests.clear_authentication();
select is((select count(*)::int from public.notifications where user_id = :'ud' and dedupe_key like 'event-upd:%'), 1,
  'D is told the time changed');

-- Chats do NOT widen: D joins P, joins a chat, leaves P -> no chat notices
select tests.authenticate_as(:'ud'); select public.redeem_invitation(:'inv_p');
select tests.authenticate_as(:'ua');
select public.create_group_conversation(gen_random_uuid(), :'p', 'Induk sahaja', null, array[:'ud']::uuid[]) as g \gset
select tests.authenticate_as(:'ud'); select public.leave_family(:'p');
select tests.clear_authentication(); delete from public.notifications;
select tests.authenticate_as(:'ua'); select public.send_message(gen_random_uuid(), :'g', 'Hal keluarga induk');
select tests.clear_authentication();
select is((select count(*)::int from public.notifications where user_id = :'ud'), 0,
  'someone who left the family gets no chat notifications, even while in a linked family');

-- Unlinking hides the clan event again
select tests.authenticate_as(:'ua'); select public.remove_family_link(:'link');
select tests.authenticate_as(:'ud');
select is((select count(*)::int from public.family_events where id = :'raya'), 0, 'after unlinking the event is gone for the branch');

select * from finish();
rollback;
