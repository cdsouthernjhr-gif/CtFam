-- FamilySync — RLS and RPC security tests for families, members, invitations,
-- profiles, preferences, device tokens and storage.
begin;
select no_plan();

-- ---------------------------------------------------------------------------
-- Fixtures: owner A, admin B, member C, outsider D, other-family owner E
-- ---------------------------------------------------------------------------
select tests.create_user('a@test.local', 'Aminah') as ua \gset
select tests.create_user('b@test.local', 'Badrul') as ub \gset
select tests.create_user('c@test.local', 'Chong') as uc \gset
select tests.create_user('d@test.local', 'Devi') as ud \gset
select tests.create_user('e@test.local', 'Ehsan') as ue \gset
select tests.create_user('p@test.local', 'Puteri') as up \gset

select is((select count(*)::int from public.profiles where id in (:'ua', :'ub', :'uc')), 3,
  'profiles are created automatically for new auth users');
select is((select display_name from public.profiles where id = :'ua'), 'Aminah',
  'display_name default comes from signup metadata');
select is((select count(*)::int from public.user_preferences where user_id = :'ua'), 1,
  'preferences row created for new users');
select is((select show_message_preview from public.user_preferences where user_id = :'ua'), false,
  'lock-screen message preview is OFF by default');

-- anon cannot call RPCs
select tests.authenticate_anon();
select throws_ok($$ select public.create_family('Anon family') $$, '42501', null,
  'anon cannot execute create_family');
select throws_ok($$ select count(*) from public.families $$, '42501', null, 'anon has no table access at all');

-- A creates family 1, E creates family 2
select tests.authenticate_as(:'ua');
select public.create_family('Keluarga Abdullah', 'Keluarga besar') as f1 \gset
select tests.authenticate_as(:'ue');
select public.create_family('Keluarga Lain') as f2 \gset

select tests.authenticate_as(:'ua');
select is((select role::text from public.family_members where family_id = :'f1' and user_id = :'ua'), 'owner',
  'creator becomes owner');
select is((select active_family_id from public.user_preferences where user_id = :'ua'), :'f1'::uuid,
  'creator''s active family is set');
select is((select count(*)::int from public.families), 1, 'A sees only her own family');

-- Direct inserts into family_members are impossible
select throws_ok(
  format($$ insert into public.family_members (family_id, user_id, role) values (%L, %L, 'owner') $$, :'f2', :'ua'),
  '42501', null, 'cannot insert family_members directly (no self-join to other family)');
select throws_ok(
  format($$ insert into public.families (name) values ('x') $$),
  '42501', null, 'cannot insert families directly');

-- ---------------------------------------------------------------------------
-- Invitations
-- ---------------------------------------------------------------------------
select code as inv_multi, invitation_id as inv_multi_id
  from public.create_invitation(:'f1', 5, 72, false, 'semua') \gset
select code as inv_single, invitation_id as inv_single_id
  from public.create_invitation(:'f1', 1, 24, false, null) \gset

select is(char_length(:'inv_multi'), 16, 'invitation code is 16 characters');
select ok(:'inv_multi' ~ '^[0-9A-HJKMNP-TV-Z]{16}$', 'invitation code uses Crockford base32 alphabet');
select ok(
  not exists (select 1 from public.invitations i where i.id = :'inv_multi_id' and i::text like '%' || :'inv_multi' || '%'),
  'raw invitation code is not stored in the invitations row');
select is((select token_hint from public.invitations where id = :'inv_multi_id'), right(:'inv_multi', 4),
  'only a 4-char hint is stored');

-- C (outsider so far) previews and redeems
select tests.authenticate_as(:'uc');
select is((select family_name from public.preview_invitation(:'inv_multi')), 'Keluarga Abdullah',
  'preview reveals family name for a valid code');
select is((select count(*)::int from public.families), 0, 'before joining C sees no families');
select is(public.redeem_invitation(lower(substr(:'inv_multi', 1, 8)) || '-' || substr(:'inv_multi', 9)) ->> 'status',
  'joined', 'C joins with a valid code (case/separator-insensitive)');
select is((select count(*)::int from public.families where id = :'f1'), 1, 'after joining C sees the family');
select is(public.redeem_invitation(:'inv_multi') ->> 'status', 'already_member', 'redeeming again is idempotent');
select is((select use_count from public.invitations where id = :'inv_multi_id'), null::int,
  'ordinary members cannot read invitations');

-- B joins with the single-use code; P tries the same single-use code
select tests.authenticate_as(:'ub');
select is(public.redeem_invitation(:'inv_single') ->> 'status', 'joined', 'B joins with single-use code');
select tests.authenticate_as(:'up');
select is(public.redeem_invitation(:'inv_single') ->> 'status', 'exhausted',
  'single-use invitation cannot be reused by another user');

-- ---------------------------------------------------------------------------
-- Roles
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'uc');
select throws_ok(format($$ select public.set_member_role(%L, %L, 'admin') $$, :'f1', :'uc'),
  '42501', null, 'member cannot promote themselves');
