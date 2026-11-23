-- FamilySync — Chat: membership isolation, idempotent send, receipts,
-- moderation, attachments, Realtime channel authorisation.
begin;
select no_plan();

-- Family F1: owner A, member B, member C, moderator M. Family F2: owner E. Outsider D.
select tests.create_user('ca@test.local', 'Aminah') as ua \gset
select tests.create_user('cb@test.local', 'Badrul') as ub \gset
select tests.create_user('cc@test.local', 'Chong') as uc \gset
select tests.create_user('cm@test.local', 'Mira') as um \gset
select tests.create_user('cd@test.local', 'Devi') as ud \gset
select tests.create_user('ce@test.local', 'Ehsan') as ue \gset

select tests.authenticate_as(:'ua');
select public.create_family('Keluarga Sembang') as f1 \gset
select code as inv from public.create_invitation(:'f1', 5, 24) \gset
select tests.authenticate_as(:'ub'); select public.redeem_invitation(:'inv');
select tests.authenticate_as(:'uc'); select public.redeem_invitation(:'inv');
select tests.authenticate_as(:'um'); select public.redeem_invitation(:'inv');
select tests.authenticate_as(:'ua'); select public.set_member_role(:'f1', :'um', 'moderator');
select tests.authenticate_as(:'ue'); select public.create_family('Keluarga Lain') as f2 \gset

select gen_random_uuid() as g1, gen_random_uuid() as m1, gen_random_uuid() as m2, gen_random_uuid() as m3,
       gen_random_uuid() as m_img, gen_random_uuid() as m_bad \gset

-- ---------------------------------------------------------------------------
-- Direct conversations: unique per pair, symmetric, family-scoped
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'ua');
select public.get_or_create_direct_conversation(:'f1', :'ub') as dm_ab \gset
select tests.authenticate_as(:'ub');
select is(public.get_or_create_direct_conversation(:'f1', :'ua'), :'dm_ab'::uuid,
  'B opening a chat with A reuses the same direct conversation');
select tests.clear_authentication();
select is((select count(*)::int from public.conversations where kind = 'direct'), 1, 'no duplicate direct conversation');
select tests.authenticate_as(:'ua');
select throws_ok(format($$ select public.get_or_create_direct_conversation(%L, %L) $$, :'f1', :'ua'), '22023', null,
  'cannot open a direct chat with yourself');
select throws_ok(format($$ select public.get_or_create_direct_conversation(%L, %L) $$, :'f1', :'ue'), '42501', null,
  'cannot open a direct chat with someone outside the family');

-- ---------------------------------------------------------------------------
-- Sending: idempotent, membership enforced, no direct writes
-- ---------------------------------------------------------------------------
select lives_ok(format($$ select public.send_message(%L, %L, 'Assalamualaikum') $$, :'m1', :'dm_ab'), 'A sends a message');
select lives_ok(format($$ select public.send_message(%L, %L, 'Assalamualaikum') $$, :'m1', :'dm_ab'),
  'retrying the same message id is safe');
select is((select count(*)::int from public.messages where id = :'m1'), 1, 'retry did not duplicate the message');
select is((select last_message_preview from public.conversations where id = :'dm_ab'), 'Assalamualaikum',
  'conversation preview updated');
select throws_ok(format($$ select public.send_message(%L, %L, '   ') $$, gen_random_uuid(), :'dm_ab'), '22023', null,
  'empty message rejected');
select throws_ok(format($$ insert into public.messages (id, conversation_id, family_id, sender_id, body) values (%L, %L, %L, %L, 'x') $$,
  gen_random_uuid(), :'dm_ab', :'f1', :'ua'), '42501', null, 'direct insert into messages is denied');

select tests.authenticate_as(:'uc');
select is((select count(*)::int from public.messages where conversation_id = :'dm_ab'), 0,
  'family member C cannot read the A–B private chat');
select is((select count(*)::int from public.conversations where id = :'dm_ab'), 0, 'C cannot see the A–B conversation');
select throws_ok(format($$ select public.send_message(%L, %L, 'menyampuk') $$, gen_random_uuid(), :'dm_ab'), '42501', null,
  'C cannot post into the A–B chat');
