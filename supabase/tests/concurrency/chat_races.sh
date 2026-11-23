#!/usr/bin/env bash
# Chat race tests (separate database sessions):
#  1. Both participants tap "start chat" many times at once -> exactly one
#     direct conversation exists.
#  2. The same message id is sent concurrently (client retries) -> exactly one
#     message is stored.
#  3. N members send at once into one group -> all N stored, none lost.
set -euo pipefail
PORT="${DB_TEST_PORT:-54329}"; export PGPASSWORD=postgres
N="${RACE_USERS:-10}"
q() { psql -h localhost -p "$PORT" -U postgres -d postgres -Atq -v ON_ERROR_STOP=1 "$@"; }

A=$(q -c "select tests.create_user('chat-race-a@test.local')")
B=$(q -c "select tests.create_user('chat-race-b@test.local')")
FAMILY=$(q -c "begin; select tests.authenticate_as('$A'); select public.create_family('Chat race'); commit;" | tail -1)
CODE=$(q -c "begin; select tests.authenticate_as('$A'); select code from public.create_invitation('$FAMILY', 100, 1); commit;" | tail -1)
q -c "begin; select tests.authenticate_as('$B'); select public.redeem_invitation('$CODE'); commit;" >/dev/null

# 1. direct conversation race
for i in $(seq 1 "$N"); do
  U=$([ $((i % 2)) = 0 ] && echo "$A" || echo "$B"); O=$([ "$U" = "$A" ] && echo "$B" || echo "$A")
  ( q -c "begin; select tests.authenticate_as('$U'); select public.get_or_create_direct_conversation('$FAMILY', '$O'); commit;" >/dev/null ) &
done
wait
DIRECT=$(q -c "select count(*) from public.conversations where family_id = '$FAMILY' and kind = 'direct'")
CONV=$(q -c "select id from public.conversations where family_id = '$FAMILY' and kind = 'direct'")

# 2. same message id sent concurrently
MID=$(q -c "select gen_random_uuid()")
for i in $(seq 1 "$N"); do
  ( q -c "begin; select tests.authenticate_as('$A'); select public.send_message('$MID', '$CONV', 'retry'); commit;" >/dev/null 2>&1 || true ) &
done
wait
SAME=$(q -c "select count(*) from public.messages where id = '$MID'")

# 3. many members posting at once into a group
USERS=("$A" "$B")
for i in $(seq 1 "$N"); do
  U=$(q -c "select tests.create_user('chat-racer$i@test.local')")
  q -c "begin; select tests.authenticate_as('$U'); select public.redeem_invitation('$CODE'); commit;" >/dev/null
  USERS+=("$U")
done
GROUP=$(q -c "select gen_random_uuid()")
IDS=$(printf "'%s'," "${USERS[@]}"); IDS="${IDS%,}"
q -c "begin; select tests.authenticate_as('$A'); select public.create_group_conversation('$GROUP', '$FAMILY', 'Semua', null, array[$IDS]::uuid[]); commit;" >/dev/null
for U in "${USERS[@]}"; do
  ( q -c "begin; select tests.authenticate_as('$U'); select public.send_message(gen_random_uuid(), '$GROUP', 'hai dari $U'); commit;" >/dev/null ) &
done
wait
POSTED=$(q -c "select count(*) from public.messages where conversation_id = '$GROUP' and kind = 'text'")
EXPECTED=${#USERS[@]}

echo "direct_conversations=$DIRECT same_id_messages=$SAME group_messages=$POSTED/$EXPECTED"
[ "$DIRECT" = "1" ] && [ "$SAME" = "1" ] && [ "$POSTED" = "$EXPECTED" ]
