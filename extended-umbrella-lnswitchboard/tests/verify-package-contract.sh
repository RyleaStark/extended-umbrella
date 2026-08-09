#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc21@sha256:36d07b3f077b29f923a91a7a6b071c5a0c98b928d239e140902c941764f0f765'
TAILSCALE_IMAGE='tailscale/tailscale:v1.102.2@sha256:321ce041508c19079b57a28b6666c8d81ab0b08accc0a2585b3ab663d557ac24'
MESH_IMAGE='cloudflare/mesh:2026.7.0@sha256:18fad6d500e8ca48b7e4d5ae1905d65e8a50c1f5f5e21eba020d54d5cbf82571'

python3 - "$PACKAGE_DIR" <<'PY'
from pathlib import Path
import re, sys, yaml
root = Path(sys.argv[1])
compose = yaml.safe_load((root / 'docker-compose.yml').read_text(encoding='utf-8'))
manifest = yaml.safe_load((root / 'umbrel-app.yml').read_text(encoding='utf-8'))
assert manifest['version'] == '0.4.0.rc21-umbrel.1'
assert 'version' not in compose
app = compose['services']['lnswitchboard']
assert app['image'] == 'ghcr.io/ryleastark/lnswitchboard:0.4.0.rc21@sha256:36d07b3f077b29f923a91a7a6b071c5a0c98b928d239e140902c941764f0f765'
assert compose['services']['tailscale']['image'] == 'tailscale/tailscale:v1.102.2@sha256:321ce041508c19079b57a28b6666c8d81ab0b08accc0a2585b3ab663d557ac24'
mesh = compose['services']['cloudflare-mesh']
assert mesh['image'] == 'cloudflare/mesh:2026.7.0@sha256:18fad6d500e8ca48b7e4d5ae1905d65e8a50c1f5f5e21eba020d54d5cbf82571'
assert mesh['group_add'] == ['1000']
volumes = app['volumes']
assert '${APP_DATA_DIR}/data/secrets:/app/secrets' in volumes
assert not any(v.startswith('${APP_DATA_DIR}/data:/app/secrets') for v in volumes)
assert not any('admin.macaroon' in v for v in volumes)
assert '${APP_LIGHTNING_NODE_DATA_DIR}/data/chain/bitcoin/${APP_BITCOIN_NETWORK}/invoice.macaroon:/lnd/invoice.macaroon:ro' in volumes
assert '${APP_LIGHTNING_NODE_DATA_DIR}/data/chain/bitcoin/${APP_BITCOIN_NETWORK}/readonly.macaroon:/lnd/readonly.macaroon:ro' in volumes
assert '${BITCOIN_NETWORK}' not in (root / 'docker-compose.yml').read_text(encoding='utf-8')
assert app['environment']['LND_HOST'] == '${APP_LIGHTNING_NODE_IP}'
assert app['environment']['DEP_ENV'] == 'UMBREL'
assert app['environment']['TRUSTED_HOSTS'] == '*'
assert app['environment']['CLOUDFLARE_OAUTH_REDIRECT_PAGE'] == (
    '${CLOUDFLARE_OAUTH_REDIRECT_PAGE:-https://placeholder.invalid/oauth/callback}'
)
proxy = compose['services']['app_proxy']
assert proxy['environment']['LOG_LEVEL'] == 'silent'
assert 'PROXY_AUTH_WHITELIST' not in proxy['environment']
assert proxy['environment']['CUSTOM_DOTENV_FILE'] == '/lnswitchboard-proxy-config/app-proxy.env'
assert '${APP_DATA_DIR}/data/proxy-config:/lnswitchboard-proxy-config:ro' in proxy['volumes']
init = compose['services']['init']
assert '${APP_DATA_DIR}/data/proxy-config:/app-proxy-config' in init['volumes']
init_script = init['command'][-1]
assert "proxy-config/app-proxy.env" in init_script
assert "LOG_LEVEL=silent" in init_script
assert "PROXY_AUTH_WHITELIST=" in init_script
assert "chmod 0444" in init_script
assert '/api/health' in app['healthcheck']['test'][-1]
ts = compose['services']['tailscale']
assert ts['entrypoint'] == ['/usr/local/bin/lnswitchboard-tailscale-supervisor']
assert ts['user'] == '1000:1000' and ts['read_only'] is True
assert ts['cap_drop'] == ['ALL'] and 'cap_add' not in ts and 'devices' not in ts
assert ts['environment']['TS_USERSPACE'] == 'true'
assert ts['environment']['TS_NO_LOGS_NO_SUPPORT'] == 'true'
assert '${APP_DATA_DIR}/data/secrets/tailscale:/run/lnswitchboard' in ts['volumes']
migrate = compose['services']['state_migrate']
assert migrate['network_mode'] == 'none'
assert migrate['user'] == '0:0'
assert migrate['read_only'] is True
assert migrate['cap_drop'] == ['ALL']
assert set(migrate['cap_add']) == {'CHOWN', 'DAC_OVERRIDE', 'FOWNER'}
assert '/app-data/connectors:size=64k,mode=000' in migrate['tmpfs']
assert migrate['security_opt'] == ['no-new-privileges:true']
assert '${APP_DATA_DIR}/data:/app-data' in migrate['volumes']
assert '${APP_DATA_DIR}/hooks/state-migrate.py:/opt/lnswitchboard/state-migrate.py:ro' in migrate['volumes']
text = '\n'.join(p.read_text(encoding='utf-8', errors='replace') for p in root.rglob('*') if p.is_file())
for pattern in (r'(?i)password\s*[:=]\s*["\']?[^$\s{]', r'(?i)(access|refresh|mesh|tailscale)[_-]?token\s*[:=]\s*["\']?[^$\s{]'):
    assert not re.search(pattern, text), f'credential-like literal matched {pattern}'
