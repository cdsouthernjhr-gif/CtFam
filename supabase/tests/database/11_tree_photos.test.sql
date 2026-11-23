-- FamilySync — family tree photos: storage policies and RPCs.
begin;
select no_plan();

select tests.create_user('pa@test.local', 'Owner') as ua \gset
select tests.create_user('pb@test.local', 'Hasan') as ub \gset
select tests.create_user('pe@test.local', 'Luar') as ue \gset
select tests.authenticate_as(:'ua');
select public.create_family('Keluarga Gambar') as f1 \gset
select code as inv from public.create_invitation(:'f1', 5, 24) \gset
select tests.authenticate_as(:'ub'); select public.redeem_invitation(:'inv');
select tests.authenticate_as(:'ue'); select public.create_family('Lain');

select gen_random_uuid() as hasan, gen_random_uuid() as siti \gset
select tests.authenticate_as(:'ua');
select public.upsert_person(:'hasan', :'f1', 'Hasan', 'male', '1980-05-05');
select public.upsert_person(:'siti', :'f1', 'Siti', 'female', '1982-07-07');
select public.link_person_account(:'hasan', :'ub');

-- Member: own folder only
select tests.authenticate_as(:'ub');
select lives_ok(format($$ insert into storage.objects (bucket_id, name) values ('tree-photos', '%s/%s/a.jpg') $$, :'f1', :'hasan'),
  'a member uploads a photo of their own record');
select throws_ok(format($$ insert into storage.objects (bucket_id, name) values ('tree-photos', '%s/%s/a.jpg') $$, :'f1', :'siti'),
  '42501', null, 'a member cannot upload a photo for someone else');
select throws_ok(format($$ insert into storage.objects (bucket_id, name) values ('tree-photos', '%s/cover/a.jpg') $$, :'f1'),
  '42501', null, 'a member cannot upload the tree cover');
select throws_ok(format($$ insert into storage.objects (bucket_id, name) values ('tree-photos', '%s/%s/x/a.jpg') $$, :'f1', :'hasan'),
  '42501', null, 'nested paths are refused');

select lives_ok(format($$ select public.set_person_photo(%L, '%s/%s/a.jpg') $$, :'hasan', :'f1', :'hasan'),
  'a member sets their own photo');
select is((select photo_path from public.family_persons where id = :'hasan'), :'f1' || '/' || :'hasan' || '/a.jpg', 'path stored');
select throws_ok(format($$ select public.set_person_photo(%L, '%s/%s/a.jpg') $$, :'siti', :'f1', :'hasan'),
  '42501', null, 'a member cannot set someone else''s photo');
select throws_ok(format($$ select public.set_person_photo(%L, '%s/%s/missing.jpg') $$, :'hasan', :'f1', :'hasan'),
  '22023', null, 'the file must exist');
select throws_ok(format($$ select public.set_tree_photo(%L, null) $$, :'f1'), '42501', null, 'members cannot change the cover');

-- Owner: anyone + cover
select tests.authenticate_as(:'ua');
select lives_ok(format($$ insert into storage.objects (bucket_id, name) values ('tree-photos', '%s/%s/s.jpg') $$, :'f1', :'siti'),
  'owner uploads for a person without an account');
select lives_ok(format($$ insert into storage.objects (bucket_id, name) values ('tree-photos', '%s/cover/c.jpg') $$, :'f1'),
  'owner uploads the cover');
select throws_ok(format($$ select public.set_person_photo(%L, '%s/%s/a.jpg') $$, :'siti', :'f1', :'hasan'),
  '22023', null, 'a photo must live in that person''s folder');
select lives_ok(format($$ select public.set_person_photo(%L, '%s/%s/s.jpg') $$, :'siti', :'f1', :'siti'), 'owner sets Siti''s photo');
select is(public.set_tree_photo(:'f1', :'f1' || '/cover/c.jpg'), :'f1' || '/cover/c.jpg', 'owner sets the cover');
select is((select tree_photo_path from public.families where id = :'f1'), :'f1' || '/cover/c.jpg', 'cover stored');
select throws_ok(format($$ update public.families set tree_photo_path = null where id = %L $$, :'f1'), '42501', null,
  'cover only through the RPC');

-- Reading and deleting
select tests.authenticate_as(:'ub');
select is((select count(*)::int from storage.objects where bucket_id = 'tree-photos'), 3, 'members see all family photos');
with d as (delete from storage.objects where bucket_id = 'tree-photos' and name like '%/s.jpg' returning 1) select count(*) as deleted from d \gset
select is(:deleted::int, 0, 'a member cannot delete someone else''s photo');
select lives_ok(format($$ select public.set_person_photo(%L, null) $$, :'hasan'), 'a member removes their own photo');
with d as (delete from storage.objects where bucket_id = 'tree-photos' and name like '%/a.jpg' returning 1) select count(*) as deleted from d \gset
select is(:deleted::int, 1, 'and deletes the file');

select tests.authenticate_as(:'ue');
select is((select count(*)::int from storage.objects where bucket_id = 'tree-photos'), 0, 'outsiders see no photos');

select tests.authenticate_as(:'ua');
with d as (delete from storage.objects where bucket_id = 'tree-photos' returning 1) select count(*) as deleted from d \gset
select is(:deleted::int, 2, 'owner can delete any tree photo');

select * from finish();
rollback;
