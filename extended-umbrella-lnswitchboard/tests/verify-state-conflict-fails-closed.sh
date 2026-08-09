#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc21@sha256:36d07b3f077b29f923a91a7a6b071c5a0c98b928d239e140902c941764f0f765'
FIXTURE=$(mktemp -d)
PROJECT="lns-conflict-${RANDOM}-$$"
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

seed() {
  mount_source=$1
  local_part=$2
  docker run --rm -i --platform linux/arm64 --user 1000:1000 \
    -v "$mount_source:/app/secrets" \
    --entrypoint python "$APP_IMAGE" - "$local_part" <<'PY'
import asyncio, sys
from pathlib import Path
from backend.app.ln_address_store import LNAddressStore
local_part = sys.argv[1]
store = LNAddressStore(Path('/app/secrets/lnswitchboard.db'))
asyncio.run(store.add_address(
    local_part=local_part,
    domain='conflict.invalid',
    min_sendable_sat=1,
    max_sendable_sat=100,
    metadata_description='conflict fixture',
    success_message='preserved',
    webhook_urls=[],
))
PY
}

seed "$APP_DATA_DIR/data/secrets" historical-sentinel
seed "$APP_DATA_DIR/data" interim-sentinel
historical_before=$(sha256sum "$APP_DATA_DIR/data/secrets/lnswitchboard.db" | cut -d' ' -f1)
interim_before=$(sha256sum "$APP_DATA_DIR/data/lnswitchboard.db" | cut -d' ' -f1)

set +e
migration_output=$(compose run --rm --no-deps state_migrate 2>&1)
migration_status=$?
set -e
[ "$migration_status" -ne 0 ]
grep -q 'both historical and interim state exist as different bundles' <<<"$migration_output"

historical_after=$(sha256sum "$APP_DATA_DIR/data/secrets/lnswitchboard.db" | cut -d' ' -f1)
interim_after=$(sha256sum "$APP_DATA_DIR/data/lnswitchboard.db" | cut -d' ' -f1)
[ "$historical_before" = "$historical_after" ]
[ "$interim_before" = "$interim_after" ]
test ! -e "$APP_DATA_DIR/data/.lnswitchboard-state-migration-v1.json"
test ! -e "$APP_DATA_DIR/data/.lnswitchboard-state-backup-v1"
printf 'GREEN divergent_state_fails_closed_without_mutation\n'
