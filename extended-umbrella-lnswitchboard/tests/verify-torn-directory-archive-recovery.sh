#!/usr/bin/env bash
set -euo pipefail
PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FIXTURE=$(mktemp -d)
PROJECT="lns-torn-dir-${RANDOM}-$$"
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
mkdir -p \
  "$APP_DATA_DIR/data/secrets/state-bundle" \
  "$APP_DATA_DIR/data/state-bundle" \
  "$APP_DATA_DIR/data/.lnswitchboard-state-backup-v1/state-bundle" \
  "$APP_DATA_DIR/hooks"
chmod 0777 "$APP_DATA_DIR/data" "$APP_DATA_DIR/data/secrets"
printf 'first\n' > "$APP_DATA_DIR/data/secrets/state-bundle/first.txt"
printf 'second\n' > "$APP_DATA_DIR/data/secrets/state-bundle/second.txt"
cp -a "$APP_DATA_DIR/data/secrets/state-bundle/." "$APP_DATA_DIR/data/.lnswitchboard-state-backup-v1/state-bundle/"
# The first source child was removed before power failed; only a strict subset remains.
printf 'second\n' > "$APP_DATA_DIR/data/state-bundle/second.txt"
cp -a "$PACKAGE_DIR/hooks/." "$APP_DATA_DIR/hooks/"
docker run --rm -v "$APP_DATA_DIR/data:/data" \
  alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 \
  sh -c 'chown -R 0:0 /data/.lnswitchboard-state-backup-v1; chmod 0700 /data/.lnswitchboard-state-backup-v1'
printf '%s\n' 'services:' '  app_proxy:' '    image: alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1' > "$FIXTURE/app-proxy.yml"
compose() {
  docker compose --project-name "$PROJECT" -f "$PACKAGE_DIR/docker-compose.yml" -f "$FIXTURE/app-proxy.yml" "$@"
}
compose run --rm --no-deps state_migrate
[ -L "$APP_DATA_DIR/data/state-bundle" ]
[ "$(readlink "$APP_DATA_DIR/data/state-bundle")" = 'secrets/state-bundle' ]
[ "$(cat "$APP_DATA_DIR/data/secrets/state-bundle/first.txt")" = first ]
[ "$(cat "$APP_DATA_DIR/data/secrets/state-bundle/second.txt")" = second ]
docker run --rm -v "$APP_DATA_DIR/data:/data:ro" \
  alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 \
  sh -c "test \"\$(cat /data/.lnswitchboard-state-backup-v1/state-bundle/first.txt)\" = first; test \"\$(cat /data/.lnswitchboard-state-backup-v1/state-bundle/second.txt)\" = second"
echo 'GREEN torn_directory_archive_cleanup_is_idempotent'
