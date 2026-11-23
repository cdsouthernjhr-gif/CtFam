-- FamilySync — Notifications: recipients, preferences, mute, privacy,
-- locale, quiet hours, dedupe, queue, RLS and service-role RPCs.
begin;
select no_plan();

select tests.create_user('na@test.local', 'Aminah') as ua \gset
select tests.create_user('nb@test.local', 'Badrul') as ub \gset
select tests.create_user('nc@test.local', 'Chong') as uc \gset
select tests.create_user('ne@test.local', 'Ehsan') as ue \gset

select tests.authenticate_as(:'ua');
select public.create_family('Keluarga Notifikasi') as f1 \gset
select code as inv from public.create_invitation(:'f1', 5, 24) \gset
select code as inv_appr from public.create_invitation(:'f1', 5, 24, true) \gset
select tests.authenticate_as(:'ub'); select public.redeem_invitation(:'inv');
select tests.authenticate_as(:'uc'); select public.redeem_invitation(:'inv');
select tests.authenticate_as(:'ue'); select public.create_family('Lain') as f2 \gset

-- Owner A was notified that B and C joined
select tests.authenticate_as(:'ua');
select is((select count(*)::int from public.notifications where type = 'member_joined'), 2, 'owner notified of 2 members joining');

-- Device tokens: B and C have phones, A does not
select tests.authenticate_as(:'ub'); select public.register_device_token('token-bbbbbbbbbbbbbbbbbbbbbbbb');
select tests.authenticate_as(:'uc'); select public.register_device_token('token-cccccccccccccccccccccccc');
select tests.clear_authentication();
update public.profiles set locale = 'en' where id = :'uc';
delete from public.notification_queue;

-- ---------------------------------------------------------------------------
-- Private message: privacy default, locale, recipients, push queue
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'ua');
select public.get_or_create_direct_conversation(:'f1', :'ub') as dm_ab \gset
select public.send_message(gen_random_uuid(), :'dm_ab', 'PIN bank saya 1234') as m1 \gset
select tests.clear_authentication();
select is((select count(*)::int from public.notifications where type = 'private_message'), 1, 'only the recipient is notified');
select is((select user_id from public.notifications where type = 'private_message'), :'ub'::uuid, 'recipient is B');
select is((select body from public.notifications where type = 'private_message'), 'Mesej baharu daripada Aminah',
  'lock-screen privacy by default: no message content');
select ok((select body not like '%1234%' from public.notifications where type = 'private_message'), 'content not leaked');
select is((select data ->> 'route' from public.notifications where type = 'private_message'), '/chat/' || :'dm_ab', 'tap route');
select is((select count(*)::int from public.notification_queue), 1, 'push queued for B (has a device)');

-- Preview opt-in
update public.user_preferences set show_message_preview = true where user_id = :'ub';
select tests.authenticate_as(:'ua');
select public.send_message(gen_random_uuid(), :'dm_ab', 'Jom makan');
select tests.clear_authentication();
select is((select count(*)::int from public.notifications where type = 'private_message' and body = 'Aminah: Jom makan'), 1,
  'content shown only when the recipient enabled previews');

-- Mute
select tests.authenticate_as(:'ub');
update public.conversation_members set muted_until = now() + interval '1 hour' where conversation_id = :'dm_ab' and user_id = auth.uid();
select tests.authenticate_as(:'ua');
select public.send_message(gen_random_uuid(), :'dm_ab', 'Senyap');
select tests.clear_authentication();
select is((select count(*)::int from public.notifications where type = 'private_message'), 2, 'muted conversation: no notification');

-- Group message: locale per recipient, sender excluded
select tests.authenticate_as(:'ua');
select public.create_group_conversation(gen_random_uuid(), :'f1', 'Sepupu', null, array[:'ub', :'uc']::uuid[]) as g1 \gset
select tests.authenticate_as(:'ub');
select public.send_message(gen_random_uuid(), :'g1', 'Hai semua');
select tests.clear_authentication();
select is((select count(*)::int from public.notifications where type = 'group_message'), 2, 'group: everyone except the sender');
select is((select body from public.notifications where type = 'group_message' and user_id = :'uc'), 'New message in Sepupu',
  'English recipient gets English text');
select is((select body from public.notifications where type = 'group_message' and user_id = :'ua'), 'Mesej baharu dalam Sepupu',
  'Malay recipient gets Malay text');
select is((select count(*)::int from public.notifications where type = 'group_message' and user_id = :'ub'), 0, 'sender not notified');

-- Preference off
update public.user_preferences set notify_group_messages = false where user_id = :'uc';
select tests.authenticate_as(:'ua');
select public.send_message(gen_random_uuid(), :'g1', 'Lagi');
select tests.clear_authentication();
select is((select count(*)::int from public.notifications where type = 'group_message' and user_id = :'uc'), 1,
  'turning off group notifications stops them');

-- ---------------------------------------------------------------------------
-- Tasks
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'ub');
select gen_random_uuid() as l1, gen_random_uuid() as i1 \gset
select public.create_todo_list(:'l1', :'f1', 'Rumah', 'household');
select tests.authenticate_as(:'ua');
select public.upsert_todo_item(:'i1', :'l1', 'Sapu sampah', null, 'normal', null, 'none', array[:'uc']::uuid[]);
select tests.clear_authentication();
select is((select count(*)::int from public.notifications where type = 'task_assigned' and user_id = :'uc'), 1, 'assignee notified');
select is((select count(*)::int from public.notifications where type = 'task_created' and user_id = :'ub'), 1, 'list creator notified of new task');
select tests.authenticate_as(:'uc');
select public.set_todo_item_status(:'i1', true);
select tests.clear_authentication();
select is((select count(*)::int from public.notifications where type = 'task_completed' and user_id = :'ua'), 1,
  'task creator notified on completion');
