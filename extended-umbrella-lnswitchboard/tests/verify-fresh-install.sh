#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FIXTURE=$(mktemp -d)
PROJECT="lns-fresh-${RANDOM}-$$"
export APP_ID="$PROJECT"
export APP_DATA_DIR="$FIXTURE/app-data"
export APP_LIGHTNING_NODE_IP=127.0.0.1
export APP_LIGHTNING_NODE_DATA_DIR="$FIXTURE/lightning"
export APP_BITCOIN_NETWORK=mainnet
export CLOUDFLARE_OAUTH_CLIENT_ID=''
export CLOUDFLARE_OAUTH_REDIRECT_LOOPBACK=''
export CLOUDFLARE_OAUTH_REDIRECT_PAGE=''

mkdir -p \
  "$APP_DATA_DIR" \
  "$APP_LIGHTNING_NODE_DATA_DIR/data/chain/bitcoin/$APP_BITCOIN_NETWORK"
cp -a "$PACKAGE_DIR/hooks" "$APP_DATA_DIR/hooks"
printf 'fixture certificate\n' > "$APP_LIGHTNING_NODE_DATA_DIR/tls.cert"
printf '00\n' > "$APP_LIGHTNING_NODE_DATA_DIR/data/chain/bitcoin/$APP_BITCOIN_NETWORK/invoice.macaroon"
printf '00\n' > "$APP_LIGHTNING_NODE_DATA_DIR/data/chain/bitcoin/$APP_BITCOIN_NETWORK/readonly.macaroon"
printf '%s\n' \
  'services:' \
  '  app_proxy:' \
  '    image: alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1' \
  > "$FIXTURE/app-proxy.yml"

compose() {
  docker compose \
    --project-name "$PROJECT" \
    -f "$PACKAGE_DIR/docker-compose.yml" \
    -f "$FIXTURE/app-proxy.yml" \
    "$@"
}
cleanup() {
  compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  docker run --rm \
    -v "$FIXTURE:/fixture" \
    alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 \
    sh -c 'rm -rf /fixture/* /fixture/.[!.]* /fixture/..?*' >/dev/null 2>&1 || true
  rmdir "$FIXTURE" 2>/dev/null || true
}
trap cleanup EXIT

compose config --format json > "$FIXTURE/rendered.json"
python3 - "$FIXTURE/rendered.json" "$APP_DATA_DIR" "$APP_LIGHTNING_NODE_DATA_DIR" <<'PY'
import json, os, sys
config = json.load(open(sys.argv[1], encoding='utf-8'))
app_data = os.path.realpath(sys.argv[2])
lnd_data = os.path.realpath(sys.argv[3])
app = config['services']['lnswitchboard']
mounts = {m['target']: os.path.realpath(m['source']) for m in app['volumes']}
assert mounts['/app/secrets'] == os.path.join(app_data, 'data', 'secrets')
assert mounts['/lnd/tls.cert'] == os.path.join(lnd_data, 'tls.cert')
assert mounts['/lnd/invoice.macaroon'].endswith('/data/chain/bitcoin/mainnet/invoice.macaroon')
assert mounts['/lnd/readonly.macaroon'].endswith('/data/chain/bitcoin/mainnet/readonly.macaroon')
assert not any('admin.macaroon' in m['source'] for m in app['volumes'])
assert app['environment']['LND_HOST'] == '127.0.0.1'
assert app['environment']['TRUSTED_HOSTS'] == '*'
assert app['healthcheck']['test'][-1].find('/api/health') >= 0
tailscale = config['services']['tailscale']
ts_mounts = {m['target']: os.path.realpath(m['source']) for m in tailscale['volumes']}
assert ts_mounts['/run/lnswitchboard'] == os.path.join(app_data, 'data', 'secrets', 'tailscale')
assert tailscale['user'] == '1000:1000'
assert tailscale['read_only'] is True
assert tailscale['cap_drop'] == ['ALL']
assert tailscale['environment']['TS_USERSPACE'] == 'true'
assert tailscale['environment']['TS_NO_LOGS_NO_SUPPORT'] == 'true'
print('GREEN fresh_install_render_contract_ok')
PY

compose up -d init lnswitchboard tailscale

for _ in $(seq 1 45); do
  web_health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${APP_ID}_web" 2>/dev/null || true)
  ts_health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${APP_ID}_tailscale" 2>/dev/null || true)
  [ "$web_health" = healthy ] && [ "$ts_health" = healthy ] && break
  sleep 2
done
[ "$web_health" = healthy ]
[ "$ts_health" = healthy ]

