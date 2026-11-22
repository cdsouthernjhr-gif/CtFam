#!/usr/bin/env bash
# Races N separate database sessions redeeming the SAME single-use invitation.
# Exactly one must succeed. Runs against the throw-away test container.
set -euo pipefail
PORT="${DB_TEST_PORT:-54329}"; export PGPASSWORD=postgres
N="${RACE_USERS:-20}"
q() { psql -h localhost -p "$PORT" -U postgres -d postgres -Atq -v ON_ERROR_STOP=1 "$@"; }

OWNER=$(q -c "select tests.create_user('race-owner@test.local')")
FAMILY=$(q -c "begin; select tests.authenticate_as('$OWNER'); select public.create_family('Race family'); commit;" | tail -1)
CODE=$(q -c "begin; select tests.authenticate_as('$OWNER'); select code from public.create_invitation('$FAMILY', 1, 1); commit;" | tail -1)
USERS=()
for i in $(seq 1 "$N"); do USERS+=("$(q -c "select tests.create_user('racer$i@test.local')")"); done

TMP=$(mktemp -d)
for i in "${!USERS[@]}"; do
  ( q -c "begin; select tests.authenticate_as('${USERS[$i]}'); select public.redeem_invitation('$CODE') ->> 'status'; commit;" \
      | tail -1 > "$TMP/$i" ) &
done
wait
JOINED=$(cat "$TMP"/* | grep -c '^joined$' || true)
EXHAUSTED=$(cat "$TMP"/* | grep -c '^exhausted$' || true)
MEMBERS=$(q -c "select count(*) from public.family_members where family_id = '$FAMILY' and role = 'member'")
USES=$(q -c "select use_count from public.invitations where family_id = '$FAMILY'")
rm -rf "$TMP"
echo "joined=$JOINED exhausted=$EXHAUSTED members=$MEMBERS use_count=$USES (of $N racers)"
[ "$JOINED" = "1" ] && [ "$MEMBERS" = "1" ] && [ "$USES" = "1" ] && [ "$EXHAUSTED" = "$((N-1))" ]
