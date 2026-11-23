-- FamilySync — Family tree: permissions, validation, computed relationships
-- (Malay/English), pending proposals, account linking, birthdays.
begin;
select no_plan();

select tests.create_user('ta@test.local', 'Amir') as ua \gset
select tests.create_user('tb@test.local', 'Hasan') as ub \gset
select tests.create_user('te@test.local', 'Orang Luar') as ue \gset

select tests.authenticate_as(:'ua');
select public.create_family('Keluarga Salasilah') as f1 \gset
select code as inv from public.create_invitation(:'f1', 5, 24) \gset
select tests.authenticate_as(:'ub'); select public.redeem_invitation(:'inv');
select tests.authenticate_as(:'ue'); select public.create_family('Lain') as f2 \gset

-- ids
select gen_random_uuid() as saya, gen_random_uuid() as ayah, gen_random_uuid() as ibu, gen_random_uuid() as tok,
       gen_random_uuid() as hasan, gen_random_uuid() as siti, gen_random_uuid() as lina, gen_random_uuid() as faris,
       gen_random_uuid() as aina, gen_random_uuid() as irfan, gen_random_uuid() as pakdin, gen_random_uuid() as rizal,
       gen_random_uuid() as rosnah, gen_random_uuid() as halim, gen_random_uuid() as nur, gen_random_uuid() as salmah,
       gen_random_uuid() as karim, gen_random_uuid() as zul, gen_random_uuid() as fatin, gen_random_uuid() as mira,
       gen_random_uuid() as arwah \gset

-- ---------------------------------------------------------------------------
-- People: owner adds everyone (with and without accounts)
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'ua');
select lives_ok(format($$ select public.upsert_person(%L, %L, 'Amir', 'male', '1985-06-01', null, null, true) $$, :'saya', :'f1'),
  'owner creates own record linked to their account');
select public.upsert_person(:'tok', :'f1', 'Tok Wahab', 'male', '1920-01-01', '1995-03-03');
select public.upsert_person(:'ayah', :'f1', 'Ayah', 'male', '1950-02-02');
select public.upsert_person(:'ibu', :'f1', 'Ibu', 'female', '1955-03-03');
select public.upsert_person(:'rosnah', :'f1', 'Rosnah', 'female', '1960-04-04');
select public.upsert_person(:'hasan', :'f1', 'Hasan', 'male', '1980-05-05');
select public.upsert_person(:'siti', :'f1', 'Siti', 'female', '1982-07-07');
select public.upsert_person(:'lina', :'f1', 'Lina', 'female', '1990-08-08');
select public.upsert_person(:'halim', :'f1', 'Halim', 'male', '1995-09-09');
select public.upsert_person(:'faris', :'f1', 'Faris', 'male', '2010-10-10');
select public.upsert_person(:'aina', :'f1', 'Aina', 'female', '2002-11-11');
select public.upsert_person(:'irfan', :'f1', 'Irfan', 'male', '2024-01-15');
select public.upsert_person(:'pakdin', :'f1', 'Pak Din', 'male', '1952-12-12');
select public.upsert_person(:'rizal', :'f1', 'Rizal', 'male', '1984-01-01');
select public.upsert_person(:'nur', :'f1', 'Nur', 'female', '2015-02-14');
select public.upsert_person(:'salmah', :'f1', 'Salmah', 'female', '1987-03-21');
select public.upsert_person(:'karim', :'f1', 'Pak Karim', 'male', '1960-05-30');
select public.upsert_person(:'zul', :'f1', 'Zul', 'male', '1990-06-06');
select public.upsert_person(:'fatin', :'f1', 'Fatin', 'female', '1992-02-29');
select public.upsert_person(:'mira', :'f1', 'Mira', 'female', '1983-04-04');
select is((select count(*)::int from public.family_persons where family_id = :'f1'), 20, 'owner added 20 people');

select throws_ok(format($$ select public.upsert_person(%L, %L, 'Masa depan', 'male', current_date + 1) $$, gen_random_uuid(), :'f1'),
  '22023', null, 'birth date in the future is rejected');
