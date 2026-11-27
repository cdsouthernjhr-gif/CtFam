-- FamilySync — To-Do photos: storage policies, RPCs, limits, privacy.
begin;
select no_plan();

select tests.create_user('ta@test.local', 'Owner') as ua \gset
select tests.create_user('tb@test.local', 'Ali') as ub \gset
select tests.create_user('tc@test.local', 'Chong') as uc \gset
select tests.create_user('te@test.local', 'Luar') as ue \gset
select tests.authenticate_as(:'ua');
select public.create_family('Keluarga Todo') as f1 \gset
select code as inv from public.create_invitation(:'f1', 5, 24) \gset
select tests.authenticate_as(:'ub'); select public.redeem_invitation(:'inv');
select tests.authenticate_as(:'uc'); select public.redeem_invitation(:'inv');
select tests.authenticate_as(:'ue'); select public.create_family('Lain');

select gen_random_uuid() as l1, gen_random_uuid() as l2, gen_random_uuid() as i1, gen_random_uuid() as i2 \gset
select tests.authenticate_as(:'ub');
select public.create_todo_list(:'l1', :'f1', 'Rumah', 'household');
select public.create_todo_list(:'l2', :'f1', 'Rahsia', 'personal', null, 'members', array[]::uuid[]);
select public.upsert_todo_item(:'i1', :'l1', 'Cat dinding');
select public.upsert_todo_item(:'i2', :'l2', 'Hadiah');

-- Storage: item photos for anyone working on the list; cover for the list manager
select tests.authenticate_as(:'uc');
select lives_ok(format($$ insert into storage.objects (bucket_id, name) values ('todo-photos', '%s/%s/%s/b1.jpg') $$, :'f1', :'l1', :'i1'),
  'a member uploads a photo for an item of a family list');
select throws_ok(format($$ insert into storage.objects (bucket_id, name) values ('todo-photos', '%s/%s/cover/c.jpg') $$, :'f1', :'l1'),
  '42501', null, 'only the list creator or an admin sets the cover');
select throws_ok(format($$ insert into storage.objects (bucket_id, name) values ('todo-photos', '%s/%s/%s/x.jpg') $$, :'f1', :'l2', :'i2'),
  '42501', null, 'no uploads to a private list you are not in');
select throws_ok(format($$ insert into storage.objects (bucket_id, name) values ('todo-photos', '%s/%s/%s/x.jpg') $$, :'f1', :'l1', :'i2'),
  '42501', null, 'the item must belong to the list in the path');
select throws_ok(format($$ insert into storage.objects (bucket_id, name) values ('todo-photos', '%s/%s/%s/a/x.jpg') $$, :'f1', :'l1', :'i1'),
  '42501', null, 'nested paths are refused');

-- Recording photos
select gen_random_uuid() as p1 \gset
select lives_ok(format($$ select public.add_todo_item_photo(%L, %L, 'before', '%s/%s/%s/b1.jpg') $$, :'p1', :'i1', :'f1', :'l1', :'i1'),
  'records a before photo');
select lives_ok(format($$ select public.add_todo_item_photo(%L, %L, 'before', '%s/%s/%s/b1.jpg') $$, :'p1', :'i1', :'f1', :'l1', :'i1'),
  'adding is idempotent for the same id');
select is((select count(*)::int from public.todo_item_photos where item_id = :'i1'), 1, 'one row after the replay');
select throws_ok(format($$ select public.add_todo_item_photo(%L, %L, 'after', '%s/%s/%s/missing.jpg') $$, gen_random_uuid(), :'i1', :'f1', :'l1', :'i1'),
  '22023', null, 'the file must exist');
select throws_ok(format($$ select public.add_todo_item_photo(%L, %L, 'during', '%s/%s/%s/b1.jpg') $$, gen_random_uuid(), :'i1', :'f1', :'l1', :'i1'),
  '22023', null, 'kind is before or after');
select throws_ok(format($$ insert into public.todo_item_photos (id, item_id, list_id, family_id, kind, path) values (gen_random_uuid(), %L, %L, %L, 'after', 'x') $$, :'i1', :'l1', :'f1'),
  '42501', null, 'rows only through the RPC');