select throws_ok(format($$ select public.send_message(%L, %L, 'curi id') $$, :'m1', :'dm_ab'), '42501', null,
  'C cannot hijack an existing message id');
select tests.authenticate_as(:'ue');
select is((select count(*)::int from public.messages), 0, 'other family sees no messages');
select tests.authenticate_as(:'ud');
select is((select count(*)::int from public.conversations), 0, 'outsider sees no conversations');

-- Replies must point into the same conversation
select tests.authenticate_as(:'ub');
select lives_ok(format($$ select public.send_message(%L, %L, 'Waalaikumussalam', %L) $$, :'m2', :'dm_ab', :'m1'), 'B replies');
select is((select reply_to_id from public.messages where id = :'m2'), :'m1'::uuid, 'reply_to stored');

-- ---------------------------------------------------------------------------
-- Receipts & unread counts
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'ua');
select is((select unread_count from public.conversation_summaries(:'f1') where id = :'dm_ab'), 1, 'A has 1 unread (B''s reply)');
select is((select other_user_id from public.conversation_summaries(:'f1') where id = :'dm_ab'), :'ub'::uuid,
  'summary exposes the other participant');
select lives_ok(format($$ select public.mark_conversation_read(%L) $$, :'dm_ab'), 'A marks read');
select is((select unread_count from public.conversation_summaries(:'f1') where id = :'dm_ab'), 0, 'unread cleared');
select public.mark_conversation_read(:'dm_ab', now() - interval '1 day');
select ok((select last_read_at from public.message_receipts where conversation_id = :'dm_ab' and user_id = :'ua') > now() - interval '1 minute',
  'read cursor never moves backwards');
select tests.authenticate_as(:'ub');
select ok((select last_read_at from public.message_receipts where conversation_id = :'dm_ab' and user_id = :'ua') is not null,
  'B can see A''s read cursor (read receipts)');

-- ---------------------------------------------------------------------------
-- Edit / delete / pin
-- ---------------------------------------------------------------------------
select throws_ok(format($$ select public.edit_message(%L, 'diubah oleh B') $$, :'m1'), '42501', null, 'cannot edit someone else''s message');
select tests.authenticate_as(:'ua');
select is((public.edit_message(:'m1', 'Assalamualaikum semua')).body, 'Assalamualaikum semua', 'sender edits own message');
select ok((select edited_at is not null from public.messages where id = :'m1'), 'edited_at set');
select lives_ok(format($$ select public.set_message_pinned(%L, true) $$, :'m2'), 'direct chat participant pins a message');
select lives_ok(format($$ select public.delete_message(%L) $$, :'m1'), 'sender deletes own message');
select lives_ok(format($$ select public.delete_message(%L) $$, :'m1'), 'delete is idempotent');
select is((select body from public.messages where id = :'m1'), null, 'deleted message body is cleared');
select ok((select deleted_at is not null from public.messages where id = :'m1'),
  'deleted row stays visible to members (Realtime delivers the deletion)');
select throws_ok(format($$ select public.edit_message(%L, 'hidup semula') $$, :'m1'), '42501', null, 'deleted message cannot be edited');

-- ---------------------------------------------------------------------------
-- Groups: creation, membership, moderation
-- ---------------------------------------------------------------------------
select lives_ok(format($$ select public.create_group_conversation(%L, %L, 'Sepupu', null, array[%L, %L]::uuid[]) $$,
  :'g1', :'f1', :'ub', :'uc'), 'A creates a group with B and C');
select lives_ok(format($$ select public.create_group_conversation(%L, %L, 'Sepupu', null, array[%L, %L]::uuid[]) $$,
  :'g1', :'f1', :'ub', :'uc'), 'group creation is idempotent');
select is((select count(*)::int from public.conversation_members where conversation_id = :'g1' and left_at is null), 3, '3 members');
select is((select role from public.conversation_members where conversation_id = :'g1' and user_id = :'ua'), 'admin', 'creator is group admin');
select throws_ok(format($$ select public.create_group_conversation(%L, %L, 'Campur', null, array[%L]::uuid[]) $$,
  gen_random_uuid(), :'f1', :'ue'), 'P0002', null, 'cannot add someone from another family');

