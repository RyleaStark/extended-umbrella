#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc29@sha256:c9ffacd79b51f75f18dbf6eca238fad660f3fe264a1176ae5d3953f6d4758a24'
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

rm "$APP_DATA_DIR/data/.lnswitchboard-state-backup-v1"
mkdir "$FIXTURE/outside-public-backend"
printf 'outside-sentinel\n' > "$FIXTURE/outside-public-backend/sentinel"
outside_before=$(sha256sum "$FIXTURE/outside-public-backend/sentinel" | cut -d' ' -f1)
ln -s "$FIXTURE/outside-public-backend" "$APP_DATA_DIR/data/public-backend"
set +e
output=$(compose run --rm --no-deps state_migrate 2>&1)
status=$?
set -e
[ "$status" -ne 0 ]
grep -q 'reserved public backend path has an unexpected type' <<<"$output"
after=$(sha256sum "$APP_DATA_DIR/data/lnswitchboard.db" | cut -d' ' -f1)
outside_after=$(sha256sum "$FIXTURE/outside-public-backend/sentinel" | cut -d' ' -f1)
[ "$before" = "$after" ]
[ "$outside_before" = "$outside_after" ]
printf 'GREEN public_backend_symlink_fails_before_state_or_outside_mutation\n'

rm "$APP_DATA_DIR/data/public-backend"
mkdir "$FIXTURE/outside-cloudflare-token"
printf 'outside-token-sentinel\n' > "$FIXTURE/outside-cloudflare-token/sentinel"
outside_before=$(sha256sum "$FIXTURE/outside-cloudflare-token/sentinel" | cut -d' ' -f1)
ln -s "$FIXTURE/outside-cloudflare-token" "$APP_DATA_DIR/data/connectors/cloudflare-mesh"
set +e
output=$(compose run --rm --no-deps state_migrate 2>&1)
status=$?
set -e
[ "$status" -ne 0 ]
grep -q 'reserved writable mount source connectors/cloudflare-mesh is a symlink' <<<"$output"
after=$(sha256sum "$APP_DATA_DIR/data/lnswitchboard.db" | cut -d' ' -f1)
outside_after=$(sha256sum "$FIXTURE/outside-cloudflare-token/sentinel" | cut -d' ' -f1)
[ "$before" = "$after" ]
[ "$outside_before" = "$outside_after" ]
printf 'GREEN connector_mount_symlink_fails_before_state_or_outside_mutation\n'

rm "$APP_DATA_DIR/data/connectors/cloudflare-mesh"
mkdir "$FIXTURE/outside-tailscale-control"
printf 'outside-control-sentinel\n' > "$FIXTURE/outside-tailscale-control/sentinel"
outside_before=$(sha256sum "$FIXTURE/outside-tailscale-control/sentinel" | cut -d' ' -f1)
mkdir -p "$APP_DATA_DIR/data/secrets"
ln -s "$FIXTURE/outside-tailscale-control" "$APP_DATA_DIR/data/secrets/tailscale"
set +e
output=$(compose run --rm --no-deps state_migrate 2>&1)
status=$?
set -e
[ "$status" -ne 0 ]
grep -q 'reserved writable mount source secrets/tailscale is a symlink' <<<"$output"
after=$(sha256sum "$APP_DATA_DIR/data/lnswitchboard.db" | cut -d' ' -f1)
outside_after=$(sha256sum "$FIXTURE/outside-tailscale-control/sentinel" | cut -d' ' -f1)
[ "$before" = "$after" ]
[ "$outside_before" = "$outside_after" ]
printf 'GREEN tailscale_control_parent_symlink_fails_before_outside_mutation\n'