print('GREEN static_package_security_and_persistence_contract_ok')
PY

# Validate every application environment key against the exact RC21 Settings model.
docker run --rm -i --platform linux/arm64 \
  -v "$PACKAGE_DIR/docker-compose.yml:/package/docker-compose.yml:ro" \
  --entrypoint python "$APP_IMAGE" - <<'PY'
from pathlib import Path
import os
import yaml
from pydantic import ValidationError
from pydantic.aliases import AliasChoices
from backend.app.config import Settings

allowed = set()
for name, field in Settings.model_fields.items():
    allowed.add(name.upper())
    alias = field.validation_alias
    if isinstance(alias, str):
        allowed.add(alias)
    elif isinstance(alias, AliasChoices):
        allowed.update(str(choice) for choice in alias.choices if isinstance(choice, str))
compose = yaml.safe_load(Path('/package/docker-compose.yml').read_text(encoding='utf-8'))
keys = set(compose['services']['lnswitchboard']['environment'])
unknown = sorted(keys - allowed)
assert not unknown, f'RC21 ignores package environment keys: {unknown}'
invalid_redirects = {
    'CLOUDFLARE_OAUTH_REDIRECT_LOOPBACK': [
        'https://admin.example/api/cloudflare/oauth/callback',
        'http://[::ffff:127.0.0.1]:22121/api/cloudflare/oauth/callback',
    ],
    'CLOUDFLARE_OAUTH_REDIRECT_PAGE': [
        'http://oauth.example/callback/',
        'https://oauth.example/callback/?code=query-secret',
    ],
}
for env_name, values in invalid_redirects.items():
    for value in values:
        os.environ[env_name] = value
        try:
            Settings()
        except ValidationError:
            pass
        else:
            raise AssertionError(f'RC21 accepted unsafe OAuth redirect {env_name}={value}')
    os.environ.pop(env_name, None)
print('GREEN exact_rc21_settings_and_portable_oauth_contract_ok')
PY

app_revision=$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$APP_IMAGE")
[ "$app_revision" = '8369b7305a9300ed10d23af7be96be4434718bf6' ]
echo 'GREEN exact_rc21_source_revision_ok'

docker run --rm -i \
  -e DEP_ENV=DOCKER \
  -e TRUSTED_HOSTS='*' \
  -e LND_HOST=127.0.0.1 \
  "$APP_IMAGE" python - <<'PY'
import asyncio
from backend.app.main import admin_app

async def status_for(client):
    sent=[]
    delivered=False
    async def receive():
        nonlocal delivered
        if not delivered:
            delivered=True
            return {'type':'http.request','body':b'','more_body':False}
        return {'type':'http.disconnect'}
    async def send(message):
        sent.append(message)
    scope={
        'type':'http',
        'asgi':{'version':'3.0'},
        'http_version':'1.1',
        'method':'GET',
        'scheme':'http',
        'path':'/api/health',
        'raw_path':b'/api/health',
        'query_string':b'',
        'root_path':'',
        'headers':[(b'host',b'lnswitchboard.local')],
        'client':(client,43210),
        'server':('lnswitchboard.local',22121),
    }
    await admin_app(scope, receive, send)
    return next(message['status'] for message in sent if message['type']=='http.response.start')

assert asyncio.run(status_for('203.0.113.25')) == 403
assert asyncio.run(status_for('192.168.50.25')) == 200
PY
printf 'GREEN exact_rc21_generic_docker_admin_boundary_is_application_owned\n'

for image in "$APP_IMAGE" "$TAILSCALE_IMAGE" "$MESH_IMAGE"; do
  output=$(docker buildx imagetools inspect "$image")
  grep -q 'Platform:[[:space:]]*linux/amd64' <<<"$output"
  grep -q 'Platform:[[:space:]]*linux/arm64' <<<"$output"
done

bash -n "$PACKAGE_DIR/hooks/mesh-entrypoint.sh"
bash -n "$PACKAGE_DIR/hooks/tailscale-supervisor.sh"
bash -n "$PACKAGE_DIR/tests/verify-empty-interim-prefers-history.sh"
bash -n "$PACKAGE_DIR/tests/verify-fresh-install.sh"
bash -n "$PACKAGE_DIR/tests/verify-interim-layout-migration.sh"
bash -n "$PACKAGE_DIR/tests/verify-partial-migration-recovery.sh"
bash -n "$PACKAGE_DIR/tests/verify-reserved-paths-fail-closed.sh"
bash -n "$PACKAGE_DIR/tests/verify-state-conflict-fails-closed.sh"
bash -n "$PACKAGE_DIR/tests/verify-wal-migration.sh"
bash -n "$PACKAGE_DIR/tests/verify-rc12-upgrade-preservation.sh"
python3 - "$PACKAGE_DIR/hooks/state-migrate.py" <<'PY'
import ast, pathlib, sys
ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'))
PY
printf 'GREEN multiarch_indexes_and_shell_contract_ok\n'