select throws_ok(format($$ select public.set_member_role(%L, %L, 'admin') $$, :'f1', :'ub'),
  '42501', null, 'member cannot promote others');
select throws_ok(format($$ update public.family_members set role = 'owner' where user_id = %L $$, :'uc'),
  '42501', null, 'member cannot update role column directly');
select throws_ok(format($$ select * from public.create_invitation(%L) $$, :'f1'),
  '42501', null, 'member cannot create invitations');

select tests.authenticate_as(:'ua');
select lives_ok(format($$ select public.set_member_role(%L, %L, 'admin') $$, :'f1', :'ub'),
  'owner can promote B to admin');
select throws_ok(format($$ select public.set_member_role(%L, %L, 'owner') $$, :'f1', :'ub'),
  '22023', null, 'set_member_role cannot assign owner');

select tests.authenticate_as(:'ub');
select throws_ok(format($$ select public.set_member_role(%L, %L, 'member') $$, :'f1', :'ua'),
  '42501', null, 'admin cannot demote the owner');
select throws_ok(format($$ select public.set_member_role(%L, %L, 'admin') $$, :'f1', :'uc'),
  '42501', null, 'admin cannot create other admins');
select lives_ok(format($$ select public.set_member_role(%L, %L, 'moderator') $$, :'f1', :'uc'),
  'admin can make C a moderator');
select ok((select count(*) from public.invitations where family_id = :'f1') = 2, 'admin can read invitations');
select lives_ok(format($$ select public.revoke_invitation(%L) $$, :'inv_multi_id'), 'admin can revoke invitation');

select tests.authenticate_as(:'up');
select is(public.redeem_invitation(:'inv_multi') ->> 'status', 'revoked', 'revoked invitation cannot be redeemed');

-- Admin E of another family cannot touch family 1
select tests.authenticate_as(:'ue');
select throws_ok(format($$ select public.set_member_status(%L, %L, 'removed') $$, :'f1', :'uc'),
  '42501', null, 'owner of another family cannot remove members of family 1');
select throws_ok(format($$ select * from public.create_invitation(%L) $$, :'f1'),
  '42501', null, 'owner of another family cannot create invitations for family 1');
select is((select count(*)::int from public.family_members where family_id = :'f1'), 0,
  'cross-family: E cannot list family 1 members');
select is((select count(*)::int from public.audit_logs where family_id = :'f1'), 0,
  'cross-family: E cannot read family 1 activity');
select is((select count(*)::int from public.profiles where id = :'ua'), 0,
  'cross-family: E cannot read A''s profile');

-- ---------------------------------------------------------------------------
-- Expiry, approval, suspension
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'ua');
select code as inv_exp, invitation_id as inv_exp_id from public.create_invitation(:'f1', 3, 1) \gset
select code as inv_appr from public.create_invitation(:'f1', 3, 24, true) \gset
select tests.clear_authentication();
update public.invitations set created_at = now() - interval '3 hours', expires_at = now() - interval '1 hour'
  where id = :'inv_exp_id';

select tests.authenticate_as(:'up');
select is(public.redeem_invitation(:'inv_exp') ->> 'status', 'expired', 'expired invitation is rejected');
select is(public.redeem_invitation(:'inv_appr') ->> 'status', 'pending_approval', 'approval-required invitation gives pending');
select is((select count(*)::int from public.families where id = :'f1'), 0, 'pending member cannot see family');

select tests.authenticate_as(:'uc');
select throws_ok(format($$ select public.review_membership(%L, %L, true) $$, :'f1', :'up'),
  '42501', null, 'moderator cannot approve membership');
select tests.authenticate_as(:'ub');
select lives_ok(format($$ select public.review_membership(%L, %L, true) $$, :'f1', :'up'), 'admin approves P');
select tests.authenticate_as(:'up');
select is((select count(*)::int from public.families where id = :'f1'), 1, 'approved member sees the family');

select tests.authenticate_as(:'ub');
select lives_ok(format($$ select public.set_member_status(%L, %L, 'suspended') $$, :'f1', :'up'), 'admin suspends P');
select tests.authenticate_as(:'up');
select is((select count(*)::int from public.families where id = :'f1'), 0, 'suspended member loses access immediately');
select is((select count(*)::int from public.profiles where id = :'ua'), 0, 'suspended member cannot read family profiles');

-- ---------------------------------------------------------------------------
-- Brute force protection
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'ud');
select public.redeem_invitation('ZZZZZZZZZZZZZZZ' || n::text) from generate_series(0, 9) n;
select is(public.redeem_invitation(:'inv_appr') ->> 'status', 'rate_limited',
  'after 10 failed attempts even a valid code is refused (rate limited)');
select is((select count(*)::int from public.families), 0, 'outsider D still sees no families');

