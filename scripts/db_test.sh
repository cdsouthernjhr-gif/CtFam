#!/usr/bin/env bash
# Runs all migrations and pgTAP tests against a throw-away Supabase Postgres
# container. Usage: scripts/db_test.sh            (fresh container each run)
#                   KEEP_DB=1 scripts/db_test.sh  (leave container running)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${SUPABASE_PG_IMAGE:-supabase/postgres:17.12.0.002}"
NAME="familysync-db-test"
PORT="${DB_TEST_PORT:-54329}"
export PGPASSWORD=postgres
PSQL=(psql -h localhost -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 -q)

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=postgres -p "$PORT:5432" "$IMAGE" >/dev/null
for _ in $(seq 1 60); do
  "${PSQL[@]}" -Atc 'select 1' >/dev/null 2>&1 && break
  sleep 1
done
sleep 2

echo "==> Applying local test shims"
# shims need superuser (supabase_admin); migrations run as postgres like hosted Supabase
for f in "$ROOT"/supabase/tests/support/*.sql; do
  psql -h localhost -p "$PORT" -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -q -f "$f"
done

echo "==> Applying migrations"
for f in "$ROOT"/supabase/migrations/*.sql; do
  echo "    $(basename "$f")"
  "${PSQL[@]}" -f "$f"
done
psql -h localhost -p "$PORT" -U supabase_admin -d postgres -q -c 'create extension if not exists pgtap with schema extensions;'

echo "==> Running pgTAP tests"
shopt -s nullglob
FAILED=0
for f in "$ROOT"/supabase/tests/database/*.test.sql; do
  OUT="$(cd "$ROOT" && "${PSQL[@]}" -At -v ON_ERROR_STOP=0 -f "$f" 2>&1 || true)"
  if echo "$OUT" | grep -qE '^not ok|ERROR|Looks like you (failed|planned)'; then
    echo "FAIL $(basename "$f")"; echo "$OUT" | grep -E '^not ok|ERROR|#' | head -40; FAILED=1
  else
    echo "ok   $(basename "$f") ($(echo "$OUT" | grep -c '^ok') assertions)"
  fi
done

echo "==> Running concurrency tests"
for f in "$ROOT"/supabase/tests/concurrency/*.sh; do
  if OUT="$(DB_TEST_PORT=$PORT "$f" 2>&1)"; then echo "ok   $(basename "$f"): $OUT"
  else echo "FAIL $(basename "$f"): $OUT"; FAILED=1; fi
done

[ "${KEEP_DB:-0}" = "1" ] || docker rm -f "$NAME" >/dev/null
exit $FAILED
