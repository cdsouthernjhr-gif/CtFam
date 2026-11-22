#!/usr/bin/env bash
# Multi-session To-Do race tests:
#  1. N sessions edit the same item with the same expected revision -> exactly
#     one wins, the rest get revision_conflict.
#  2. N sessions complete the same recurring item at once -> it is completed
#     once and exactly ONE next occurrence is created.
set -euo pipefail
PORT="${DB_TEST_PORT:-54329}"; export PGPASSWORD=postgres
N="${RACE_USERS:-12}"
q() { psql -h localhost -p "$PORT" -U postgres -d postgres -Atq -v ON_ERROR_STOP=1 "$@"; }

OWNER=$(q -c "select tests.create_user('todo-race-owner@test.local')")
FAMILY=$(q -c "begin; select tests.authenticate_as('$OWNER'); select public.create_family('Todo race'); commit;" | tail -1)
CODE=$(q -c "begin; select tests.authenticate_as('$OWNER'); select code from public.create_invitation('$FAMILY', 100, 1); commit;" | tail -1)
LIST=$(q -c "select gen_random_uuid()"); ITEM=$(q -c "select gen_random_uuid()"); REC=$(q -c "select gen_random_uuid()")
q -c "begin; select tests.authenticate_as('$OWNER'); select public.create_todo_list('$LIST', '$FAMILY', 'Race'); \
      select public.upsert_todo_item('$ITEM', '$LIST', 'Asal'); \
      select public.upsert_todo_item('$REC', '$LIST', 'Ulang', null, 'normal', now(), 'daily'); commit;" >/dev/null
USERS=()
for i in $(seq 1 "$N"); do
  U=$(q -c "select tests.create_user('todo-racer$i@test.local')")
  q -c "begin; select tests.authenticate_as('$U'); select public.redeem_invitation('$CODE'); commit;" >/dev/null
  USERS+=("$U")
done

TMP=$(mktemp -d)
for i in "${!USERS[@]}"; do
  ( if q -c "begin; select tests.authenticate_as('${USERS[$i]}'); \
             select public.upsert_todo_item('$ITEM', '$LIST', 'Edit $i', null, 'normal', null, 'none', null, 1); commit;" \
          >/dev/null 2>"$TMP/err$i"; then echo ok > "$TMP/edit$i"; else echo conflict > "$TMP/edit$i"; fi ) &
done
wait
EDIT_OK=$(cat "$TMP"/edit* | grep -c '^ok$' || true)
EDIT_CONFLICT=$(grep -l 'revision_conflict' "$TMP"/err* 2>/dev/null | wc -l)
REV=$(q -c "select revision from public.todo_items where id = '$ITEM'")

for i in "${!USERS[@]}"; do
  ( q -c "begin; select tests.authenticate_as('${USERS[$i]}'); select public.set_todo_item_status('$REC', true); commit;" \
      >/dev/null 2>&1 ) &
done
wait
NEXT=$(q -c "select count(*) from public.todo_items where recurrence_source_id = '$REC'")
REC_REV=$(q -c "select revision from public.todo_items where id = '$REC'")
rm -rf "$TMP"

echo "edits: ok=$EDIT_OK conflict=$EDIT_CONFLICT final_revision=$REV | recurring: next_occurrences=$NEXT revision=$REC_REV (of $N sessions)"
[ "$EDIT_OK" = "1" ] && [ "$EDIT_CONFLICT" = "$((N-1))" ] && [ "$REV" = "2" ] && [ "$NEXT" = "1" ] && [ "$REC_REV" = "2" ]
