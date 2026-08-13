#!/usr/bin/env bash
set -euo pipefail
PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc28@sha256:01e9e4f873b4e1ac9c5710f44ee7801e63cc0caebfc695cded34215d557ecd0d'
FIXTURE=$(mktemp -d)
PROJECT="lns-empty-archive-${RANDOM}-$$"
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
mkdir -p "$APP_DATA_DIR/data/secrets" "$APP_DATA_DIR/data/.lnswitchboard-state-backup-v1" "$APP_DATA_DIR/hooks" "$FIXTURE/empty"
chmod 0777 "$APP_DATA_DIR/data" "$APP_DATA_DIR/data/secrets" "$FIXTURE/empty"
chmod 0700 "$APP_DATA_DIR/data/.lnswitchboard-state-backup-v1"
cp -a "$PACKAGE_DIR/hooks/." "$APP_DATA_DIR/hooks/"
# Historical canonical database with a record.
docker run --rm -i --platform linux/arm64 --user 1000:1000 \
  -v "$APP_DATA_DIR/data/secrets:/app/secrets" --entrypoint python "$APP_IMAGE" - <<'PY'
import asyncio
from pathlib import Path
from backend.app.ln_address_store import LNAddressStore
store=LNAddressStore(Path('/app/secrets/lnswitchboard.db'))
asyncio.run(store.add_address(local_part='history',domain='preserve.invalid',min_sendable_sat=1,max_sendable_sat=2,metadata_description='fixture',success_message='ok',webhook_urls=[]))
PY
# Empty interim database was archived to a suffix because a stale backup was
# already present when power failed; its key remains in the root layout.
docker run --rm --platform linux/arm64 --user 1000:1000 \
  -v "$FIXTURE/empty:/app/secrets" --entrypoint python "$APP_IMAGE" \
  -c "from pathlib import Path; from backend.app.ln_address_store import LNAddressStore; LNAddressStore(Path('/app/secrets/lnswitchboard.db'))"
cp "$APP_DATA_DIR/data/secrets/lnswitchboard.db" "$APP_DATA_DIR/data/.lnswitchboard-state-backup-v1/lnswitchboard.db"
mv "$FIXTURE/empty/lnswitchboard.db" "$APP_DATA_DIR/data/.lnswitchboard-state-backup-v1/lnswitchboard.db.2"
printf 'empty-interim-key' > "$APP_DATA_DIR/data/connection-secrets.key"
docker run --rm -v "$APP_DATA_DIR/data:/data" \
  alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 \
  sh -c 'chown -R 0:0 /data/.lnswitchboard-state-backup-v1 && chmod 0700 /data/.lnswitchboard-state-backup-v1'
printf '%s\n' 'services:' '  app_proxy:' '    image: alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1' > "$FIXTURE/app-proxy.yml"
compose() {
  docker compose --project-name "$PROJECT" -f "$PACKAGE_DIR/docker-compose.yml" -f "$FIXTURE/app-proxy.yml" "$@"
}
before=$(sha256sum "$APP_DATA_DIR/data/secrets/lnswitchboard.db" | cut -d' ' -f1)
compose run --rm --no-deps state_migrate
[ "$before" = "$(sha256sum "$APP_DATA_DIR/data/secrets/lnswitchboard.db" | cut -d' ' -f1)" ]
docker run --rm -v "$APP_DATA_DIR/data:/data:ro" \
  alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 \
  test -s /data/.lnswitchboard-state-backup-v1/connection-secrets.key
[ -L "$APP_DATA_DIR/data/lnswitchboard.db" ]
test ! -e "$APP_DATA_DIR/data/connection-secrets.key"
echo 'GREEN interrupted_empty_interim_archive_prefers_history'
