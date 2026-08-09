#!/usr/bin/env bash
set -euo pipefail
PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FIXTURE=$(mktemp -d)
PROJECT="lns-connector-mask-${RANDOM}-$$"
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
mkdir -p "$APP_DATA_DIR/data/connectors/private" "$APP_DATA_DIR/hooks"
printf 'connector-private-state' > "$APP_DATA_DIR/data/connectors/private/state"
chmod 0400 "$APP_DATA_DIR/data/connectors/private/state"
printf '%s\n' 'services:' '  app_proxy:' '    image: alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1' > "$FIXTURE/app-proxy.yml"
compose() {
  docker compose --project-name "$PROJECT" -f "$PACKAGE_DIR/docker-compose.yml" -f "$FIXTURE/app-proxy.yml" "$@"
}
before=$(sha256sum "$APP_DATA_DIR/data/connectors/private/state" | cut -d' ' -f1)
compose run --rm --no-deps --entrypoint python state_migrate -c \
  "from pathlib import Path; p=Path('/app-data/connectors/private/state'); assert not p.exists(); Path('/app-data/connectors/probe').write_text('ephemeral')"
[ "$before" = "$(sha256sum "$APP_DATA_DIR/data/connectors/private/state" | cut -d' ' -f1)" ]
test ! -e "$APP_DATA_DIR/data/connectors/probe"
echo 'GREEN migrator_connector_subtree_is_ephemerally_masked'
