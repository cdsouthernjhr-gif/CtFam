#!/usr/bin/env bash
# API contract test: runs every read (table + select) and every RPC the app
# uses through a real PostgREST against the local test database, as a
# signed-in family member. Catches what pgTAP cannot see:
#   * ambiguous embeds (PGRST201 / HTTP 300, e.g. two foreign keys to profiles)
#   * unknown columns or relationships in select strings
#   * RPC parameter names that do not match the SQL function (PGRST202/203)
# Needs the DB from `KEEP_DB=1 scripts/db_test.sh` and Docker.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${DB_TEST_PORT:-54329}"
API_PORT="${API_TEST_PORT:-54330}"
NAME="familysync-postgrest-test"
SECRET="local-contract-test-secret-0123456789abcdef"   # test-only, local container
export PGPASSWORD=postgres
q() { psql -h localhost -p "$PORT" -U postgres -d postgres -Atq -v ON_ERROR_STOP=1 "$@"; }

# A member with a family, so RLS helpers run their real paths
SUFFIX=$RANDOM$RANDOM
UID_=$(q -c "select tests.create_user('contract-$SUFFIX@test.local', 'Kontrak')")
FAMILY=$(q -c "begin; select tests.authenticate_as('$UID_'); select public.create_family('Kontrak $SUFFIX'); commit;" | tail -1)

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --network host \
  -e PGRST_DB_URI="postgres://postgres:postgres@localhost:$PORT/postgres" \
  -e PGRST_DB_SCHEMAS=public -e PGRST_DB_ANON_ROLE=anon \
  -e PGRST_JWT_SECRET="$SECRET" -e PGRST_SERVER_PORT="$API_PORT" \
  -e PGRST_DB_PRE_REQUEST="" \
  postgrest/postgrest:v12.2.3 >/dev/null
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 40); do curl -s -o /dev/null "http://localhost:$API_PORT/" && break; sleep 0.5; done

TOKEN=$(python3 - "$SECRET" "$UID_" <<'PY'
import base64, hashlib, hmac, json, sys, time
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b'=').decode()
header = b64(json.dumps({'alg': 'HS256', 'typ': 'JWT'}).encode())
payload = b64(json.dumps({'sub': sys.argv[2], 'role': 'authenticated', 'aud': 'authenticated',
                          'exp': int(time.time()) + 3600}).encode())
sig = b64(hmac.new(sys.argv[1].encode(), f'{header}.{payload}'.encode(), hashlib.sha256).digest())
print(f'{header}.{payload}.{sig}')
PY
)

python3 "$ROOT/tool/extract_selects.py" "$ROOT" > /tmp/familysync-api.json
python3 - "$API_PORT" "$TOKEN" "$FAMILY" /tmp/familysync-api.json <<'PY'
import json, sys, urllib.error, urllib.parse, urllib.request
port, token, family, spec = sys.argv[1], sys.argv[2], sys.argv[3], json.load(open(sys.argv[4]))
base = f'http://localhost:{port}'
H = {'Authorization': f'Bearer {token}', 'Content-Type': 'application/json'}

def call(method, path, body=None):
    req = urllib.request.Request(base + path, method=method, headers=H,
                                 data=None if body is None else json.dumps(body).encode())
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

failures = []
for table, select in spec['selects']:
    status, body = call('GET', f'/{table}?select={urllib.parse.quote(select, safe=",()!*")}&limit=1')
    if status != 200:
        failures.append(f'SELECT {table} [{status}] {body[:220]}')

LOOKUP = ('PGRST202', 'PGRST203')  # function not found / ambiguous overload
for name, variants in spec['rpcs'].items():
    for keys in (variants or [[]]):
        args = {k: None for k in keys}
        if 'p_family_id' in args:
            args['p_family_id'] = family
        status, body = call('POST', f'/rpc/{name}', args)
        if status in (300, 404) or any(code in body for code in LOOKUP):
            failures.append(f'RPC {name}({", ".join(keys)}) [{status}] {body[:220]}')

print(f"selects={len(spec['selects'])} rpcs={len(spec['rpcs'])} failures={len(failures)}")
for f in failures:
    print('  ' + f)
sys.exit(1 if failures else 0)
PY
