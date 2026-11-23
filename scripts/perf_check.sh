#!/usr/bin/env bash
# Seeds a large family in a throw-away transaction and checks query budgets.
# Needs the local test database: KEEP_DB=1 scripts/db_test.sh first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${DB_TEST_PORT:-54329}"
export PGPASSWORD=postgres
psql -h localhost -p "$PORT" -U postgres -d postgres -q -v ON_ERROR_STOP=1 \
  -f "$ROOT/supabase/tests/perf/perf_check.sql" 2>&1 | grep -E '\| +[0-9]|query|PERF'