-- ---------------------------------------------------------------------------
-- Profiles & preferences
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'uc');
select is((select count(*)::int from public.profiles where id in (:'ua', :'ub')), 2, 'family members can read each other''s profiles');
update public.profiles set display_name = 'hacked' where id = :'ua';
select is((select display_name from public.profiles where id = :'ua'), 'Aminah', 'cannot update another user''s profile');
select lives_ok($$ update public.profiles set display_name = 'Chong Wei' where id = auth.uid() $$, 'can update own profile');
select throws_ok(format($$ update public.profiles set avatar_path = %L where id = auth.uid() $$, :'ua' || '/x.jpg'),
  '42501', null, 'avatar_path must point to own folder');
select throws_ok(format($$ update public.user_preferences set active_family_id = %L where user_id = auth.uid() $$, :'f2'),
  '42501', null, 'cannot set active family to a family you do not belong to');

-- ---------------------------------------------------------------------------
-- Device tokens
-- ---------------------------------------------------------------------------
select lives_ok($$ select public.register_device_token('fcm-token-ccccccccccccccccccccccc', 'Pixel', '1.0.0') $$, 'register FCM token');
select tests.authenticate_as(:'ua');
select is((select count(*)::int from public.device_tokens), 0, 'users cannot see other users'' device tokens');
select lives_ok($$ select public.register_device_token('fcm-token-ccccccccccccccccccccccc', 'Pixel', '1.0.0') $$,
  'token re-registered by a new account on the same device');
select tests.clear_authentication();
select is((select user_id from public.device_tokens where token = 'fcm-token-ccccccccccccccccccccccc'), :'ua'::uuid,
  'token ownership moves to the latest account');

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'uc');
select lives_ok(format($$ insert into storage.objects (bucket_id, name) values ('avatars', %L) $$, :'uc' || '/me.jpg'),
  'user uploads avatar into own folder');
select throws_ok(format($$ insert into storage.objects (bucket_id, name) values ('avatars', %L) $$, :'ua' || '/x.jpg'),
  '42501', null, 'user cannot upload into another user''s avatar folder');
select throws_ok(format($$ insert into storage.objects (bucket_id, name) values ('family-media', %L) $$, :'f1' || '/x.jpg'),
  '42501', null, 'moderator cannot upload family images');
select tests.authenticate_as(:'ua');
select is((select count(*)::int from storage.objects where name = :'uc' || '/me.jpg'), 1, 'family member can read avatar');
select lives_ok(format($$ insert into storage.objects (bucket_id, name) values ('family-media', %L) $$, :'f1' || '/cover.jpg'),
  'owner uploads family image');
select tests.authenticate_as(:'ue');
select is((select count(*)::int from storage.objects), 0, 'other family cannot read avatars or family images');
select throws_ok(format($$ insert into storage.objects (bucket_id, name) values ('family-media', %L) $$, :'f1' || '/evil.jpg'),
  '42501', null, 'other family cannot upload into family 1 folder');
select tests.clear_authentication();
select is((select public from storage.buckets where id = 'avatars'), false, 'avatars bucket is private');
select is((select file_size_limit from storage.buckets where id = 'family-media'), 5242880::bigint, 'upload size limit set');

-- ---------------------------------------------------------------------------
-- Ownership transfer, leaving, deletion
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'ua');
select throws_ok(format($$ select public.leave_family(%L) $$, :'f1'), '22023', null, 'owner must transfer before leaving');
select is((select count(*)::int from public.account_deletion_blockers()), 1, 'owner with members is blocked from deleting account');
select lives_ok(format($$ select public.transfer_ownership(%L, %L) $$, :'f1', :'ub'), 'owner transfers to B');
select is((select role::text from public.family_members where family_id = :'f1' and user_id = :'ua'), 'admin', 'old owner becomes admin');
select tests.authenticate_as(:'ub');
select throws_ok(format($$ select public.delete_family(%L, 'wrong') $$, :'f1'), '22023', null, 'delete_family requires exact name');
select tests.authenticate_as(:'ua');
select throws_ok(format($$ select public.delete_family(%L, 'Keluarga Abdullah') $$, :'f1'), '42501', null, 'admin cannot delete family');
select tests.authenticate_as(:'ub');
select lives_ok(format($$ select public.delete_family(%L, 'Keluarga Abdullah') $$, :'f1'), 'owner deletes family');
select tests.authenticate_as(:'uc');
select is((select count(*)::int from public.families), 0, 'deleted family is no longer visible');

-- RLS enabled everywhere in public
select tests.clear_authentication();
select is(
  (select count(*)::int from pg_tables where schemaname = 'public' and not rowsecurity), 0,
  'RLS is enabled on every public table');
select is(
  (select count(*)::int from pg_proc p where p.pronamespace in ('public'::regnamespace, 'private'::regnamespace)
     and p.prosecdef and not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%')), 0,
  'every SECURITY DEFINER function pins search_path');

select * from finish();
rollback;