-- Up to 4 per kind
insert into storage.objects (bucket_id, name)
select 'todo-photos', :'f1' || '/' || :'l1' || '/' || :'i1' || '/b' || n || '.jpg' from generate_series(2, 4) n;
select public.add_todo_item_photo(gen_random_uuid(), :'i1', 'before', :'f1' || '/' || :'l1' || '/' || :'i1' || '/b' || n || '.jpg')
from generate_series(2, 4) n;
select is((select count(*)::int from public.todo_item_photos where item_id = :'i1' and kind = 'before'), 4, 'four before photos');
insert into storage.objects (bucket_id, name) values ('todo-photos', :'f1' || '/' || :'l1' || '/' || :'i1' || '/b5.jpg');
select throws_ok(format($$ select public.add_todo_item_photo(%L, %L, 'before', '%s/%s/%s/b5.jpg') $$, gen_random_uuid(), :'i1', :'f1', :'l1', :'i1'),
  'P0001', 'photo_limit', 'a fifth before photo is refused');
select lives_ok(format($$ select public.add_todo_item_photo(%L, %L, 'after', '%s/%s/%s/b5.jpg') $$, gen_random_uuid(), :'i1', :'f1', :'l1', :'i1'),
  'after photos have their own limit');
select ok(exists (select 1 from public.todo_activity_logs where item_id = :'i1' and action = 'item.photo_added'), 'logged');

-- Privacy
select tests.authenticate_as(:'ue');
select is((select count(*)::int from storage.objects where bucket_id = 'todo-photos'), 0, 'outsiders see no files');
select is((select count(*)::int from public.todo_item_photos), 0, 'outsiders see no rows');
select throws_ok(format($$ select public.delete_todo_item_photo(%L) $$, :'p1'), '42501', null, 'outsiders cannot delete');

select tests.authenticate_as(:'ub');
insert into storage.objects (bucket_id, name) values ('todo-photos', :'f1' || '/' || :'l2' || '/' || :'i2' || '/s.jpg');
select lives_ok(format($$ select public.add_todo_item_photo(%L, %L, 'before', '%s/%s/%s/s.jpg') $$, gen_random_uuid(), :'i2', :'f1', :'l2', :'i2'),
  'photo on a private list');
select tests.authenticate_as(:'uc');
select is((select count(*)::int from public.todo_item_photos where list_id = :'l2'), 0, 'private list photos stay private (rows)');
select is((select count(*)::int from storage.objects where bucket_id = 'todo-photos' and name like '%/s.jpg'), 0,
  'private list photos stay private (files)');
select is((select count(*)::int from public.todo_item_photos where list_id = :'l1'), 5, 'family list photos are visible');

-- Deleting
select is(public.delete_todo_item_photo(:'p1'), :'f1' || '/' || :'l1' || '/' || :'i1' || '/b1.jpg', 'returns the file path');
with d as (delete from storage.objects where bucket_id = 'todo-photos' and name like '%/b1.jpg' returning 1) select count(*) as deleted from d \gset
select is(:deleted::int, 1, 'and the file can be deleted');
select is(public.delete_todo_item_photo(:'p1'), null, 'deleting twice is harmless');

-- Cover
select throws_ok(format($$ select public.set_todo_list_cover(%L, null) $$, :'l1'), '42501', null, 'members cannot change the cover');
select tests.authenticate_as(:'ub');
insert into storage.objects (bucket_id, name) values ('todo-photos', :'f1' || '/' || :'l1' || '/cover/c.jpg');
select is(public.set_todo_list_cover(:'l1', :'f1' || '/' || :'l1' || '/cover/c.jpg'), null, 'creator sets the cover');
select is((select cover_path from public.todo_list_summaries(:'f1') where id = :'l1'), :'f1' || '/' || :'l1' || '/cover/c.jpg',
  'summaries include the cover');
select throws_ok(format($$ select public.set_todo_list_cover(%L, '%s/%s/%s/b2.jpg') $$, :'l1', :'f1', :'l1', :'i1'),
  '22023', null, 'the cover must be in the cover folder');
select tests.authenticate_as(:'ua');
insert into storage.objects (bucket_id, name) values ('todo-photos', :'f1' || '/' || :'l1' || '/cover/d.jpg');
select is(public.set_todo_list_cover(:'l1', :'f1' || '/' || :'l1' || '/cover/d.jpg'), :'f1' || '/' || :'l1' || '/cover/c.jpg',
  'an admin replaces it; the old path is returned for cleanup');
select is(public.set_todo_list_cover(:'l1', null), :'f1' || '/' || :'l1' || '/cover/d.jpg', 'and can remove it');

select * from finish();
rollback;
