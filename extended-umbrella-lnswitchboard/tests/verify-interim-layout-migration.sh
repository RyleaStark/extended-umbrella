#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc29@sha256:c9ffacd79b51f75f18dbf6eca238fad660f3fe264a1176ae5d3953f6d4758a24'
FIXTURE=$(mktemp -d)
PROJECT="lns-interim-${RANDOM}-$$"
export APP_ID="$PROJECT"
export APP_DATA_DIR="$FIXTURE/app-data"
export APP_LIGHTNING_NODE_IP=127.0.0.1
export APP_LIGHTNING_NODE_DATA_DIR="$FIXTURE/lightning"
export APP_BITCOIN_NETWORK=mainnet
export CLOUDFLARE_OAUTH_CLIENT_ID=''
export CLOUDFLARE_OAUTH_REDIRECT_LOOPBACK=''
export CLOUDFLARE_OAUTH_REDIRECT_PAGE=''
mkdir -p "$APP_DATA_DIR/data" "$APP_DATA_DIR/hooks" "$APP_LIGHTNING_NODE_DATA_DIR/data/chain/bitcoin/mainnet"
chmod 0777 "$APP_DATA_DIR/data"
cp -a "$PACKAGE_DIR/hooks/." "$APP_DATA_DIR/hooks/"
printf 'fixture certificate\n' > "$APP_LIGHTNING_NODE_DATA_DIR/tls.cert"
printf '00\n' > "$APP_LIGHTNING_NODE_DATA_DIR/data/chain/bitcoin/mainnet/invoice.macaroon"
printf '00\n' > "$APP_LIGHTNING_NODE_DATA_DIR/data/chain/bitcoin/mainnet/readonly.macaroon"
printf '%s\n' \
  'services:' \
  '  app_proxy:' \
  '    image: alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1' \
  > "$FIXTURE/app-proxy.yml"
compose() {
  docker compose --project-name "$PROJECT" -f "$PACKAGE_DIR/docker-compose.yml" -f "$FIXTURE/app-proxy.yml" "$@"
}
cleanup() {
  compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  docker run --rm -v "$FIXTURE:/fixture" alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 sh -c 'rm -rf /fixture/* /fixture/.[!.]* /fixture/..?*' >/dev/null 2>&1 || true
  rmdir "$FIXTURE" 2>/dev/null || true
}
trap cleanup EXIT

# Seed state exactly where the broken umbrel.2-.7 packages mounted /app/secrets.
docker run --rm -i --platform linux/arm64 --user 1000:1000 \
  -v "$APP_DATA_DIR/data:/app/secrets" \
  --entrypoint python "$APP_IMAGE" - <<'PY'
import asyncio
from pathlib import Path
from backend.app.ln_address_store import LNAddressStore
store = LNAddressStore(Path('/app/secrets/lnswitchboard.db'))
asyncio.run(store.add_address(
    local_part='interim-sentinel',
    domain='interim.invalid',
    min_sendable_sat=1,
    max_sendable_sat=100,
    metadata_description='interim package fixture',
    success_message='preserved',
    webhook_urls=[],
))
print('seeded_interim_record')
PY

test -s "$APP_DATA_DIR/data/lnswitchboard.db"
compose run --rm --no-deps state_migrate

test -s "$APP_DATA_DIR/data/secrets/lnswitchboard.db" || {
  echo 'canonical migrated database is missing' >&2
  exit 1
}
test -L "$APP_DATA_DIR/data/lnswitchboard.db" || {
  echo 'interim database compatibility link is missing' >&2
  exit 1
}
[ "$(readlink "$APP_DATA_DIR/data/lnswitchboard.db")" = 'secrets/lnswitchboard.db' ]
docker run --rm \
  -v "$APP_DATA_DIR/data:/app-data:ro" \
  alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 \
  test -s /app-data/.lnswitchboard-state-backup-v1/lnswitchboard.db || {
  echo 'preserved interim database backup is missing' >&2
  exit 1
}

docker run --rm -i --platform linux/arm64 --user 1000:1000 \
  -v "$APP_DATA_DIR/data/secrets:/app/secrets" \
  --entrypoint python "$APP_IMAGE" - <<'PY'
import asyncio, sqlite3
from pathlib import Path
from backend.app.ln_address_store import LNAddressStore
path = Path('/app/secrets/lnswitchboard.db')
rows = asyncio.run(LNAddressStore(path).list_addresses())
assert any(row['local_part'] == 'interim-sentinel' and row['domain'] == 'interim.invalid' for row in rows), rows
with sqlite3.connect(path) as db:
    assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
print('GREEN interim_layout_records_migrated_and_preserved')
PY