select tests.authenticate_as(:'uc');
select lives_ok(format($$ select public.send_message(%L, %L, 'Hai semua') $$, :'m3', :'g1'), 'member posts in group');
select throws_ok(format($$ select public.add_conversation_members(%L, array[%L]::uuid[]) $$, :'g1', :'um'), '42501', null,
  'ordinary group member cannot add members');
select throws_ok(format($$ select public.update_group_conversation(%L, 'Nama baru') $$, :'g1'), '42501', null,
  'ordinary member cannot rename the group');
select throws_ok(format($$ select public.set_message_pinned(%L, true) $$, :'m3'), '42501', null,
  'ordinary member cannot pin in a group');
select tests.authenticate_as(:'um');
select is((select count(*)::int from public.messages where conversation_id = :'g1'), 0,
  'family moderator who is NOT in the group cannot read it');
select tests.authenticate_as(:'ua');
select is(public.add_conversation_members(:'g1', array[:'um']::uuid[]), 1, 'group admin adds the moderator');
select tests.authenticate_as(:'um');
select lives_ok(format($$ select public.delete_message(%L) $$, :'m3'), 'family moderator in the group removes a message');
select lives_ok(format($$ select public.remove_conversation_member(%L, %L) $$, :'g1', :'uc'), 'moderator removes C from the group');
select tests.authenticate_as(:'uc');
select is((select count(*)::int from public.messages where conversation_id = :'g1'), 0, 'removed member loses access immediately');
select throws_ok(format($$ select public.send_message(%L, %L, 'masih boleh?') $$, gen_random_uuid(), :'g1'), '42501', null,
  'removed member cannot post');
select tests.authenticate_as(:'ua');
select lives_ok(format($$ select public.leave_conversation(%L) $$, :'g1'), 'admin A leaves');
select tests.clear_authentication();
select ok(exists (select 1 from public.conversation_members where conversation_id = :'g1' and left_at is null and role = 'admin'),
  'group still has an admin after the only admin left');
select ok((select count(*) from public.messages where conversation_id = :'g1' and kind = 'system') >= 3,
  'system messages record group events');

-- Own preferences only
select tests.authenticate_as(:'ub');
select lives_ok(format($$ update public.conversation_members set muted_until = now() + interval '8 hours' where conversation_id = %L and user_id = auth.uid() $$, :'dm_ab'),
  'member mutes a conversation');
update public.conversation_members set muted_until = now() + interval '1 day' where conversation_id = :'dm_ab' and user_id = :'ua';
select is((select muted_until from public.conversation_members where conversation_id = :'dm_ab' and user_id = :'ua'), null,
  'cannot change another member''s mute');
select throws_ok(format($$ update public.conversation_members set role = 'admin' where conversation_id = %L and user_id = auth.uid() $$, :'g1'),
  '42501', null, 'cannot promote self via direct update');

-- ---------------------------------------------------------------------------
-- Attachments
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'ub');
select lives_ok(format($$ insert into storage.objects (bucket_id, name, owner) values ('chat-attachments', %L, auth.uid()) $$,
  :'dm_ab' || '/' || :'m_img' || '/foto.jpg'), 'member uploads into the conversation folder');
select tests.authenticate_as(:'uc');
select throws_ok(format($$ insert into storage.objects (bucket_id, name, owner) values ('chat-attachments', %L, auth.uid()) $$,
  :'dm_ab' || '/' || gen_random_uuid() || '/x.jpg'), '42501', null, 'non-member cannot upload into a private chat');
select is((select count(*)::int from storage.objects where bucket_id = 'chat-attachments'), 0, 'non-member cannot read chat files');
select tests.authenticate_as(:'ub');
select throws_ok(format($$ select public.send_message(%L, %L, null, null, %L::jsonb) $$, :'m_bad', :'dm_ab',
  json_build_array(json_build_object('path', :'dm_ab' || '/' || :'m_bad' || '/tiada.jpg', 'mime_type', 'image/jpeg',
                                     'size_bytes', 1000, 'file_name', 'tiada.jpg'))),
  '22023', null, 'cannot attach a file that was never uploaded');
