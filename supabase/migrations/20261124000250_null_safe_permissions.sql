-- =============================================================================
-- FamilySync — Migration 20261124000250: NULL-safe permission checks
--
-- Found while testing the family tree: in PL/pgSQL, `if not (a = b or c)` does
-- NOT raise when a is NULL (NULL OR false = NULL, NOT NULL = NULL, and IF
-- treats NULL as false). When the creator/sender deleted their account
-- (created_by / sender_id set to NULL), any list member could delete that
-- task and any conversation member could delete that message.
-- Both checks now use IS NOT DISTINCT FROM. Signatures and grants unchanged.
-- Regression tests: supabase/tests/database/10_null_safety.test.sql
-- =============================================================================

create or replace function public.delete_todo_item(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_item public.todo_items%rowtype;
begin
  select * into v_item from public.todo_items where id = p_id for update;
  if v_item.id is null or not private.can_access_todo_list(v_item.list_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_item.deleted_at is not null then
    return;  -- idempotent
  end if;
  if not (v_item.created_by is not distinct from v_uid or private.can_manage_todo_list(v_item.list_id)) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.todo_items set deleted_at = now(), updated_by = v_uid, revision = revision + 1 where id = p_id;
  perform private.todo_log(v_item.family_id, v_item.list_id, v_item.id, 'item.deleted',
    jsonb_build_object('title', v_item.title));
end;
$$;

create or replace function public.delete_message(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := private.require_uid();
  v_msg public.messages%rowtype;
begin
  select * into v_msg from public.messages where id = p_id for update;
  if v_msg.id is null or not private.is_conversation_member(v_msg.conversation_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_msg.deleted_at is not null then
    return;  -- idempotent
  end if;
  if not (v_msg.sender_id is not distinct from v_uid or private.can_moderate_conversation(v_msg.conversation_id))
     or v_msg.kind = 'system' then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.messages
     set body = null, meta = null, deleted_at = now(), deleted_by = v_uid, pinned_at = null, pinned_by = null
   where id = p_id;
  -- Attachment rows go away, which also revokes Storage read access to them.
  delete from public.message_attachments where message_id = p_id;
  update public.conversations set last_message_preview = null, revision = revision + 1
   where id = v_msg.conversation_id and last_message_at = v_msg.created_at;
end;
$$;