select throws_ok(format($$ select public.upsert_person(%L, %L, 'Tiada', 'male', null) $$, gen_random_uuid(), :'f1'),
  '22023', null, 'birth date is required');
select throws_ok(format($$ select public.upsert_person(%L, %L, 'X', 'other', '2000-01-01') $$, gen_random_uuid(), :'f1'),
  '22023', null, 'gender must be male/female');

-- Relations (owner: confirmed immediately)
select public.propose_relation(gen_random_uuid(), :'f1', 'parent', :'tok', :'ayah');
select public.propose_relation(gen_random_uuid(), :'f1', 'parent', :'tok', :'pakdin');
select public.propose_relation(gen_random_uuid(), :'f1', 'parent', :'pakdin', :'rizal');
select public.propose_relation(gen_random_uuid(), :'f1', 'spouse', :'ayah', :'ibu');
select public.propose_relation(gen_random_uuid(), :'f1', 'parent', :'ayah', id) from unnest(array[:'saya', :'hasan', :'siti', :'lina']::uuid[]) id;
select public.propose_relation(gen_random_uuid(), :'f1', 'parent', :'ibu', id) from unnest(array[:'saya', :'hasan', :'siti', :'lina']::uuid[]) id;
select public.propose_relation(gen_random_uuid(), :'f1', 'parent', :'ayah', :'halim');
select public.propose_relation(gen_random_uuid(), :'f1', 'parent', :'rosnah', :'halim');
select public.propose_relation(gen_random_uuid(), :'f1', 'parent', :'hasan', :'faris');
select public.propose_relation(gen_random_uuid(), :'f1', 'parent', :'siti', :'aina');
select public.propose_relation(gen_random_uuid(), :'f1', 'parent', :'aina', :'irfan');
select public.propose_relation(gen_random_uuid(), :'f1', 'parent', :'saya', :'nur', 'adoptive');
select public.propose_relation(gen_random_uuid(), :'f1', 'spouse', :'saya', :'salmah');
select public.propose_relation(gen_random_uuid(), :'f1', 'parent', :'karim', :'salmah');
select public.propose_relation(gen_random_uuid(), :'f1', 'parent', :'karim', :'zul');
select public.propose_relation(gen_random_uuid(), :'f1', 'spouse', :'zul', :'fatin');
select is((select count(*)::int from public.family_relations where family_id = :'f1' and status = 'confirmed'), 22,
  'owner relations are confirmed immediately');

-- Validation
select throws_ok(format($$ select public.propose_relation(%L, %L, 'parent', %L, %L) $$, gen_random_uuid(), :'f1', :'faris', :'hasan'),
  '22023', 'tree_cycle', 'a child cannot become the parent of their parent (cycle)');
select throws_ok(format($$ select public.propose_relation(%L, %L, 'parent', %L, %L) $$, gen_random_uuid(), :'f1', :'irfan', :'karim'),
  '22023', 'invalid_dates', 'a biological parent must be born before the child');
select throws_ok(format($$ select public.propose_relation(%L, %L, 'parent', %L, %L) $$, gen_random_uuid(), :'f1', :'pakdin', :'saya'),
  '22023', 'too_many_parents', 'only one biological father');
select throws_ok(format($$ select public.propose_relation(%L, %L, 'spouse', %L, %L) $$, gen_random_uuid(), :'f1', :'ayah', :'saya'),
  '22023', 'invalid_input', 'a parent cannot be recorded as a spouse');
select throws_ok(format($$ select public.propose_relation(%L, %L, 'spouse', %L, %L) $$, gen_random_uuid(), :'f1', :'salmah', :'saya'),
  '23505', null, 'duplicate spouse link (either order) is rejected');

