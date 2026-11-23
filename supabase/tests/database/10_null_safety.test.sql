-- FamilySync — regression: permission checks stay closed when the owner
-- column is NULL (creator/sender deleted their account).
begin;
select no_plan();

select tests.create_user('na1@test.local', 'Owner') as ua \gset
select tests.create_user('na2@test.local', 'Member') as ub \gset
select tests.create_user('na3@test.local', 'Leaver') as uc \gset
select tests.authenticate_as(:'ua');
select public.create_family('Keluarga Null') as f1 \gset
select code as inv from public.create_invitation(:'f1', 5, 24) \gset
select tests.authenticate_as(:'ub'); select public.redeem_invitation(:'inv');
select tests.authenticate_as(:'uc'); select public.redeem_invitation(:'inv');

-- C creates a task in a family-wide list and sends a group message
select gen_random_uuid() as l1, gen_random_uuid() as i1, gen_random_uuid() as m1 \gset
select tests.authenticate_as(:'ua');
select public.create_todo_list(:'l1', :'f1', 'Rumah');
select public.create_group_conversation(gen_random_uuid(), :'f1', 'Semua', null, array[:'ub', :'uc']::uuid[]) as g \gset
select tests.authenticate_as(:'uc');
select public.upsert_todo_item(:'i1', :'l1', 'Tugasan C');
select public.send_message(:'m1', :'g', 'Mesej C');

-- C's account is deleted: owner columns become NULL
select tests.clear_authentication();
update public.todo_items set created_by = null, updated_by = null where id = :'i1';
update public.messages set sender_id = null where id = :'m1';

select tests.authenticate_as(:'ub');
select throws_ok(format($$ select public.delete_todo_item(%L) $$, :'i1'), '42501', null,
  'a plain member cannot delete a task whose creator is gone');
select throws_ok(format($$ select public.delete_message(%L) $$, :'m1'), '42501', null,
  'a plain member cannot delete a message whose sender is gone');

select tests.authenticate_as(:'ua');
select lives_ok(format($$ select public.delete_todo_item(%L) $$, :'i1'), 'the list manager (owner) still can');
select lives_ok(format($$ select public.delete_message(%L) $$, :'m1'), 'a moderator (family owner) still can');

select * from finish();
rollback;
