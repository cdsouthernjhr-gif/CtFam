-- FamilySync — Shared To-Do: RLS, RPC rules, idempotency, revisions, recurrence.
begin;
select no_plan();

-- Fixtures: family F1 (owner A, member B, member C), family F2 (owner E), outsider D
select tests.create_user('ta@test.local', 'Aminah') as ua \gset
select tests.create_user('tb@test.local', 'Badrul') as ub \gset
select tests.create_user('tc@test.local', 'Chong') as uc \gset
select tests.create_user('td@test.local', 'Devi') as ud \gset
select tests.create_user('te@test.local', 'Ehsan') as ue \gset

select tests.authenticate_as(:'ua');
select public.create_family('Keluarga Todo') as f1 \gset
select code as inv from public.create_invitation(:'f1', 5, 24) \gset
select tests.authenticate_as(:'ub');
select public.redeem_invitation(:'inv');
select tests.authenticate_as(:'uc');
select public.redeem_invitation(:'inv');
select tests.authenticate_as(:'ue');
select public.create_family('Keluarga Lain') as f2 \gset

select gen_random_uuid() as list1, gen_random_uuid() as list_priv, gen_random_uuid() as item1,
       gen_random_uuid() as item_rec, gen_random_uuid() as list_f2, gen_random_uuid() as c1 \gset

-- ---------------------------------------------------------------------------
-- Lists
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'ua');
select lives_ok(format($$ select public.create_todo_list(%L, %L, 'Barang dapur', 'grocery') $$, :'list1', :'f1'),
  'member creates a family-visible list');
select lives_ok(format($$ select public.create_todo_list(%L, %L, 'Barang dapur', 'grocery') $$, :'list1', :'f1'),
  'create_todo_list is idempotent for the same id');
select is((select count(*)::int from public.todo_lists where id = :'list1'), 1, 'replayed create did not duplicate');
select lives_ok(format($$ select public.create_todo_list(%L, %L, 'Hadiah rahsia', 'personal', null, 'members', array[%L]::uuid[]) $$,
  :'list_priv', :'f1', :'ub'), 'owner creates a members-only list shared with B');

select tests.authenticate_as(:'ue');
select throws_ok(format($$ select public.create_todo_list(%L, %L, 'Hack', 'personal') $$, gen_random_uuid(), :'f1'),
  '42501', null, 'outsider cannot create a list in another family');
select lives_ok(format($$ select public.create_todo_list(%L, %L, 'Senarai F2') $$, :'list_f2', :'f2'), 'E creates list in own family');
select is((select count(*)::int from public.todo_lists where family_id = :'f1'), 0, 'cross-family: E sees no F1 lists');

select tests.authenticate_as(:'uc');
select is((select count(*)::int from public.todo_lists where id = :'list1'), 1, 'C sees family-visible list');
select is((select count(*)::int from public.todo_lists where id = :'list_priv'), 0, 'C cannot see members-only list');
select is((select count(*)::int from public.todo_lists where id = :'list_f2'), 0, 'C cannot see other family list');
select throws_ok(format($$ select public.update_todo_list(%L, 'Renamed', null, 'grocery') $$, :'list1'),
  '42501', null, 'non-creator member cannot rename list');
select throws_ok(format($$ select public.delete_todo_list(%L) $$, :'list1'), '42501', null, 'non-creator member cannot delete list');
select throws_ok(format($$ insert into public.todo_lists (id, family_id, name) values (%L, %L, 'direct') $$, gen_random_uuid(), :'f1'),
  '42501', null, 'direct insert into todo_lists is denied');

select tests.authenticate_as(:'ub');
select is((select count(*)::int from public.todo_lists where id = :'list_priv'), 1, 'B (list member) sees members-only list');

-- ---------------------------------------------------------------------------
-- Items: idempotent create, revision conflict, permissions
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'ub');
select lives_ok(format($$ select public.upsert_todo_item(%L, %L, 'Beli susu', null, 'high', null, 'none', array[%L]::uuid[]) $$,
  :'item1', :'list1', :'uc'), 'B adds item assigned to C');
select lives_ok(format($$ select public.upsert_todo_item(%L, %L, 'Beli susu', null, 'high', null, 'none', array[%L]::uuid[]) $$,
  :'item1', :'list1', :'uc'), 'replaying the same create is safe');
select is((select revision from public.todo_items where id = :'item1'), 1, 'replay did not bump revision');
select is((select count(*)::int from public.todo_assignments where item_id = :'item1'), 1, 'assignment stored once');

