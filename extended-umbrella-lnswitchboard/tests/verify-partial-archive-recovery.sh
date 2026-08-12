#!/usr/bin/env bash
set -euo pipefail
PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc25@sha256:1085582e9220532f62c7a00214ea0caccbc670260a56deaa28d34766dd16907c'
FIXTURE=$(mktemp -d)
PROJECT="lns-archive-recovery-${RANDOM}-$$"
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
mkdir -p "$APP_DATA_DIR/data/secrets" "$APP_DATA_DIR/data/.lnswitchboard-state-backup-v1" "$APP_DATA_DIR/hooks"
chmod 0777 "$APP_DATA_DIR/data" "$APP_DATA_DIR/data/secrets"
chmod 0700 "$APP_DATA_DIR/data/.lnswitchboard-state-backup-v1"
cp -a "$PACKAGE_DIR/hooks/." "$APP_DATA_DIR/hooks/"
# Model a power loss after canonical commit and after the database source moved
# to backup, but before the remaining key was archived and links were created.
docker run --rm -i --platform linux/arm64 --user 1000:1000 \
  -v "$APP_DATA_DIR/data:/app/secrets" --entrypoint python "$APP_IMAGE" - <<'PY'
from pathlib import Path
from backend.app.connection_store import ConnectionStore
root=Path('/app/secrets')
ConnectionStore(root/'lnswitchboard.db').upsert_connection(
    provider='tailscale', external_id='archive-recovery', label='fixture', status='connected'
)
(root/'connection-secrets.key').write_text('fixture-key', encoding='utf-8')
PY
cp -a "$APP_DATA_DIR/data/lnswitchboard.db" "$APP_DATA_DIR/data/secrets/lnswitchboard.db"
cp -a "$APP_DATA_DIR/data/lnswitchboard.db-journal" "$APP_DATA_DIR/data/secrets/lnswitchboard.db-journal"
cp -a "$APP_DATA_DIR/data/connection-secrets.key" "$APP_DATA_DIR/data/secrets/connection-secrets.key"
mv "$APP_DATA_DIR/data/lnswitchboard.db" "$APP_DATA_DIR/data/.lnswitchboard-state-backup-v1/lnswitchboard.db"
docker run --rm -v "$APP_DATA_DIR/data:/data" \
  alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 \
  sh -c 'chown -R 0:0 /data/.lnswitchboard-state-backup-v1 && chmod 0700 /data/.lnswitchboard-state-backup-v1'
printf '%s\n' 'services:' '  app_proxy:' '    image: alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1' > "$FIXTURE/app-proxy.yml"
compose() {
  docker compose --project-name "$PROJECT" -f "$PACKAGE_DIR/docker-compose.yml" -f "$FIXTURE/app-proxy.yml" "$@"
}
compose run --rm --no-deps state_migrate
[ -L "$APP_DATA_DIR/data/lnswitchboard.db" ]
test ! -e "$APP_DATA_DIR/data/lnswitchboard.db-journal"
test ! -L "$APP_DATA_DIR/data/lnswitchboard.db-journal"
[ -L "$APP_DATA_DIR/data/connection-secrets.key" ]
docker run --rm -v "$APP_DATA_DIR/data:/data:ro" \
  alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 \
  sh -c 'test -s /data/.lnswitchboard-state-backup-v1/lnswitchboard.db; test -e /data/.lnswitchboard-state-backup-v1/lnswitchboard.db-journal; test -s /data/.lnswitchboard-state-backup-v1/connection-secrets.key'
docker run --rm -i --platform linux/arm64 --user 1000:1000 \
  -v "$APP_DATA_DIR/data/secrets:/app/secrets" --entrypoint python "$APP_IMAGE" - <<'PY'
from pathlib import Path
from backend.app.connection_store import ConnectionStore
rows=ConnectionStore(Path('/app/secrets/lnswitchboard.db')).list_connections()
assert any(row.external_id=='archive-recovery' for row in rows), rows
PY
echo 'GREEN interrupted_archive_cleanup_recovers_without_record_loss'
