#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc17@sha256:bc500ed74215fddcf237b71b7d3950ae2106752aed29aec17ae297d3d60b8f8b'
FIXTURE=$(mktemp -d)
PROJECT="lns-rollback-${RANDOM}-$$"
export APP_ID="$PROJECT"
export APP_DATA_DIR="$FIXTURE/app"
export APP_DOMAIN=umbrel.local
export APP_LIGHTNING_NODE_IP=10.21.21.9
export APP_LIGHTNING_NODE_DATA_DIR="$FIXTURE/lnd"
export APP_BITCOIN_NETWORK=mainnet

cleanup() {
  compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  docker run --rm -v "$FIXTURE:/fixture" \
    alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 \
    sh -c 'rm -rf /fixture/* /fixture/.[!.]* /fixture/..?*' >/dev/null 2>&1 || true
  rmdir "$FIXTURE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$APP_DATA_DIR/data" "$APP_DATA_DIR/hooks"
chmod 0777 "$APP_DATA_DIR/data"
cp -a "$PACKAGE_DIR/hooks/." "$APP_DATA_DIR/hooks/"
printf '%s\n' \
  'services:' \
  '  app_proxy:' \
  '    image: alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1' \
  > "$FIXTURE/app-proxy.yml"

compose() {
  docker compose --project-name "$PROJECT" \
    -f "$PACKAGE_DIR/docker-compose.yml" \
    -f "$FIXTURE/app-proxy.yml" "$@"
}

# Reproduce state written by the interim umbrel.2-.7 root mount.
docker run --rm -i --platform linux/arm64 --user 1000:1000 \
  -v "$APP_DATA_DIR/data:/app/secrets" \
  --entrypoint python "$APP_IMAGE" - <<'PY'
import asyncio
from pathlib import Path
from backend.app.ln_address_store import LNAddressStore
async def main():
    store=LNAddressStore(Path('/app/secrets/lnswitchboard.db'))
    await store.add_address(local_part='before-upgrade', domain='migration.invalid', min_sendable_sat=None, max_sendable_sat=None, metadata_description='interim', success_message=None, webhook_urls=[])
asyncio.run(main())
PY

compose run --rm --no-deps state_migrate

test -L "$APP_DATA_DIR/data/lnswitchboard.db" || {
  echo 'interim rollback path is not a compatibility symlink' >&2
  exit 1
}
[ "$(readlink "$APP_DATA_DIR/data/lnswitchboard.db")" = 'secrets/lnswitchboard.db' ]

# Emulate rollback: the old package remounts the data root at /app/secrets.
docker run --rm -i --platform linux/arm64 --user 1000:1000 \
  -v "$APP_DATA_DIR/data:/app/secrets" \
  --entrypoint python "$APP_IMAGE" - <<'PY'
import asyncio
from pathlib import Path
from backend.app.connection_secret_store import ConnectionSecretStore
from backend.app.ln_address_store import LNAddressStore
async def main():
    store=LNAddressStore(Path('/app/secrets/lnswitchboard.db'))
    rows=await store.list_addresses()
    assert {row['local_part'] for row in rows} == {'before-upgrade'}
    await store.add_address(local_part='during-rollback', domain='migration.invalid', min_sendable_sat=None, max_sendable_sat=None, metadata_description='rollback', success_message=None, webhook_urls=[])
    secrets=ConnectionSecretStore(Path('/app/secrets/lnswitchboard.db'), Path('/app/secrets/connection-secrets.key'))
    secrets.set('rollback-connection', {'token': 'rollback-secret-sentinel'})
    Path('/app/secrets/nostr_zap_signer.hex').write_text('11' * 32, encoding='ascii')
asyncio.run(main())
PY

# Re-upgrade must accept the owned compatibility link and preserve both records.
compose run --rm --no-deps state_migrate
docker run --rm -i --platform linux/arm64 --user 1000:1000 \
  -v "$APP_DATA_DIR/data/secrets:/app/secrets" \
  --entrypoint python "$APP_IMAGE" - <<'PY'
import asyncio
from pathlib import Path
from backend.app.connection_secret_store import ConnectionSecretStore
from backend.app.ln_address_store import LNAddressStore
async def main():
    rows=await LNAddressStore(Path('/app/secrets/lnswitchboard.db')).list_addresses()
    assert {row['local_part'] for row in rows} == {'before-upgrade', 'during-rollback'}
    secrets=ConnectionSecretStore(Path('/app/secrets/lnswitchboard.db'), Path('/app/secrets/connection-secrets.key'))
    assert secrets.get('rollback-connection') == {'token': 'rollback-secret-sentinel'}
    assert Path('/app/secrets/nostr_zap_signer.hex').read_text(encoding='ascii') == '11' * 32
asyncio.run(main())
PY

echo 'GREEN interim_rollback_and_reupgrade_preserve_records'
