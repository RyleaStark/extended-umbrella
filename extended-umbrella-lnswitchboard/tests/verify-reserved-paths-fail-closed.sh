#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc17@sha256:bc500ed74215fddcf237b71b7d3950ae2106752aed29aec17ae297d3d60b8f8b'
FIXTURE=$(mktemp -d)
PROJECT="lns-reserved-${RANDOM}-$$"
export APP_ID="$PROJECT"
export APP_DATA_DIR="$FIXTURE/app-data"
export APP_LIGHTNING_NODE_IP=127.0.0.1
export APP_LIGHTNING_NODE_DATA_DIR="$FIXTURE/lightning"
export APP_BITCOIN_NETWORK=mainnet
export CLOUDFLARE_OAUTH_CLIENT_ID=''
export CLOUDFLARE_OAUTH_REDIRECT_LOOPBACK=''
export CLOUDFLARE_OAUTH_REDIRECT_PAGE=''
mkdir -p "$APP_DATA_DIR/data/connectors" "$APP_DATA_DIR/hooks" "$APP_LIGHTNING_NODE_DATA_DIR/data/chain/bitcoin/mainnet"
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

docker run --rm -i --platform linux/arm64 --user 1000:1000 \
  -v "$APP_DATA_DIR/data:/app/secrets" \
  --entrypoint python "$APP_IMAGE" - <<'PY'
from pathlib import Path
from backend.app.connection_store import ConnectionStore
ConnectionStore(Path('/app/secrets/lnswitchboard.db')).upsert_connection(
    provider='tailscale',
    external_id='reserved-path-sentinel',
    label='reserved path fixture',
    status='connected',
)
PY
ln -s connectors "$APP_DATA_DIR/data/.lnswitchboard-state-backup-v1"
before=$(sha256sum "$APP_DATA_DIR/data/lnswitchboard.db" | cut -d' ' -f1)

set +e
output=$(compose run --rm --no-deps state_migrate 2>&1)
status=$?
set -e
[ "$status" -ne 0 ]
grep -q 'reserved backup path has an unexpected type' <<<"$output"
after=$(sha256sum "$APP_DATA_DIR/data/lnswitchboard.db" | cut -d' ' -f1)
[ "$before" = "$after" ]
test ! -e "$APP_DATA_DIR/data/secrets/lnswitchboard.db"
test ! -e "$APP_DATA_DIR/data/connectors/lnswitchboard.db"
printf 'GREEN reserved_path_symlink_fails_before_state_mutation\n'
