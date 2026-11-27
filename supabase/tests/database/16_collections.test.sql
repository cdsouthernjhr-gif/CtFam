-- FamilySync — money collections: modes, treasurer confirmation, expenses,
-- visibility (family and clan-shared), receipts, notifications.
begin;
select no_plan();

select tests.create_user('ka@test.local', 'Owner') as ua \gset
select tests.create_user('kb@test.local', 'Ali') as ub \gset
select tests.create_user('kc@test.local', 'Chong') as uc \gset
select tests.create_user('kf@test.local', 'Fatimah') as uf \gset
select tests.create_user('ke@test.local', 'Luar') as ue \gset
select tests.authenticate_as(:'ua');
select public.create_family('Keluarga Besar') as f1 \gset
select code as inv from public.create_invitation(:'f1', 5, 24) \gset
select tests.authenticate_as(:'ub'); select public.redeem_invitation(:'inv');
select tests.authenticate_as(:'uc'); select public.redeem_invitation(:'inv');
-- Ali's own family, linked under the big family; Fatimah is only there.
select tests.authenticate_as(:'ub');
select public.create_family('Keluarga Ali') as f3 \gset
select code as inv3 from public.create_invitation(:'f3', 5, 24) \gset
select (public.request_family_link(:'f1', :'f3')).id as link \gset
select tests.authenticate_as(:'ua'); select public.respond_family_link(:'link', true);
select tests.authenticate_as(:'uf'); select public.redeem_invitation(:'inv3');
select tests.authenticate_as(:'ue'); select public.create_family('Lain');
select tests.clear_authentication();
delete from public.notifications;

select gen_random_uuid() as k1, gen_random_uuid() as k2, gen_random_uuid() as k3 \gset

-- ---------------------------------------------------------------- creating
select tests.authenticate_as(:'uc');
select throws_ok(format($$ select public.upsert_collection(%L, %L, 'X', 'Y', 'lump') $$, gen_random_uuid(), :'f1'),
  '22023', null, 'lump needs a target');
select throws_ok(format($$ select public.upsert_collection(%L, %L, 'X', 'Y', 'per_member', null, null, false, null, '[]') $$,
  gen_random_uuid(), :'f1'), '22023', null, 'per_member needs targets');
select lives_ok(format($$ select public.upsert_collection(%L, %L, 'Kenduri', 'Kenduri tahlil arwah Atok', 'lump', 3000) $$, :'k1', :'f1'),
  'any member creates a lump-sum collection');
select lives_ok(format($$ select public.upsert_collection(%L, %L, 'Kenduri', 'Kenduri tahlil arwah Atok', 'lump', 3000) $$, :'k1', :'f1'),
  'creating is idempotent');
select ok(private.is_collection_treasurer(:'k1'), 'the creator is a treasurer');
select tests.clear_authentication();
select is((select count(*)::int from public.notifications where dedupe_key = 'collection:new:' || :'k1'), 2,
  'the family (not the creator, not the clan) is told: owner + Ali');

select tests.authenticate_as(:'ub');
select throws_ok(format($$ select public.upsert_collection(%L, %L, 'Kenduri!', 'x', 'lump', 10) $$, :'k1', :'f1'),
  '42501', null, 'a plain member cannot edit someone else''s collection');
select tests.authenticate_as(:'ua');
select lives_ok(format($$ select public.upsert_collection(%L, %L, 'Kenduri', 'Kenduri tahlil arwah Atok', 'lump', 3500) $$, :'k1', :'f1'),
  'the family owner can edit (treasurer by role)');

select lives_ok(format($$ select public.upsert_collection(%L, %L, 'Hadiah Mak', 'Hadiah hari jadi Mak', 'per_member', null, null, true, array[%L]::uuid[],
  jsonb_build_array(jsonb_build_object('user_id', %L, 'amount', 500), jsonb_build_object('user_id', %L, 'amount', 300), jsonb_build_object('user_id', %L, 'amount', 200))) $$,
  :'k2', :'f1', :'ub', :'ub', :'uc', :'uf'), 'per-member targets, shared with the clan (Fatimah gets a target)');
