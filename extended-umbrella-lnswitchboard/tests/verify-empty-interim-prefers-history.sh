#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc18@sha256:e8a3f17e62ae3b53166db85342fed844140719cf83449601290bbd00fa50dfa4'
FIXTURE=$(mktemp -d)
PROJECT="lns-empty-interim-${RANDOM}-$$"
export APP_ID="$PROJECT"
export APP_DATA_DIR="$FIXTURE/app-data"
export APP_LIGHTNING_NODE_IP=127.0.0.1
export APP_LIGHTNING_NODE_DATA_DIR="$FIXTURE/lightning"
export APP_BITCOIN_NETWORK=mainnet
export CLOUDFLARE_OAUTH_CLIENT_ID=''
export CLOUDFLARE_OAUTH_REDIRECT_LOOPBACK=''
export CLOUDFLARE_OAUTH_REDIRECT_PAGE=''
mkdir -p "$APP_DATA_DIR/data/secrets" "$APP_DATA_DIR/hooks" "$APP_LIGHTNING_NODE_DATA_DIR/data/chain/bitcoin/mainnet"
chmod 0777 "$APP_DATA_DIR/data" "$APP_DATA_DIR/data/secrets"
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

# Historical RC12 canonical database with a real record.
docker run --rm -i --platform linux/arm64 \
  -v "$APP_DATA_DIR/data/secrets:/app/secrets" \
  --entrypoint python "$APP_IMAGE" - <<'PY'
import asyncio
from pathlib import Path
from backend.app.ln_address_store import LNAddressStore
store = LNAddressStore(Path('/app/secrets/lnswitchboard.db'))
asyncio.run(store.add_address(
    local_part='historical-record', domain='preserve.invalid',
    min_sendable_sat=1, max_sendable_sat=100,
    metadata_description='historical fixture', success_message='preserved', webhook_urls=[],
))
PY
# Interim package initialized a different but record-empty database and key.
docker run --rm -i --platform linux/arm64 --user 1000:1000 \
  -v "$APP_DATA_DIR/data:/app/secrets" \
  --entrypoint python "$APP_IMAGE" - <<'PY'
from pathlib import Path
from backend.app.ln_address_store import LNAddressStore
LNAddressStore(Path('/app/secrets/lnswitchboard.db'))
Path('/app/secrets/connection-secrets.key').write_text('interim-fixture-key', encoding='utf-8')
PY
historical_before=$(sha256sum "$APP_DATA_DIR/data/secrets/lnswitchboard.db" | cut -d' ' -f1)
compose run --rm --no-deps state_migrate
historical_after=$(sha256sum "$APP_DATA_DIR/data/secrets/lnswitchboard.db" | cut -d' ' -f1)
[ "$historical_before" = "$historical_after" ]
test -L "$APP_DATA_DIR/data/lnswitchboard.db"
[ "$(readlink "$APP_DATA_DIR/data/lnswitchboard.db")" = 'secrets/lnswitchboard.db' ]

docker run --rm -i --platform linux/arm64 --user 1000:1000 \
  -v "$APP_DATA_DIR/data/secrets:/app/secrets" \
  --entrypoint python "$APP_IMAGE" - <<'PY'
import asyncio
from pathlib import Path
from backend.app.ln_address_store import LNAddressStore
rows = asyncio.run(LNAddressStore(Path('/app/secrets/lnswitchboard.db')).list_addresses())
assert any(row['local_part'] == 'historical-record' for row in rows), rows
print('GREEN historical_records_win_over_empty_interim_database')
PY
