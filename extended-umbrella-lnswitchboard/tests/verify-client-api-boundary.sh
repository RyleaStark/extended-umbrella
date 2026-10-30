#!/usr/bin/env bash
set -euo pipefail
PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$PACKAGE_DIR" <<'PY'
import sys
from pathlib import Path
import yaml
root = Path(sys.argv[1])
services = yaml.safe_load((root / 'docker-compose.yml').read_text())['services']
app = services['lnswitchboard']
assert app['environment']['CLIENT_API_ENABLED'] == 'true'
assert app['environment']['CLIENT_API_HOST'] == '0.0.0.0'
assert app['environment']['CLIENT_API_PORT'] == '22122'
assert app['ports'] == ['22122:22122']
assert services['lnswitchboard-public']['ports'] == ['21212:21212']
assert services['app_proxy']['environment']['APP_PORT'] == 22121
assert 'PROXY_AUTH_WHITELIST' not in services['app_proxy']['environment']
assert b'PROXY_AUTH_WHITELIST=\\n' in (root / 'hooks/prepare-state-guard.py').read_bytes()
print('GREEN client_only_port_no_dashboard_proxy_bypass')
PY
APP_IMAGE=$(python3 - "$PACKAGE_DIR/docker-compose.yml" <<'PY'
import sys, yaml
print(yaml.safe_load(open(sys.argv[1]))['services']['lnswitchboard']['image'])
PY
)
# No provider access or wallet requests: all LND targets are disposable loopback.
container_id=$(docker run --detach --rm \
  --publish 127.0.0.1::22122 \
  --env CLIENT_API_ENABLED=true --env CLIENT_API_HOST=0.0.0.0 \
  --env CLIENT_API_PORT=22122 --env LND_HOST=127.0.0.1 \
  --env DATA_STORE_PATH=/tmp/lnswitchboard.db \
  --env MACAROON_STORE_PATH=/tmp/macaroon.hex \
  --env NOSTR_ZAP_SECRET_PATH=/tmp/nostr.hex \
  --env TRUSTED_HOSTS='127.0.0.1,localhost' \
  --env TRUSTED_PROXY_CIDRS='' "$APP_IMAGE")
trap 'docker rm --force "$container_id" >/dev/null 2>&1 || true' EXIT
port=$(docker inspect --format '{{(index (index .NetworkSettings.Ports "22122/tcp") 0).HostPort}}' "$container_id")
python3 - "$port" <<'PY'
import sys, time, urllib.error, urllib.request
base = 'http://127.0.0.1:' + sys.argv[1]

def status(path, headers=None):
    try:
        with urllib.request.urlopen(urllib.request.Request(base+path, headers=headers or {}), timeout=2) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code

for attempt in range(60):
    try:
        ready = status('/api/client/v1/addresses/missing') == 401
    except (OSError, TimeoutError):
        ready = False
    if ready:
        break
    time.sleep(0.5)
else:
    raise AssertionError('client-only listener never became ready')
for path in ('/', '/api/client-credentials', '/api/client-credentials/status', '/api/settings', '/api/health', '/openapi.json', '/.well-known/lnurlp/pay',
             '/api/client/v1/%2e%2e/%2e%2e/%2e%2e/index.html', '/api/client/v1/%2e%2e/%2e%2e/%2e%2e/'):
    assert status(path) == 404, path
assert status('/api/client/v1/addresses/missing', {'Authorization':'Bearer invalid'}) == 401
# Direct caller cannot spoof a public or private source through forwarding headers.
assert status('/api/client/v1/addresses/missing', {'X-Forwarded-For':'8.8.8.8'}) == 401
print('GREEN exact_published_image_client_tcp_auth_and_operator_route_exclusion')
PY
# The exact shipped image must include the native settings UI and report a live
# client listener only through its private administration boundary.
docker exec -i "$container_id" python - <<'PY'
import json
from pathlib import Path
from urllib.request import urlopen
with urlopen('http://127.0.0.1:22121/api/client-credentials/status', timeout=3) as response:
    assert response.headers['Cache-Control'] == 'no-store, private'
    status = json.load(response)
assert status == {'enabled': True, 'listening': True, 'host': '0.0.0.0', 'port': 22122, 'allow_private_webhooks': False}, status
from backend.app.env_settings import ENV_FIELDS
assert any(field['key'] == 'ALLOW_PRIVATE_WEBHOOKS' and field['editable'] for field in ENV_FIELDS)
assets = list(Path('/app/frontend/static/assets').glob('settings-*.js'))
assert assets, 'missing compiled settings UI'
source = '\n'.join(path.read_text() for path in assets)
for label in ('Machine clients', 'Provision client', 'Webhook signing secret', 'Done — clear token', 'Confirm revoke'):
    assert label in source, label
print('GREEN exact_published_image_native_machine_client_settings_and_live_status')
PY
