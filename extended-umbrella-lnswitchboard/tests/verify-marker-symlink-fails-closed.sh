#!/usr/bin/env bash
set -euo pipefail
PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FIXTURE=$(mktemp -d)
PROJECT="lns-marker-link-${RANDOM}-$$"
export APP_ID="$PROJECT"
export APP_DATA_DIR="$FIXTURE/app"
export APP_DOMAIN=umbrel.local
export APP_LIGHTNING_NODE_IP=10.21.21.9
export APP_LIGHTNING_NODE_DATA_DIR="$FIXTURE/lnd"
export APP_BITCOIN_NETWORK=mainnet
cleanup() {
  compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  docker run --rm -v "$FIXTURE:/fixture" alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 sh -c 'rm -rf /fixture/* /fixture/.[!.]* /fixture/..?*' >/dev/null 2>&1 || true
  rmdir "$FIXTURE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
mkdir -p "$APP_DATA_DIR/data/connectors" "$APP_DATA_DIR/hooks"
chmod 0777 "$APP_DATA_DIR/data"
cp -a "$PACKAGE_DIR/hooks/." "$APP_DATA_DIR/hooks/"
printf 'interim-state' > "$APP_DATA_DIR/data/connection-secrets.key"
printf 'connector-state-must-not-change' > "$APP_DATA_DIR/data/connectors/critical-state"
ln -s connectors/critical-state "$APP_DATA_DIR/data/.lnswitchboard-state-migration-v1.tmp"
printf '%s\n' 'services:' '  app_proxy:' '    image: alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1' > "$FIXTURE/app-proxy.yml"
compose() {
  docker compose --project-name "$PROJECT" -f "$PACKAGE_DIR/docker-compose.yml" -f "$FIXTURE/app-proxy.yml" "$@"
}
before=$(sha256sum "$APP_DATA_DIR/data/connectors/critical-state" | cut -d' ' -f1)
set +e
output=$(compose run --rm --no-deps state_migrate 2>&1)
status=$?
set -e
[ "$status" -ne 0 ]
grep -q 'reserved temporary marker path has an unexpected type' <<<"$output"
[ "$before" = "$(sha256sum "$APP_DATA_DIR/data/connectors/critical-state" | cut -d' ' -f1)" ]
test ! -e "$APP_DATA_DIR/data/secrets/connection-secrets.key"
echo 'GREEN marker_symlink_fails_before_connector_mutation'