select throws_ok(format($$ select public.upsert_todo_item(%L, %L, 'X', null, 'normal', null, 'none', array[%L]::uuid[]) $$,
  gen_random_uuid(), :'list1', :'ue'), 'P0002', null, 'cannot assign someone outside the family');
select throws_ok(format($$ insert into public.todo_items (id, list_id, family_id, title) values (%L, %L, %L, 'x') $$,
  gen_random_uuid(), :'list1', :'f1'), '42501', null, 'direct insert into todo_items is denied');
select throws_ok(format($$ update public.todo_items set title = 'hacked' where id = %L $$, :'item1'),
  '42501', null, 'direct update of todo_items is denied');

-- Edit with correct revision succeeds and bumps revision
select tests.authenticate_as(:'uc');
select is((public.upsert_todo_item(:'item1', :'list1', 'Beli susu 2 liter', null, 'high', null, 'none', null, 1)).revision, 2,
  'edit with matching revision succeeds and increments revision');
select is((select count(*)::int from public.todo_assignments where item_id = :'item1'), 1, 'null assignees leaves them unchanged');
-- Stale edit (another device still on revision 1)
select tests.authenticate_as(:'ub');
select throws_ok(format($$ select public.upsert_todo_item(%L, %L, 'Beli roti', null, 'high', null, 'none', null, 1) $$, :'item1', :'list1'),
  'P0409', null, 'stale edit is rejected with revision_conflict');
select is((select title from public.todo_items where id = :'item1'), 'Beli susu 2 liter', 'stale edit did not overwrite');

-- Idempotent status changes
select is((public.set_todo_item_status(:'item1', true)).status::text, 'completed', 'B completes item');
select is((select revision from public.todo_items where id = :'item1'), 3, 'completion bumps revision');
select is((public.set_todo_item_status(:'item1', true)).revision, 3, 'completing again is a no-op (no blind toggle)');
select is((select completed_by from public.todo_items where id = :'item1'), :'ub'::uuid, 'completed_by recorded');
select tests.authenticate_as(:'uc');
select is((public.set_todo_item_status(:'item1', false)).status::text, 'open', 'C reopens item');
select is((select completed_at from public.todo_items where id = :'item1'), null, 'reopen clears completed_at');

-- Outsider and cross-family access
select tests.authenticate_as(:'ue');
select throws_ok(format($$ select public.set_todo_item_status(%L, true) $$, :'item1'), '42501', null,
  'other family cannot complete F1 item');
select throws_ok(format($$ select public.upsert_todo_item(%L, %L, 'x', null, 'normal', null, 'none', null, null) $$, :'item1', :'list1'),
  '42501', null, 'other family cannot edit F1 item');
select is((select count(*)::int from public.todo_items where family_id = :'f1'), 0, 'other family sees no F1 items');
select tests.authenticate_as(:'ud');
select is((select count(*)::int from public.todo_items), 0, 'outsider sees no items at all');

-- Members-only list items are hidden from non-members
select tests.authenticate_as(:'ua');
select public.upsert_todo_item(gen_random_uuid(), :'list_priv', 'Kek hari jadi C');
select tests.authenticate_as(:'uc');
select is((select count(*)::int from public.todo_items where list_id = :'list_priv'), 0, 'C cannot see items of members-only list');
select throws_ok(format($$ select public.upsert_todo_item(%L, %L, 'peek') $$, gen_random_uuid(), :'list_priv'),
  '42501', null, 'C cannot add items to members-only list');

-- Delete rules: C (not creator, not list manager) cannot delete B's item
select throws_ok(format($$ select public.delete_todo_item(%L) $$, :'item1'), '42501', null, 'non-creator member cannot delete item');
select tests.authenticate_as(:'ub');
select lives_ok(format($$ select public.delete_todo_item(%L) $$, :'item1'), 'item creator deletes item');
select lives_ok(format($$ select public.delete_todo_item(%L) $$, :'item1'), 'delete is idempotent');
select is((select count(*)::int from public.todo_items where id = :'item1' and deleted_at is null), 0, 'deleted item is marked deleted');
select is((select count(*)::int from public.todo_items where id = :'item1'), 1,
  'soft-deleted row stays readable to members so Realtime can deliver the deletion');
select throws_ok(format($$ select public.set_todo_item_status(%L, true) $$, :'item1'), '42501', null, 'deleted item cannot be changed');