select is((select sum(amount)::int from public.collection_targets where collection_id = :'k2'), 1000, 'targets stored');
select throws_ok(format($$ select public.upsert_collection(%L, %L, 'X', 'Y', 'per_member', null, null, false, null,
  jsonb_build_array(jsonb_build_object('user_id', %L, 'amount', 5))) $$, :'k3', :'f1', :'ue'),
  '22023', null, 'outsiders cannot be given a target');
select lives_ok(format($$ select public.upsert_collection(%L, %L, 'Tabung', 'Tabung kecemasan', 'open') $$, :'k3', :'f1'),
  'open collection without a target');

-- ---------------------------------------------------------------- visibility
select tests.authenticate_as(:'uf');
select is((select count(*)::int from public.collections), 1, 'clan member sees only the clan-shared collection');
select is((select count(*)::int from public.collection_summaries(:'f3')), 1, 'and it is in her family''s overview');
select tests.authenticate_as(:'ue');
select is((select count(*)::int from public.collections), 0, 'outsiders see nothing');
select throws_ok(format($$ select public.record_collection_payment(%L, %L, 10) $$, gen_random_uuid(), :'k1'), '42501', null,
  'outsiders cannot pay');

-- ---------------------------------------------------------------- payments
select gen_random_uuid() as p1, gen_random_uuid() as p2, gen_random_uuid() as p3, gen_random_uuid() as p4 \gset
select tests.authenticate_as(:'ub');
select is((public.record_collection_payment(:'p1', :'k1', 1000, '2026-11-01', 'Bank in')).status, 'pending',
  'a member''s own payment is pending');
select is((public.record_collection_payment(:'p1', :'k1', 1000, '2026-11-01', 'Bank in')).status, 'pending', 'replay is harmless');
select is((select count(*)::int from public.collection_payments where id = :'p1'), 1, 'one row');
select throws_ok(format($$ select public.record_collection_payment(%L, %L, 50, null, null, null, %L) $$, gen_random_uuid(), :'k1', :'uc'),
  '42501', null, 'members cannot record for others');
select throws_ok(format($$ select public.review_collection_payment(%L, true) $$, :'p1'), '42501', null,
  'members cannot confirm');
select tests.clear_authentication();
select is((select count(*)::int from public.notifications where dedupe_key = 'collection:pending:' || :'p1'), 2,
  'treasurers (creator Chong + owner) are asked to confirm');

select tests.authenticate_as(:'uc');
select is((select confirmed_total::int from public.collection_summaries(:'f1') where id = :'k1'), 0, 'pending does not count');
select is((select pending_total::int from public.collection_summaries(:'f1') where id = :'k1'), 1000, 'but is shown as pending');
select is((public.review_collection_payment(:'p1', true)).status, 'confirmed', 'treasurer confirms');
select is((select confirmed_total::int from public.collection_summaries(:'f1') where id = :'k1'), 1000, 'confirmed counts');
select tests.clear_authentication();
select is((select count(*)::int from public.notifications where user_id = :'ub' and dedupe_key = 'collection:review:' || :'p1'), 1,
  'the payer is told');

select tests.authenticate_as(:'uc');
select is((public.record_collection_payment(:'p2', :'k1', 2600, null, 'Tunai', null, :'ua')).status, 'confirmed',
  'a treasurer records for someone: confirmed at once');
select is((select confirmed_total::int from public.collection_summaries(:'f1') where id = :'k1'), 3600,
  'over the target is allowed (shown as above target)');

-- per member, clan member pays
select tests.authenticate_as(:'uf');
select lives_ok(format($$ select public.record_collection_payment(%L, %L, 100) $$, :'p3', :'k2'), 'clan member pays in instalments');
select tests.authenticate_as(:'ub');
select is((public.review_collection_payment(:'p3', false, 'Resit tidak jelas')).status, 'rejected', 'treasurer rejects');
select throws_ok(format($$ select public.review_collection_payment(%L, true) $$, :'p3'), 'P0001', 'already_reviewed',
  'a reviewed payment cannot be flipped');
select tests.authenticate_as(:'uf');
select is((select my_paid::int from public.collection_summaries(:'f3') where id = :'k2'), 0, 'rejected does not count');
select is((select my_target::int from public.collection_summaries(:'f3') where id = :'k2'), 200, 'her own target');
select throws_ok(format($$ select public.delete_collection_payment(%L) $$, :'p3'), '42501', null,
  'a reviewed payment can only be removed by a treasurer');
