#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RC12_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc12@sha256:7b6bc8e30e5b1ccf5cc11ee764d0503ada7717945f2f02913b2b3404dabb8561'
RC15_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc15@sha256:9ee6cdea6deaa25b88efde9c5e4309f4862cfaf6dd1b76429053610dcd193857'
FIXTURE=$(mktemp -d)
PROJECT="lns-upgrade-${RANDOM}-$$"

APP_DATA="$FIXTURE/app-data"
LND_DATA="$FIXTURE/lightning"
mkdir -p "$APP_DATA/data/secrets" "$APP_DATA/hooks" "$LND_DATA/data/chain/bitcoin/mainnet"
cp -a "$PACKAGE_DIR/hooks/." "$APP_DATA/hooks/"
chmod 0777 "$APP_DATA/data" "$APP_DATA/data/secrets"
printf 'fixture certificate\n' > "$LND_DATA/tls.cert"
printf '00\n' > "$LND_DATA/data/chain/bitcoin/mainnet/invoice.macaroon"
printf '00\n' > "$LND_DATA/data/chain/bitcoin/mainnet/readonly.macaroon"

# Seed the database as UID/GID 1000, matching the exact RC12 package runtime.
docker run --rm -i --platform linux/arm64 --user 1000:1000 \
  -v "$APP_DATA/data/secrets:/app/secrets" \
  --entrypoint python "$RC12_IMAGE" - <<'PY'
import asyncio
from pathlib import Path
from backend.app.connection_store import ConnectionStore
from backend.app.ln_address_store import LNAddressStore

path = Path('/app/secrets/lnswitchboard.db')
addresses = LNAddressStore(path)
record = asyncio.run(addresses.add_address(
    local_part='upgrade-sentinel',
    domain='migration.invalid',
    min_sendable_sat=1,
    max_sendable_sat=100,
    metadata_description='RC12 persistence fixture',
    success_message='preserved',
    webhook_urls=[],
))
connections = ConnectionStore(path)
connection = connections.upsert_connection(
    provider='tailscale',
    external_id='upgrade-sentinel-node',
    label='RC12 persistence fixture',
    status='connected',
)
print(f"seeded_address={record['id']} seeded_connection={connection.id}")
PY

test -s "$APP_DATA/data/secrets/lnswitchboard.db"

export APP_ID="$PROJECT"
export APP_DATA_DIR="$APP_DATA"
export APP_LIGHTNING_NODE_IP=127.0.0.1
export APP_LIGHTNING_NODE_DATA_DIR="$LND_DATA"
export APP_BITCOIN_NETWORK=mainnet
export CLOUDFLARE_OAUTH_CLIENT_ID=''
export CLOUDFLARE_OAUTH_REDIRECT_LOOPBACK=''
export CLOUDFLARE_OAUTH_REDIRECT_PAGE=''

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
compose config --format json > "$FIXTURE/rendered.json"
compose run --rm --no-deps state_migrate
state_mode=$(stat -c '%u:%g:%a' "$APP_DATA/data/secrets/lnswitchboard.db")
[ "$state_mode" = '1000:1000:600' ] || {
  echo "canonical database ownership/mode is $state_mode; expected 1000:1000:600" >&2
  exit 1
}
SECRETS_SOURCE=$(python3 - "$FIXTURE/rendered.json" <<'PY'
import json,sys
config=json.load(open(sys.argv[1], encoding='utf-8'))
for mount in config['services']['lnswitchboard']['volumes']:
    if mount['target'] == '/app/secrets':
        print(mount['source'])
        break
else:
    raise SystemExit('package does not mount /app/secrets')
PY
)

# Start the exact RC15 image with the source path produced by the package and
# prove both kinds of RC12 records remain visible through RC15's real stores.
docker run --rm -i --platform linux/arm64 --user 1000:1000 \
  -v "$SECRETS_SOURCE:/app/secrets" \
  --entrypoint python "$RC15_IMAGE" - <<'PY'
import asyncio
import sqlite3
from pathlib import Path
from backend.app.connection_store import ConnectionStore
from backend.app.ln_address_store import LNAddressStore

path = Path('/app/secrets/lnswitchboard.db')
addresses = asyncio.run(LNAddressStore(path).list_addresses())
assert any(
    row['local_part'] == 'upgrade-sentinel' and row['domain'] == 'migration.invalid'
    for row in addresses
), f'RC12 LN address record disappeared after package upgrade: {addresses!r}'
connections = ConnectionStore(path).list_connections()
assert any(
    row.external_id == 'upgrade-sentinel-node' and row.label == 'RC12 persistence fixture'
    for row in connections
), f'RC12 provider connection disappeared after package upgrade: {connections!r}'
asyncio.run(LNAddressStore(path).add_address(
    local_part='post-upgrade-write',
    domain='migration.invalid',
    min_sendable_sat=1,
    max_sendable_sat=100,
    metadata_description='RC15 writeability fixture',
    success_message='writable',
    webhook_urls=[],
))
with sqlite3.connect(path) as db:
    assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
print('GREEN rc12_records_survive_rc15_package_upgrade')
PY

EXPECTED_SOURCE="$APP_DATA/data/secrets"
test "$SECRETS_SOURCE" = "$EXPECTED_SOURCE" || {
  printf 'package mounted %s; expected historical persistent path %s\n' "$SECRETS_SOURCE" "$EXPECTED_SOURCE" >&2
  exit 1
}