select throws_ok(format($$ select public.send_message(%L, %L, null, null, %L::jsonb) $$, :'m_bad', :'dm_ab',
  json_build_array(json_build_object('path', :'dm_ab' || '/' || :'m_img' || '/foto.jpg', 'mime_type', 'image/jpeg',
                                     'size_bytes', 1000, 'file_name', 'foto.jpg'))),
  '22023', null, 'attachment path must belong to this message');
select is((public.send_message(:'m_img', :'dm_ab', null, null,
  json_build_array(json_build_object('path', :'dm_ab' || '/' || :'m_img' || '/foto.jpg', 'mime_type', 'image/jpeg',
                                     'size_bytes', 2048, 'file_name', 'foto.jpg', 'width', 800, 'height', 600))::jsonb)).kind::text,
  'image', 'image message sent with its attachment');
select tests.authenticate_as(:'ua');
select is((select count(*)::int from storage.objects where bucket_id = 'chat-attachments'), 1, 'other participant can read the attached file');
select tests.authenticate_as(:'ub');
select public.delete_message(:'m_img');
select tests.authenticate_as(:'ua');
select is((select count(*)::int from storage.objects where bucket_id = 'chat-attachments'), 0,
  'after the message is deleted the file is no longer readable');

-- ---------------------------------------------------------------------------
-- Realtime channel authorisation (private channels)
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
insert into realtime.messages (topic, extension, event, payload, private)
values ('conversation:' || :'dm_ab', 'broadcast', 'typing', '{}', true),
       ('presence:family:' || :'f1', 'presence', 'sync', '{}', true);

select tests.authenticate_as(:'ua');
select set_config('realtime.topic', 'conversation:' || :'dm_ab', true);
select ok((select count(*) from realtime.messages) > 0, 'participant may join conversation channel');
select lives_ok($$ insert into realtime.messages (topic, extension, event, payload, private)
  values (realtime.topic(), 'broadcast', 'typing', '{}', true) $$, 'participant may broadcast typing');
select tests.authenticate_as(:'uc');
select set_config('realtime.topic', 'conversation:' || :'dm_ab', true);
select is((select count(*)::int from realtime.messages), 0, 'non-participant cannot join the private chat channel');
select throws_ok($$ insert into realtime.messages (topic, extension, event, payload, private)
  values (realtime.topic(), 'broadcast', 'typing', '{}', true) $$, '42501', null, 'non-participant cannot broadcast');
select set_config('realtime.topic', 'presence:family:' || :'f1', true);
select ok((select count(*) from realtime.messages) > 0, 'family member may join family presence');
select tests.authenticate_as(:'ue');
select set_config('realtime.topic', 'presence:family:' || :'f1', true);
select is((select count(*)::int from realtime.messages), 0, 'other family cannot join family presence');
select set_config('realtime.topic', 'conversation:not-a-uuid', true);
select is((select count(*)::int from realtime.messages), 0, 'malformed topic grants nothing');

-- ---------------------------------------------------------------------------
-- Search and suspension
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'ub');
select is((select count(*)::int from public.search_messages(:'f1', 'waalaikum')), 1, 'search finds own conversations'' messages');
select is((select count(*)::int from public.search_messages(:'f1', '%')), 0, 'wildcards are escaped / too short');
select tests.authenticate_as(:'uc');
select is((select count(*)::int from public.search_messages(:'f1', 'waalaikum')), 0, 'search never reveals other chats');

select tests.authenticate_as(:'ua');
select public.set_member_status(:'f1', :'ub', 'suspended');
select tests.authenticate_as(:'ub');
select is((select count(*)::int from public.messages), 0, 'suspended family member loses chat access');
select throws_ok(format($$ select public.send_message(%L, %L, 'masih?') $$, gen_random_uuid(), :'dm_ab'), '42501', null,
  'suspended member cannot send');

select tests.clear_authentication();
select is((select count(*)::int from pg_tables where schemaname = 'public' and not rowsecurity), 0, 'RLS enabled on every table');
select is((select count(*)::int from pg_proc p where p.pronamespace in ('public'::regnamespace, 'private'::regnamespace)
  and p.prosecdef and not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%')), 0,
  'every SECURITY DEFINER function pins search_path');

select * from finish();
rollback;