select lives_ok(format($$ select public.record_collection_payment(%L, %L, 200) $$, :'p4', :'k2'), 'pays again');
select lives_ok(format($$ select public.delete_collection_payment(%L) $$, :'p4'), 'and can withdraw it while pending');

-- reminders
select tests.authenticate_as(:'ub');
select is(public.remind_collection(:'k2'), 2, 'per-member reminder goes to Chong and Fatimah (Ali is the sender)');
select is(public.remind_collection(:'k2'), 0, 'at most once a day');

-- ---------------------------------------------------------------- expenses & balance
select gen_random_uuid() as e1 \gset
select tests.authenticate_as(:'ub');
select throws_ok(format($$ select public.record_collection_expense(%L, %L, 800, 'Beras') $$, :'e1', :'k1'), '42501', null,
  'only treasurers record expenses');
select tests.authenticate_as(:'uc');
select lives_ok(format($$ select public.record_collection_expense(%L, %L, 800, 'Beras dan lauk') $$, :'e1', :'k1'), 'treasurer records an expense');
select is((select (confirmed_total - expense_total)::int from public.collection_summaries(:'f1') where id = :'k1'), 2800, 'balance');

-- ---------------------------------------------------------------- closing
select lives_ok(format($$ select public.set_collection_status(%L, true) $$, :'k1'), 'treasurer closes');
select tests.authenticate_as(:'ub');
select throws_ok(format($$ select public.record_collection_payment(%L, %L, 10) $$, gen_random_uuid(), :'k1'),
  'P0001', 'collection_closed', 'no payments after closing');

-- ---------------------------------------------------------------- receipts
select tests.authenticate_as(:'uf');
select lives_ok(format($$ insert into storage.objects (bucket_id, name) values ('collection-receipts', '%s/%s/r.jpg') $$, :'f1', :'k2'),
  'clan member uploads a receipt for a shared collection');
select throws_ok(format($$ insert into storage.objects (bucket_id, name) values ('collection-receipts', '%s/%s/r.jpg') $$, :'f1', :'k1'),
  '42501', null, 'but not for a collection she cannot see');
select lives_ok(format($$ select public.record_collection_payment(%L, %L, 200, null, null, '%s/%s/r.jpg') $$, gen_random_uuid(), :'k2', :'f1', :'k2'),
  'payment with receipt');
select throws_ok(format($$ select public.record_collection_payment(%L, %L, 200, null, null, '%s/%s/none.jpg') $$, gen_random_uuid(), :'k2', :'f1', :'k2'),
  '22023', null, 'the receipt must exist');
select tests.authenticate_as(:'ue');
select is((select count(*)::int from storage.objects where bucket_id = 'collection-receipts'), 0, 'outsiders see no receipts');

-- ---------------------------------------------------------------- writes only via RPC
select tests.authenticate_as(:'ua');
select throws_ok(format($$ update public.collection_payments set amount = 1 where collection_id = %L $$, :'k1'), '42501', null,
  'no direct updates');
select throws_ok(format($$ insert into public.collection_targets (collection_id, user_id, amount) values (%L, %L, 1) $$, :'k2', :'ua'),
  '42501', null, 'no direct inserts');

-- ---------------------------------------------------------------- deleting
select tests.authenticate_as(:'ub');
select throws_ok(format($$ select public.delete_collection(%L) $$, :'k3'), '42501', null, 'members cannot delete');
select tests.authenticate_as(:'uc');
select throws_ok(format($$ select public.delete_collection(%L) $$, :'k3'), '42501', null,
  'being treasurer of another collection gives no rights here');
select tests.authenticate_as(:'ua');
select lives_ok(format($$ select public.delete_collection(%L) $$, :'k3'), 'its creator (the owner) deletes');
select lives_ok(format($$ select public.delete_collection(%L) $$, :'k3'), 'deleting twice is harmless');
select is((select count(*)::int from public.collection_summaries(:'f1') where id = :'k3'), 0, 'deleted collections disappear');

select * from finish();
rollback;