# Exercise Umbrel-proxy-shaped requests against the actual RC20 listener.
docker exec -i "${APP_ID}_web" python - <<'PY'
import urllib.request
headers = {
    'Host': 'lnswitchboard',
    'X-Forwarded-For': '8.8.8.8',
    'X-Forwarded-User': 'fixture-user',
    'X-Forwarded-Proto': 'http',
}
for path in ('/', '/api/health'):
    request = urllib.request.Request('http://127.0.0.1:22121' + path, headers=headers)
    with urllib.request.urlopen(request, timeout=5) as response:
        assert response.status == 200, (path, response.status)
print('GREEN fresh_install_proxy_routes_ok')
PY

callback_code='APPLICATION_LOOPBACK_CODE_SECRET'
callback_state='APPLICATION_LOOPBACK_STATE_SECRET'
docker exec -i "${APP_ID}_web" python - "$callback_code" "$callback_state" <<'PY'
import http.client, sys
from urllib.parse import urlencode
query = urlencode({'code': sys.argv[1], 'state': sys.argv[2]})
connection = http.client.HTTPConnection('127.0.0.1', 22121, timeout=5)
connection.request('GET', f'/api/cloudflare/oauth/callback?{query}')
response = connection.getresponse()
body = response.read()
location = response.getheader('Location', '')
assert response.status == 303, response.status
assert sys.argv[1] not in location and sys.argv[2] not in location
assert sys.argv[1].encode() not in body and sys.argv[2].encode() not in body
print('GREEN application_loopback_callback_response_redacts_query')
PY
docker logs "${APP_ID}_web" > "$FIXTURE/application.stdout" 2> "$FIXTURE/application.stderr"
for secret in "$callback_code" "$callback_state"; do
  ! grep -Fq "$secret" "$FIXTURE/application.stdout"
  ! grep -Fq "$secret" "$FIXTURE/application.stderr"
done
printf 'GREEN application_runtime_logs_redact_loopback_query_without_app_proxy\n'

# Seed through RC20, remove both runtime containers, recreate them, and prove
# the persisted database remains intact rather than living in a container layer.
docker exec -i "${APP_ID}_web" python - <<'PY'
import asyncio
from pathlib import Path
from backend.app.ln_address_store import LNAddressStore
store = LNAddressStore(Path('/app/secrets/lnswitchboard.db'))
asyncio.run(store.add_address(
    local_part='fresh-sentinel',
    domain='fixture.invalid',
    min_sendable_sat=1,
    max_sendable_sat=100,
    metadata_description='fresh install persistence fixture',
    success_message='preserved',
    webhook_urls=[],
))
print('seeded_fresh_record')
PY

compose stop tailscale lnswitchboard
compose rm -f tailscale lnswitchboard
compose up -d lnswitchboard tailscale
for _ in $(seq 1 45); do
  web_health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${APP_ID}_web" 2>/dev/null || true)
  ts_health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${APP_ID}_tailscale" 2>/dev/null || true)
  [ "$web_health" = healthy ] && [ "$ts_health" = healthy ] && break
  sleep 2
done
[ "$web_health" = healthy ]
[ "$ts_health" = healthy ]
docker run --rm -v "$APP_DATA_DIR:/app-root:ro" \
  alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 \
  sh -c "test \"\$(stat -c '%u:%g:%a' /app-root/data/proxy-config/app-proxy.env)\" = '0:0:444' && grep -qx 'LOG_LEVEL=silent' /app-root/data/proxy-config/app-proxy.env && grep -qx 'PROXY_AUTH_WHITELIST=' /app-root/data/proxy-config/app-proxy.env"
printf 'GREEN fresh_install_proxy_privacy_override_file_ok\n'

docker exec -i "${APP_ID}_web" python - <<'PY'
import asyncio, sqlite3
from pathlib import Path
from backend.app.ln_address_store import LNAddressStore
path = Path('/app/secrets/lnswitchboard.db')
rows = asyncio.run(LNAddressStore(path).list_addresses())
assert any(row['local_part'] == 'fresh-sentinel' and row['domain'] == 'fixture.invalid' for row in rows), rows
with sqlite3.connect(path) as db:
    assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
print('GREEN fresh_install_record_survives_container_recreation')
PY

first_restarts=$(docker inspect -f '{{.RestartCount}}' "${APP_ID}_tailscale")
sleep 30
second_restarts=$(docker inspect -f '{{.RestartCount}}' "${APP_ID}_tailscale")
[ "$first_restarts" = "$second_restarts" ]
[ "$second_restarts" = 0 ]
[ -s "$APP_DATA_DIR/data/secrets/lnswitchboard.db" ]
printf 'GREEN fresh_install_full_runtime_ok\n'
