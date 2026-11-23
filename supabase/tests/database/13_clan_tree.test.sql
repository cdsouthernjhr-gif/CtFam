-- FamilySync — shared clan family tree (rumpun stage 2): clan-wide reading,
-- home-family editing, cross-family approval by both admins, merging
-- duplicates, relationships across families, birthday scope, unlinking.
begin;
select no_plan();

select tests.create_user('ka@test.local', 'Abdul Rahman') as ua \gset
select tests.create_user('kb@test.local', 'Anak Sulung') as ub \gset
select tests.create_user('kd@test.local', 'Ahli Cabang') as ud \gset
select tests.create_user('ke@test.local', 'Luar') as ue \gset

select tests.authenticate_as(:'ua');
select public.create_family('Keluarga Induk') as p \gset
select code as inv_p from public.create_invitation(:'p', 10, 24) \gset
select tests.authenticate_as(:'ub');
select public.redeem_invitation(:'inv_p');
select public.create_family('Keluarga Cabang') as c1 \gset
select code as inv_c from public.create_invitation(:'c1', 10, 24) \gset
select tests.authenticate_as(:'ud'); select public.redeem_invitation(:'inv_c');
select tests.authenticate_as(:'ue'); select public.create_family('Keluarga Luar');
select tests.authenticate_as(:'ub');
select (public.request_family_link(:'p', :'c1')).id as link \gset
select tests.authenticate_as(:'ua'); select public.respond_family_link(:'link', true);

select gen_random_uuid() as ar, gen_random_uuid() as ais, gen_random_uuid() as b_p, gen_random_uuid() as adik,
       gen_random_uuid() as b_c, gen_random_uuid() as w, gen_random_uuid() as k, gen_random_uuid() as anakadik \gset

-- Parent family records (A)
select public.upsert_person(:'ar', :'p', 'Abdul Rahman', 'male', '1950-01-01');
select public.upsert_person(:'ais', :'p', 'Aisyah', 'female', '1955-02-02');
select public.upsert_person(:'b_p', :'p', 'Sulung bin Abdul Rahman', 'male', '1980-05-05');
select public.upsert_person(:'adik', :'p', 'Adik', 'male', '1985-06-06');
select public.link_person_account(:'b_p', :'ub');
select public.propose_relation(gen_random_uuid(), :'p', 'spouse', :'ar', :'ais');
select public.propose_relation(gen_random_uuid(), :'p', 'parent', :'ar', id) from unnest(array[:'b_p', :'adik']::uuid[]) id;
select public.propose_relation(gen_random_uuid(), :'p', 'parent', :'ais', id) from unnest(array[:'b_p', :'adik']::uuid[]) id;

-- Branch family records (B), including a duplicate of B himself
select tests.authenticate_as(:'ub');
select public.upsert_person(:'b_c', :'c1', 'Sulung', 'male', '1980-05-05', null, null, true);
select public.upsert_person(:'w', :'c1', 'Isteri Sulung', 'female', '1982-03-03');
select public.upsert_person(:'k', :'c1', 'Cucu Pertama', 'male', '2008-08-08');
select public.upsert_person(:'anakadik', :'c1', 'Anak Adik', 'female', '2015-09-09');
select public.propose_relation(gen_random_uuid(), :'c1', 'spouse', :'b_c', :'w');
select public.propose_relation(gen_random_uuid(), :'c1', 'parent', :'b_c', :'k');
select public.propose_relation(gen_random_uuid(), :'c1', 'parent', :'w', :'k');

-- ---------------------------------------------------------------------------
-- Clan-wide reading, home-family editing
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'ud');
select is((select count(*)::int from public.family_persons where family_id = :'p'), 4,
  'a branch member sees the parent family''s tree (2a)');
select is((select birth_date from public.family_persons where id = :'ar'), '1950-01-01'::date, 'including birth dates');
select throws_ok(format($$ select public.upsert_person(%L, %L, 'Ubah', 'male', '1950-01-01') $$, :'ar', :'p'), '42501', null,
  'records are edited only by their home family');
select tests.authenticate_as(:'ub');
select throws_ok(format($$ select public.upsert_person(%L, %L, 'Ubah', 'male', '1950-01-01') $$, :'ar', :'p'), '42501', null,
  'B (plain member of the parent family) cannot edit its records either');
select tests.authenticate_as(:'ue');
select is((select count(*)::int from public.family_persons where family_id in (:'p', :'c1')), 0, 'outsiders see nothing');

