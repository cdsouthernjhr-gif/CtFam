#!/usr/bin/env bash
# Integration test for push dispatch: a new notification_queue row must make
# pg_net POST to the configured function URL with the Vault secret in the
# x-push-secret header; verify_push_secret must accept only that secret.
# A local HTTP server stands in for the send-push Edge Function.
set -euo pipefail
PORT="${DB_TEST_PORT:-54329}"; export PGPASSWORD=postgres
q() { psql -h localhost -p "$PORT" -U postgres -d postgres -Atq -v ON_ERROR_STOP=1 "$@"; }
qa() { psql -h localhost -p "$PORT" -U supabase_admin -d postgres -Atq -v ON_ERROR_STOP=1 "$@"; }

if [ "$(q -c "select count(*) from pg_extension where extname = 'pg_net'")" != "1" ]; then
  echo "skipped: pg_net not installed"; exit 0
fi
MOCK_PORT=8099
LOG=$(mktemp)
python3 - "$MOCK_PORT" "$LOG" <<'PY' &
import http.server, sys
port, log = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        open(log, "a").write(f"{self.path} {self.headers.get('x-push-secret','')}\n")
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"ok":true}')
    def log_message(self, *a): pass
http.server.HTTPServer(("0.0.0.0", port), H).serve_forever()
PY
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null; rm -f "$LOG"' EXIT
sleep 1

HOST_IP=$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo 172.17.0.1)
SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
qa -c "select vault.create_secret('$SECRET', 'push_webhook_secret')" >/dev/null
# Test-only: allow plain http for the local mock (production requires https).
qa -c "alter table private.push_config drop constraint if exists push_config_function_url_check;
       update private.push_config set function_url = 'http://$HOST_IP:$MOCK_PORT/functions/v1/send-push' where id = 1;"

A=$(q -c "select tests.create_user('push-a@test.local')")
B=$(q -c "select tests.create_user('push-b@test.local')")
FAMILY=$(q -c "begin; select tests.authenticate_as('$A'); select public.create_family('Push'); commit;" | tail -1)
CODE=$(q -c "begin; select tests.authenticate_as('$A'); select code from public.create_invitation('$FAMILY', 5, 1); commit;" | tail -1)
q -c "begin; select tests.authenticate_as('$B'); select public.redeem_invitation('$CODE');
      select public.register_device_token('token-push-bbbbbbbbbbbbbbbbbbbb'); commit;" >/dev/null
: > "$LOG"
q -c "begin; select tests.authenticate_as('$A'); select public.post_announcement('$FAMILY', 'Ujian', 'Hantar push'); commit;" >/dev/null

for _ in $(seq 1 20); do [ -s "$LOG" ] && break; sleep 0.5; done
CALLS=$(wc -l < "$LOG" | tr -d ' ')
GOT_SECRET=$(head -1 "$LOG" | awk '{print $2}')
PATH_OK=$(head -1 "$LOG" | awk '{print $1}')
QUEUED=$(q -c "select count(*) from public.notification_queue q join public.notifications n on n.id = q.notification_id where n.type = 'announcement'")
OK_SECRET=$(q -c "set role service_role; select public.verify_push_secret('$SECRET')")
BAD_SECRET=$(q -c "set role service_role; select public.verify_push_secret('wrong-secret-wrong-secret-wrong-secret')")
AUTH_DENIED=$(q -c "set role authenticated; select public.verify_push_secret('$SECRET')" 2>&1 | grep -c "permission denied" || true)

echo "queued=$QUEUED http_calls=$CALLS path=$PATH_OK secret_header_matches=$([ "$GOT_SECRET" = "$SECRET" ] && echo yes || echo no) verify(correct)=$OK_SECRET verify(wrong)=$BAD_SECRET clients_denied=$AUTH_DENIED"
[ "$QUEUED" = "1" ] && [ "$CALLS" -ge 1 ] && [ "$GOT_SECRET" = "$SECRET" ] && [ "$PATH_OK" = "/functions/v1/send-push" ] \
  && [ "$OK_SECRET" = "t" ] && [ "$BAD_SECRET" = "f" ] && [ "$AUTH_DENIED" = "1" ]
