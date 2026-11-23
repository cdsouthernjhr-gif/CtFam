-- FamilySync — linked families (rumpun) stage 1: consent, cycles, depth,
-- visibility, and NO leakage of private data across linked families.
begin;
select no_plan();

select tests.create_user('la@test.local', 'Abdul Rahman') as ua \gset
select tests.create_user('lb@test.local', 'Anak Sulung') as ub \gset
select tests.create_user('lc@test.local', 'Orang Luar') as uc \gset
select tests.create_user('ld@test.local', 'Cucu') as ud \gset

-- P = parent family (A owner, B member); C1 = B's own family (B owner, D member)
select tests.authenticate_as(:'ua');
select public.create_family('Keluarga Abdul Rahman') as p \gset
select code as inv_p from public.create_invitation(:'p', 10, 24) \gset
select public.create_todo_list(gen_random_uuid(), :'p', 'Senarai rahsia induk');
select tests.authenticate_as(:'ub');
select public.redeem_invitation(:'inv_p');
select public.create_family('Keluarga Anak Sulung') as c1 \gset
select code as inv_c1 from public.create_invitation(:'c1', 10, 24) \gset
select tests.authenticate_as(:'ud'); select public.redeem_invitation(:'inv_c1');
select tests.authenticate_as(:'uc'); select public.create_family('Keluarga Lain') as x \gset
select tests.clear_authentication();
delete from public.notifications;

-- ---------------------------------------------------------------------------
-- Requesting
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'ud');
select throws_ok(format($$ select public.request_family_link(%L, %L) $$, :'p', :'c1'), '42501', null,
  'a plain member cannot request a link');
select tests.authenticate_as(:'uc');
select throws_ok(format($$ select public.request_family_link(%L, %L) $$, :'p', :'x'), '42501', null,
  'you cannot link to a family you do not belong to');

select tests.authenticate_as(:'ub');
select (public.request_family_link(:'p', :'c1')).id as link1 \gset
select is((select status from public.family_links where id = :'link1'), 'pending', 'B (admin of C1, member of P) requests: pending');
select throws_ok(format($$ select public.respond_family_link(%L, true) $$, :'link1'), '42501', null,
  'the requesting side cannot approve its own request');
select throws_ok(format($$ select public.request_family_link(%L, %L) $$, :'p', :'c1'), '22023', 'already_linked',
  'one parent per family');
select tests.clear_authentication();
select is((select count(*)::int from public.notifications where user_id = :'ua' and dedupe_key = 'family-link:' || :'link1'), 1,
  'the parent family''s admins are notified');

select tests.authenticate_as(:'ua');
select is((select other_family_name || ':' || incoming from public.family_link_requests(:'p')),
  'Keluarga Anak Sulung:true', 'the parent sees an incoming request with the branch''s name');
select tests.authenticate_as(:'ub');
select is((select incoming from public.family_link_requests(:'c1')), false, 'the requester sees it as outgoing');
select tests.authenticate_as(:'ua');
select is((public.respond_family_link(:'link1', true)).status, 'active', 'parent owner approves');
select tests.clear_authentication();
select is((select count(*)::int from public.notifications where user_id = :'ub' and dedupe_key = 'family-link-ok:' || :'link1'), 1,
  'the requester is told');

-- Cycle: P cannot become a branch of its own branch
select tests.authenticate_as(:'ub');
select throws_ok(format($$ select public.request_family_link(%L, %L) $$, :'c1', :'p'), '22023', 'link_cycle',
  'cycles are refused');

-- Deeper: C2 (D's family) becomes a branch of C1 -> three levels
select tests.authenticate_as(:'ud');
select public.create_family('Keluarga Cucu') as c2 \gset
select (public.request_family_link(:'c1', :'c2')).id as link2 \gset
select tests.authenticate_as(:'ub');
select is((public.respond_family_link(:'link2', true)).status, 'active', 'C1 owner approves C2 as its branch');

-- ---------------------------------------------------------------------------
-- What is visible
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'ua');
select is((select array_agg(relation || ':' || name order by depth, name) from public.linked_families(:'p')),
  array['self:Keluarga Abdul Rahman', 'child:Keluarga Anak Sulung', 'clan:Keluarga Cucu'],
  'from the root: branch and sub-branch');
select tests.authenticate_as(:'ud');
select is((select array_agg(relation || ':' || name order by depth, name) from public.linked_families(:'c2')),
  array['clan:Keluarga Abdul Rahman', 'parent:Keluarga Anak Sulung', 'self:Keluarga Cucu'],
  'from the sub-branch: parent and the root');
select is((select count(*)::int from private.my_clan_family_ids()), 3, 'D''s clan has three families');
select is((select member_count from public.linked_families(:'c2') where relation = 'clan'), 2, 'member counts are shown');

-- No leakage: D is not a member of P
select is((select count(*)::int from public.family_members where family_id = :'p'), 0, 'linked families'' members are not listed');
select is((select count(*)::int from public.todo_lists where family_id = :'p'), 0, 'linked families'' tasks stay private');
select is((select count(*)::int from public.families where id = :'p'), 0, 'linked family row is not readable directly');
select is((select count(*)::int from public.audit_logs where family_id = :'p'), 0, 'activity stays private');

select tests.authenticate_as(:'uc');
select throws_ok(format($$ select * from public.linked_families(%L) $$, :'p'), '42501', null, 'outsiders cannot list a clan');
select is((select count(*)::int from public.family_links), 0, 'outsiders see no links');
select is((select count(*)::int from private.my_clan_family_ids()), 1, 'an unlinked family is a clan of one');

-- ---------------------------------------------------------------------------
-- Removing
-- ---------------------------------------------------------------------------
select tests.authenticate_as(:'ud');
select throws_ok(format($$ select public.remove_family_link(%L) $$, :'link1'), '42501', null,
  'only owner/admin of either side can unlink');
select tests.authenticate_as(:'ua');
select lives_ok(format($$ select public.remove_family_link(%L) $$, :'link1'), 'parent owner unlinks');
select is((select array_agg(name order by name) from public.linked_families(:'p')), array['Keluarga Abdul Rahman'],
  'the root is alone again');
select tests.authenticate_as(:'ud');
select is((select array_agg(name order by depth) from public.linked_families(:'c2')),
  array['Keluarga Anak Sulung', 'Keluarga Cucu'], 'C1 and C2 stay linked to each other');

-- Admin of both sides links immediately (A becomes admin in X? no: use B, admin of C1 and member of P)
select tests.authenticate_as(:'ub');
select (public.request_family_link(:'p', :'c1')).status as st \gset
select is(:'st'::text, 'pending'::text, 'B is only a member of P, so approval is still needed');

select * from finish();
rollback;
