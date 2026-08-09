#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc17@sha256:bc500ed74215fddcf237b71b7d3950ae2106752aed29aec17ae297d3d60b8f8b'
TAILSCALE_IMAGE='tailscale/tailscale:v1.102.2@sha256:321ce041508c19079b57a28b6666c8d81ab0b08accc0a2585b3ab663d557ac24'
MESH_IMAGE='cloudflare/mesh:2026.7.0@sha256:18fad6d500e8ca48b7e4d5ae1905d65e8a50c1f5f5e21eba020d54d5cbf82571'

python3 - "$PACKAGE_DIR" <<'PY'
from pathlib import Path
import re, sys, yaml
root = Path(sys.argv[1])
compose = yaml.safe_load((root / 'docker-compose.yml').read_text(encoding='utf-8'))
manifest = yaml.safe_load((root / 'umbrel-app.yml').read_text(encoding='utf-8'))
assert manifest['version'] == '0.4.0.rc17-umbrel.1'
assert 'version' not in compose
app = compose['services']['lnswitchboard']
assert app['image'] == 'ghcr.io/ryleastark/lnswitchboard:0.4.0.rc17@sha256:bc500ed74215fddcf237b71b7d3950ae2106752aed29aec17ae297d3d60b8f8b'
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

# Validate every application environment key against the exact RC17 Settings model.
docker run --rm -i --platform linux/arm64 \
  -v "$PACKAGE_DIR/docker-compose.yml:/package/docker-compose.yml:ro" \
  --entrypoint python "$APP_IMAGE" - <<'PY'
from pathlib import Path
import yaml
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
assert not unknown, f'RC17 ignores package environment keys: {unknown}'
print('GREEN exact_rc17_settings_contract_ok')
PY

app_revision=$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$APP_IMAGE")
[ "$app_revision" = '52fd8ac6e7c972c72dd2e1b650ef83d7f73cb331' ]
echo 'GREEN exact_rc17_source_revision_ok'

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