select is((select count(*)::int from public.notifications where type = 'task_completed' and user_id = :'uc'), 0,
  'the person who completed it is not notified');

-- ---------------------------------------------------------------------------
-- Dedupe: replaying the same event does not notify twice
-- ---------------------------------------------------------------------------
select is(private.notify(array[:'ub']::uuid[], :'f1', 'announcement', 'dup-test',
  '{"ms":{"title":"A","body":"B"}}'::jsonb), 1, 'first notify inserts');
select is(private.notify(array[:'ub']::uuid[], :'f1', 'announcement', 'dup-test',
  '{"ms":{"title":"A","body":"B"}}'::jsonb), 0, 'same dedupe key: no duplicate');
select is(private.notify(array[:'ue']::uuid[], :'f1', 'announcement', 'outsider-test',
  '{"ms":{"title":"A","body":"B"}}'::jsonb), 0, 'non-members of the family are never notified');

-- ---------------------------------------------------------------------------
-- Quiet hours: inbox yes, push no
-- ---------------------------------------------------------------------------
update public.user_preferences
   set quiet_hours_start = ((now() at time zone 'Asia/Kuala_Lumpur') - interval '1 hour')::time,
       quiet_hours_end = ((now() at time zone 'Asia/Kuala_Lumpur') + interval '1 hour')::time,
       timezone = 'Asia/Kuala_Lumpur'
 where user_id = :'ub';
update public.conversation_members set muted_until = null where conversation_id = :'dm_ab';
delete from public.notification_queue;
select tests.authenticate_as(:'ua');
select public.send_message(gen_random_uuid(), :'dm_ab', 'Waktu malam');
select tests.clear_authentication();
select is((select count(*)::int from public.notifications where type = 'private_message' and user_id = :'ub'), 3,
  'quiet hours: still stored in the inbox');
select is((select count(*)::int from public.notification_queue where user_id = :'ub'), 0, 'quiet hours: no push');
select is(private.in_quiet_hours('22:00', '07:00', 'Invalid/Zone') in (true, false), true, 'invalid time zone does not error');

-- ---------------------------------------------------------------------------
-- Announcements
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'ub');
select throws_ok(format($$ select public.post_announcement(%L, 'Hai', 'x') $$, :'f1'), '42501', null, 'member cannot post announcements');
select tests.authenticate_as(:'ue');
select throws_ok(format($$ select public.post_announcement(%L, 'Hai', 'x') $$, :'f1'), '42501', null, 'other family cannot post announcements');
select tests.authenticate_as(:'ua');
select is(public.post_announcement(:'f1', 'Kenduri Ahad', 'Datang jam 12 tengah hari'), 2, 'owner announcement reaches the other 2 members');

-- ---------------------------------------------------------------------------
-- RLS and RPC access
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'uc');
select ok((select count(*) from public.notifications) > 0, 'member sees own notifications');
select is((select count(*)::int from public.notifications where user_id <> auth.uid()), 0, 'never sees other users'' notifications');
select is(public.mark_notifications_read(null) > 0, true, 'mark all read');
select is((select count(*)::int from public.notifications where read_at is null), 0, 'all read');
select throws_ok($$ select count(*) from public.notification_queue $$, '42501', null, 'clients cannot read the push queue');
select throws_ok($$ select * from public.claim_push_batch(10) $$, '42501', null, 'clients cannot claim push jobs');
select throws_ok($$ select public.complete_push(1, true) $$, '42501', null, 'clients cannot complete push jobs');
select throws_ok(format($$ update public.notifications set title = 'x' where user_id = %L $$, :'uc'), '42501', null,
  'clients can only update read_at');
select tests.authenticate_anon();
select throws_ok($$ select count(*) from public.notifications $$, '42501', null, 'anon has no access');

-- ---------------------------------------------------------------------------
-- Service role: claim, retry with backoff, invalid tokens
-- ---------------------------------------------------------------------------
select tests.clear_authentication();
set local role service_role;
select ok((select count(*) from public.claim_push_batch(100)) >= 1, 'service role claims due jobs');
select is((select count(*)::int from public.claim_push_batch(100)), 0, 'claimed jobs are not handed out twice');
select min(id) as qid from public.notification_queue \gset
select public.complete_push(:'qid', false, 'timeout');
select is((select status from public.notification_queue where id = :'qid'), 'pending', 'failure is retried');
select ok((select next_attempt_at > now() from public.notification_queue where id = :'qid'), 'with backoff');
select public.complete_push(:'qid', true, null, array['token-cccccccccccccccccccccccc']);
select is((select status from public.notification_queue where id = :'qid'), 'sent', 'success recorded');
select is((select count(*)::int from public.device_tokens where token = 'token-cccccccccccccccccccccccc'), 0,
  'unregistered token removed');
reset role;

select is((select count(*)::int from pg_tables where schemaname = 'public' and not rowsecurity), 0, 'RLS on every table');
select is((select count(*)::int from pg_proc p where p.pronamespace in ('public'::regnamespace, 'private'::regnamespace)
  and p.prosecdef and not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%')), 0,
  'every SECURITY DEFINER function pins search_path');

select * from finish();
rollback;