-- ---------------------------------------------------------------------------
-- Recurrence
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'ua');
select public.upsert_todo_item(:'item_rec', :'list1', 'Buang sampah', null, 'normal',
  '2026-12-01 09:00+08', 'weekly', array[:'ub']::uuid[]);
select public.set_todo_item_status(:'item_rec', true);
select is((select count(*)::int from public.todo_items where recurrence_source_id = :'item_rec'), 1,
  'completing a weekly item creates the next occurrence');
select is((select due_at from public.todo_items where recurrence_source_id = :'item_rec'), '2026-12-08 09:00+08'::timestamptz,
  'next occurrence is due one week later');
select is((select count(*)::int from public.todo_assignments a join public.todo_items i on i.id = a.item_id
           where i.recurrence_source_id = :'item_rec'), 1, 'assignees carried to next occurrence');
select public.set_todo_item_status(:'item_rec', false);
select public.set_todo_item_status(:'item_rec', true);
select is((select count(*)::int from public.todo_items where recurrence_source_id = :'item_rec'), 1,
  'reopen + complete again does not duplicate the next occurrence');

-- ---------------------------------------------------------------------------
-- Comments
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'uc');
select lives_ok(format($$ insert into public.todo_comments (id, item_id, list_id, family_id, author_id, body)
  values (%L, %L, %L, %L, auth.uid(), 'Saya boleh buat') $$, :'c1', :'item_rec', :'list1', :'f1'), 'member comments as self');
select throws_ok(format($$ insert into public.todo_comments (id, item_id, list_id, family_id, author_id, body)
  values (%L, %L, %L, %L, %L, 'menyamar') $$, gen_random_uuid(), :'item_rec', :'list1', :'f1', :'ua'),
  '42501', null, 'cannot comment as someone else');
select tests.authenticate_as(:'ub');
update public.todo_comments set body = 'diubah' where id = :'c1';
select is((select body from public.todo_comments where id = :'c1'), 'Saya boleh buat', 'cannot edit another member''s comment');
select tests.authenticate_as(:'ue');
select throws_ok(format($$ insert into public.todo_comments (id, item_id, list_id, family_id, author_id, body)
  values (%L, %L, %L, %L, auth.uid(), 'x') $$, gen_random_uuid(), :'item_rec', :'list1', :'f1'),
  '42501', null, 'other family cannot comment');

-- ---------------------------------------------------------------------------
-- Summaries and activity
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'uc');
select is((select total_items from public.todo_list_summaries(:'f1') where id = :'list1'), 2,
  'summary counts visible items (completed recurring + next occurrence)');
select is((select completed_items from public.todo_list_summaries(:'f1') where id = :'list1'), 1, 'summary counts completed');
select is((select count(*)::int from public.todo_list_summaries(:'f1') where id = :'list_priv'), 0,
  'summary respects members-only lists');
select ok((select count(*) from public.todo_activity_logs where list_id = :'list1') >= 6, 'activity log records item events');
select tests.authenticate_as(:'ue');
select is((select count(*)::int from public.todo_list_summaries(:'f1')), 0, 'other family gets empty summary');
select is((select count(*)::int from public.todo_activity_logs where family_id = :'f1'), 0, 'other family cannot read activity');

-- Suspended member loses access immediately
select tests.authenticate_as(:'ua');
select public.set_member_status(:'f1', :'uc', 'suspended');
select tests.authenticate_as(:'uc');
select is((select count(*)::int from public.todo_items), 0, 'suspended member sees no items');
select throws_ok(format($$ select public.set_todo_item_status(%L, false) $$, :'item_rec'), '42501', null,
  'suspended member cannot change items');

-- List owner deletes list
select tests.authenticate_as(:'ua');
select lives_ok(format($$ select public.delete_todo_list(%L) $$, :'list1'), 'list creator deletes list');
select tests.authenticate_as(:'ub');
select is((select count(*)::int from public.todo_list_summaries(:'f1') where id = :'list1'), 0, 'deleted list disappears from summaries');
select throws_ok(format($$ select public.upsert_todo_item(%L, %L, 'late') $$, gen_random_uuid(), :'list1'),
  '42501', null, 'no new items in a deleted list');

select tests.clear_authentication();
select is((select count(*)::int from pg_tables where schemaname = 'public' and not rowsecurity), 0, 'RLS still enabled on every table');

select * from finish();
rollback;
