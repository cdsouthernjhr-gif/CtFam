#!/usr/bin/env bash
# Calendar race tests (separate database sessions):
#  1. The same event id is created concurrently (client retries) -> one event,
#     no errors.
#  2. N members RSVP at once -> N participants, none lost.
#  3. Two reminder dispatch runs overlap -> every reminder delivered once.
set -euo pipefail
PORT="${DB_TEST_PORT:-54329}"; export PGPASSWORD=postgres
N="${RACE_USERS:-10}"
q() { psql -h localhost -p "$PORT" -U postgres -d postgres -Atq -v ON_ERROR_STOP=1 "$@"; }

A=$(q -c "select tests.create_user('cal-race-a@test.local')")
FAMILY=$(q -c "begin; select tests.authenticate_as('$A'); select public.create_family('Calendar race'); commit;" | tail -1)
CODE=$(q -c "begin; select tests.authenticate_as('$A'); select code from public.create_invitation('$FAMILY', 100, 1); commit;" | tail -1)
USERS=()
for i in $(seq 1 "$N"); do
  U=$(q -c "select tests.create_user('cal-racer$i@test.local')")
  q -c "begin; select tests.authenticate_as('$U'); select public.redeem_invitation('$CODE'); commit;" >/dev/null
  USERS+=("$U")
done

# 1. same id created concurrently
EV=$(q -c "select gen_random_uuid()")
ERR=0; PIDS=()
for i in $(seq 1 "$N"); do
  ( q -c "begin; select tests.authenticate_as('$A');
          select public.upsert_family_event('$EV', '$FAMILY', 'Mesyuarat', now() + interval '2 hours', now() + interval '3 hours',
            false, 'Asia/Kuala_Lumpur', null, null, 'family', 'none', null, 'family', null, array[60]); commit;" >/dev/null ) &
  PIDS+=($!)
done
for p in "${PIDS[@]}"; do wait "$p" || ERR=$((ERR + 1)); done
EVENTS=$(q -c "select count(*) from public.family_events where id = '$EV'")

# 2. concurrent RSVPs
for U in "${USERS[@]}"; do
  ( q -c "begin; select tests.authenticate_as('$U'); select public.set_event_rsvp('$EV', 'going'); commit;" >/dev/null ) &
done
wait
GOING=$(q -c "select count(*) from public.event_participants where event_id = '$EV' and rsvp = 'going'")

# 3. overlapping reminder runs (everyone has the 60-minute default reminder)
q -c "delete from public.notifications where dedupe_key like 'remind:%'" >/dev/null
NOW=$(q -c "select (starts_at - interval '60 minutes')::text from public.family_events where id = '$EV'")
for i in 1 2 3; do
  ( q -c "select private.dispatch_event_reminders('$NOW'::timestamptz)" >/dev/null ) &
done
wait
REMINDED=$(q -c "select count(*) from public.notifications where dedupe_key like 'remind:$EV:%'")

EXPECTED=$((N + 1))
echo "same_id: events=$EVENTS errors=$ERR | rsvp: going=$GOING/$EXPECTED | reminders=$REMINDED/$EXPECTED (3 overlapping runs)"
[ "$EVENTS" = 1 ] && [ "$ERR" = 0 ] && [ "$GOING" = "$EXPECTED" ] && [ "$REMINDED" = "$EXPECTED" ]