-- ---------------------------------------------------------------------------
-- Computed relationships from "Saya" (the caller's own record)
-- ---------------------------------------------------------------------------
create temp table expect (target uuid, ms text, en text);
insert into expect values
  (:'hasan', 'abang', 'older brother'),
  (:'siti', 'kakak', 'older sister'),
  (:'lina', 'adik perempuan', 'younger sister'),
  (:'faris', 'anak saudara', 'nephew'),
  (:'aina', 'anak saudara', 'niece'),
  (:'irfan', 'cucu saudara', 'grandnephew'),
  (:'ayah', 'bapa', 'father'),
  (:'ibu', 'ibu', 'mother'),
  (:'tok', 'datuk', 'grandfather'),
  (:'pakdin', 'bapa saudara', 'uncle'),
  (:'rizal', 'sepupu', 'first cousin'),
  (:'halim', 'adik lelaki sebapa', 'younger half-brother'),
  (:'nur', 'anak perempuan (angkat)', 'adoptive daughter'),
  (:'salmah', 'isteri', 'wife'),
  (:'karim', 'bapa mertua', 'father-in-law'),
  (:'zul', 'adik ipar', 'brother-in-law'),
  (:'fatin', 'biras', 'co-sibling-in-law');
grant select on expect to authenticated;
select is(
  (select array_agg(e.ms || ' / ' || e.en order by e.ms) from expect e),
  (select array_agg((r ->> 'ms') || ' / ' || (r ->> 'en') order by e.ms)
     from expect e, lateral public.relationship_between(:'f1', e.target) r),
  'all computed relationships match (BM / EN)');
select is((public.relationship_between(:'f1', :'faris') ->> 'via')::uuid, :'hasan'::uuid,
  'anak saudara is explained through the target''s parent (anak kepada Hasan)');
select is((public.relationship_between(:'f1', :'irfan') ->> 'via')::uuid, :'aina'::uuid,
  'cucu saudara explained through Aina (cucu kepada Kakak Siti)');
select is(public.relationship_between(:'f1', :'irfan') ->> 'up', '1', 'cucu saudara: up 1');
select is(public.relationship_between(:'f1', :'irfan') ->> 'down', '3', 'cucu saudara: down 3');
select is(public.relationship_between(:'f1', :'saya') ->> 'kind', 'self', 'self');
select is(public.relationship_between(:'f1', :'mira') ->> 'kind', 'none', 'Mira is not linked yet');

-- From another person's point of view
select is(public.relationship_between(:'f1', :'saya', :'faris') ->> 'ms', 'bapa saudara', 'to Faris, Amir is bapa saudara');
select is(public.relationship_between(:'f1', :'tok', :'irfan') ->> 'ms', 'nenek moyang', 'to Irfan, Tok is nenek moyang (4 generations)');

-- ---------------------------------------------------------------------------
-- Member permissions and pending proposals
-- ---------------------------------------------------------------------------
select lives_ok(format($$ select public.link_person_account(%L, %L) $$, :'hasan', :'ub'), 'owner links Hasan''s record to his account');
select throws_ok(format($$ select public.link_person_account(%L, %L) $$, :'siti', :'ub'), '22023', 'already_linked',
  'an account links to one person only');
select throws_ok(format($$ select public.link_person_account(%L, %L) $$, :'siti', :'ue'), '22023', 'not_family_member',
  'only members of the family can be linked');

select tests.authenticate_as(:'ub');
select is(public.relationship_between(:'f1', :'saya') ->> 'ms', 'adik lelaki', 'to Hasan (his own record), Amir is adik lelaki');
select throws_ok(format($$ select public.upsert_person(%L, %L, 'Orang Baru', 'male', '2000-01-01') $$, gen_random_uuid(), :'f1'),
  '42501', null, 'a member cannot add other people');
select throws_ok(format($$ select public.upsert_person(%L, %L, 'Siti Ubah', 'female', '1982-07-07') $$, :'siti', :'f1'),
  '42501', null, 'a member cannot edit someone else');
select lives_ok(format($$ select public.upsert_person(%L, %L, 'Hasan bin Ahmad', 'male', '1980-05-05') $$, :'hasan', :'f1'),
  'a member edits their own record');
select throws_ok(format($$ select public.upsert_person(%L, %L, 'Hasan', 'male', '1980-05-05', null, null, true) $$, gen_random_uuid(), :'f1'),
  '22023', 'already_linked', 'a member has only one own record');
select throws_ok(format($$ select public.delete_person(%L) $$, :'lina'), '42501', null, 'members cannot delete people');
select throws_ok(format($$ select public.delete_relation(id) from public.family_relations where person_b = %L limit 1 $$, :'faris'),
  '42501', null, 'members cannot delete confirmed relations');

select (public.propose_relation(gen_random_uuid(), :'f1', 'spouse', :'hasan', :'mira')).id as prop \gset
select is((select status from public.family_relations where id = :'prop'), 'pending', 'member proposal waits for an admin');
select tests.authenticate_as(:'ua');
select is(public.relationship_between(:'f1', :'mira') ->> 'kind', 'none', 'pending relations are not used');
select tests.clear_authentication();
select is((select count(*)::int from public.notifications where user_id = :'ua' and dedupe_key = 'tree-proposal:' || :'prop'), 1,
  'admins are notified of the proposal');
select tests.authenticate_as(:'ub');
select throws_ok(format($$ select public.review_relation(%L, true) $$, :'prop'), '42501', null, 'a member cannot confirm');
select tests.authenticate_as(:'ua');
select is((public.review_relation(:'prop', true)).status, 'confirmed', 'owner confirms');
select is(public.relationship_between(:'f1', :'mira') ->> 'ms', 'kakak ipar', 'Mira (older, Hasan''s wife) is kakak ipar');

-- Outsider
select tests.authenticate_as(:'ue');
select is((select count(*)::int from public.family_persons where family_id = :'f1'), 0, 'outsiders see no people');
select is((select count(*)::int from public.family_relations where family_id = :'f1'), 0, 'outsiders see no relations');
select throws_ok(format($$ select public.relationship_between(%L, %L) $$, :'f1', :'saya'), '42501', null,
  'outsiders cannot compute relationships');
select throws_ok(format($$ select public.propose_relation(%L, %L, 'spouse', %L, %L) $$, gen_random_uuid(), :'f2', :'lina', :'rizal'),
  '22023', null, 'people of another family cannot be linked');

-- ---------------------------------------------------------------------------
-- Birthdays
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
delete from public.notifications;
select is(private.dispatch_birthdays('2026-05-05'), 2, 'Hasan''s birthday: Amir is told, Hasan is greeted');
select is((select body from public.notifications where user_id = :'ua'), 'Hasan bin Ahmad berumur 46 tahun hari ini',
  'family message with age');
select is((select title from public.notifications where user_id = :'ub'), 'Selamat hari jadi! 🎉', 'the person is greeted');
select is(private.dispatch_birthdays('2026-05-05'), 0, 'a second run the same day sends nothing (dedupe)');
select is(private.dispatch_birthdays('2027-01-01'), 2, 'Rizal (alive) is celebrated; Tok (deceased, same day) is not');
delete from public.notifications;
select is(private.dispatch_birthdays('2027-03-03'), 2, 'Ibu''s birthday reaches both members');
select is(private.dispatch_birthdays('2027-02-28'), 2, '29 February birthdays are celebrated on 28 February in common years');
delete from public.notifications;
select is(private.dispatch_birthdays('2028-02-28'), 0, '... but not in leap years');
select is(private.dispatch_birthdays('2028-02-29'), 2, 'leap year: on the day itself');

-- ---------------------------------------------------------------------------
-- Removal
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'ua');
select lives_ok(format($$ select public.delete_person(%L) $$, :'lina'), 'owner removes a person');
select is((select count(*)::int from public.family_relations where (person_a = :'lina' or person_b = :'lina') and deleted_at is null), 0,
  'their relations are removed too');
select throws_ok(format($$ select public.relationship_between(%L, %L) $$, :'f1', :'lina'), 'P0002', null, 'removed person is not found');

select * from finish();
rollback;
