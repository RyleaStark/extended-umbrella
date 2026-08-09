#!/usr/bin/env bash
set -euo pipefail
PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc18@sha256:e8a3f17e62ae3b53166db85342fed844140719cf83449601290bbd00fa50dfa4'
FIXTURE=$(mktemp -d)
PROJECT="lns-backup-only-${RANDOM}-$$"
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
mkdir -p "$APP_DATA_DIR/data/.lnswitchboard-state-backup-v1" "$APP_DATA_DIR/hooks" "$FIXTURE/seed"
chmod 0777 "$APP_DATA_DIR/data" "$FIXTURE/seed"
chmod 0700 "$APP_DATA_DIR/data/.lnswitchboard-state-backup-v1"
cp -a "$PACKAGE_DIR/hooks/." "$APP_DATA_DIR/hooks/"
docker run --rm -i --platform linux/arm64 --user 1000:1000 \
  -v "$FIXTURE/seed:/app/secrets" --entrypoint python "$APP_IMAGE" - <<'PY'
import asyncio
from pathlib import Path
from backend.app.ln_address_store import LNAddressStore
async def main():
    store=LNAddressStore(Path('/app/secrets/lnswitchboard.db'))
    await store.add_address(local_part='hidden-history',domain='recovery.invalid',min_sendable_sat=1,max_sendable_sat=2,metadata_description='archived',success_message='ok',webhook_urls=[])
asyncio.run(main())
PY
mv "$FIXTURE/seed/lnswitchboard.db" "$APP_DATA_DIR/data/.lnswitchboard-state-backup-v1/lnswitchboard.db"
printf '%s\n' '{"migrated_entries":["lnswitchboard.db"],"schema":1}' > "$APP_DATA_DIR/data/.lnswitchboard-state-migration-v1.json"
chmod 0600 "$APP_DATA_DIR/data/.lnswitchboard-state-migration-v1.json"
docker run --rm -v "$APP_DATA_DIR/data:/data" \
  alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 \
  sh -c 'chown 0:0 /data/.lnswitchboard-state-backup-v1 /data/.lnswitchboard-state-migration-v1.json; chmod 0700 /data/.lnswitchboard-state-backup-v1; chmod 0600 /data/.lnswitchboard-state-migration-v1.json'
printf '%s\n' 'services:' '  app_proxy:' '    image: alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1' > "$FIXTURE/app-proxy.yml"
compose() {
  docker compose --project-name "$PROJECT" -f "$PACKAGE_DIR/docker-compose.yml" -f "$FIXTURE/app-proxy.yml" "$@"
}
compose run --rm --no-deps state_migrate
docker run --rm -i --platform linux/arm64 --user 1000:1000 \
  -v "$APP_DATA_DIR/data/secrets:/app/secrets" --entrypoint python "$APP_IMAGE" - <<'PY'
import asyncio
from pathlib import Path
from backend.app.ln_address_store import LNAddressStore
async def main():
    rows=await LNAddressStore(Path('/app/secrets/lnswitchboard.db')).list_addresses()
    assert {row['local_part'] for row in rows} == {'hidden-history'}
asyncio.run(main())
PY
[ -L "$APP_DATA_DIR/data/lnswitchboard.db" ]
docker run --rm -v "$APP_DATA_DIR/data:/data:ro" \
  alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 \
  test -s /data/.lnswitchboard-state-backup-v1/lnswitchboard.db
echo 'GREEN backup_marker_only_state_recovers_without_hidden_records'