-- ---------------------------------------------------------------------------
-- Merging the duplicate (needs the other family's admin)
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'ub');
select is((select count(*)::int from public.merge_suggestions(:'c1') where keep_id = :'b_p' and remove_id = :'b_c'), 1,
  'the duplicate is suggested (same account, gender, birth date)');
select throws_ok(format($$ select public.merge_persons(%L, %L) $$, :'ar', :'k'), '22023', 'not_same_person',
  'different birth dates are never merged');
select is(public.merge_persons(:'b_p', :'b_c'), 'pending', 'cross-family merge waits for the parent family''s admin');
select is((select deleted_at is null from public.family_persons where id = :'b_c'), true, 'nothing changes yet');
select tests.clear_authentication();
select is((select count(*)::int from public.notifications where user_id = :'ua' and dedupe_key like 'tree-merge:%'), 1,
  'the parent family''s admin is asked');
select id as merge_id from public.person_merges where keep_id = :'b_p' and remove_id = :'b_c' \gset
select tests.authenticate_as(:'ub');
select throws_ok(format($$ select public.review_person_merge(%L, true) $$, :'merge_id'), '42501', null,
  'the requester cannot approve');
select tests.authenticate_as(:'ua');
select is(public.review_person_merge(:'merge_id', true), 'done', 'parent admin approves');
select is((select deleted_at is not null from public.family_persons where id = :'b_c'), true, 'the duplicate is retired');
select is((select count(*)::int from public.family_relations where person_a = :'b_p' and person_b = :'k' and status = 'confirmed'), 1,
  'the child now hangs under the kept record');
select is((select other_family_id from public.family_relations where person_a = :'b_p' and person_b = :'k'), :'c1'::uuid,
  'which is a cross-family link');

-- Relationships across the clan
select is(public.relationship_between(:'p', :'k', :'ar') ->> 'ms', 'cucu', 'Abdul Rahman -> Cucu Pertama: cucu');
select is(public.relationship_between(:'p', :'ar', :'k') ->> 'ms', 'datuk', 'from the grandchild''s view: datuk');
select throws_ok(format($$ select public.relationship_between(%L, %L) $$, :'c1', :'ar'), '42501', null,
  'the acting family must be one of yours');
select tests.authenticate_as(:'ub');
select is(public.relationship_between(:'c1', :'ar') ->> 'ms', 'bapa', 'B''s own (merged) record is found across the clan');
select is(public.relationship_between(:'c1', :'w') ->> 'ms', 'isteri', 'and his wife in the branch family');

-- ---------------------------------------------------------------------------
-- Cross-family relation needs BOTH admins (3a)
-- ---------------------------------------------------------------------------
select (public.propose_relation(gen_random_uuid(), :'c1', 'parent', :'adik', :'anakadik')).id as xrel \gset
select is((select status || ':' || family_ok || ':' || other_ok from public.family_relations where id = :'xrel'),
  'pending:false:true', 'B approves his side by proposing; the parent family''s side is missing');
select is(public.relationship_between(:'c1', :'anakadik', :'k') ->> 'kind', 'none', 'not counted while pending');
select tests.authenticate_as(:'ud');
select throws_ok(format($$ select public.review_relation(%L, true) $$, :'xrel'), '42501', null, 'plain members cannot approve');
select tests.authenticate_as(:'ua');
select is((public.review_relation(:'xrel', true)).status, 'confirmed', 'parent admin approves: confirmed');
select is(public.relationship_between(:'p', :'anakadik', :'k') ->> 'ms', 'sepupu', 'now Cucu Pertama and Anak Adik are sepupu');

-- ---------------------------------------------------------------------------
-- Birthdays (4a): home family + every family of the person's account
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
delete from public.notifications;
select is(private.dispatch_birthdays('2026-05-05'), 3, 'B''s birthday: A (parent family), D (B''s own family), and B greeted');
select is((select count(*)::int from public.notifications where user_id = :'ue'), 0, 'outsiders are not told');

-- ---------------------------------------------------------------------------
-- Unlinking separates the trees again
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'ua');
select public.remove_family_link(:'link');
select tests.authenticate_as(:'ud');
select is((select count(*)::int from public.family_persons where family_id = :'p'), 0,
  'after unlinking, the branch no longer sees the parent''s tree');
select throws_ok(format($$ select public.relationship_between(%L, %L, %L) $$, :'c1', :'ar', :'k'), 'P0002', null,
  'and relationships no longer cross');

select * from finish();
rollback;
