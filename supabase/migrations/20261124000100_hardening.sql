-- =============================================================================
-- FamilySync — Migration 20261124000100: hardening (Phase 7)
--
-- Trigger functions are SECURITY DEFINER and kept the default EXECUTE grant
-- to PUBLIC. Postgres refuses to call a trigger function directly, so this was
-- not exploitable, but every definer function should be explicitly locked
-- down (asserted by tests/database/08_security_audit.test.sql).
-- =============================================================================
revoke all on function private.on_message_notify() from public;
revoke all on function private.on_todo_assignment_notify() from public;
revoke all on function private.on_todo_item_notify() from public;
revoke all on function private.on_family_member_notify() from public;
revoke all on function private.on_queue_insert_kick() from public;
revoke all on function private.on_event_participant_notify() from public;
revoke all on function private.on_event_change_notify() from public;

-- New functions created by the migration owner are no longer executable by
-- PUBLIC unless granted explicitly.
alter default privileges in schema private revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from public;
