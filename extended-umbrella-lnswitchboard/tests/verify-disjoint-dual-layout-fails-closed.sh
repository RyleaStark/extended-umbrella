#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc30@sha256:27323c9b90dccde55f235ce66fc99526a0e0c1646409dbe7d4888d3ab43cf568'
FIXTURE=$(mktemp -d)
PROJECT="lns-disjoint-${RANDOM}-$$"
export APP_ID="$PROJECT"
export APP_DATA_DIR="$FIXTURE/app"
export APP_DOMAIN=umbrel.local
export APP_LIGHTNING_NODE_IP=10.21.21.9
export APP_LIGHTNING_NODE_DATA_DIR="$FIXTURE/lnd"
export APP_BITCOIN_NETWORK=mainnet

cleanup() {
  compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  docker run --rm -v "$FIXTURE:/fixture" \
    alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 \
    sh -c 'rm -rf /fixture/* /fixture/.[!.]* /fixture/..?*' >/dev/null 2>&1 || true
  rmdir "$FIXTURE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$APP_DATA_DIR/data/secrets" "$APP_DATA_DIR/hooks"
chmod 0777 "$APP_DATA_DIR/data" "$APP_DATA_DIR/data/secrets"
cp -a "$PACKAGE_DIR/hooks/." "$APP_DATA_DIR/hooks/"
printf '%s\n' \
  'services:' \
  '  app_proxy:' \
  '    image: alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1' \
  > "$FIXTURE/app-proxy.yml"
compose() {
  docker compose --project-name "$PROJECT" \
    -f "$PACKAGE_DIR/docker-compose.yml" \
    -f "$FIXTURE/app-proxy.yml" "$@"
}

docker run --rm -i --platform linux/arm64 --user 1000:1000 \
  -v "$APP_DATA_DIR/data/secrets:/app/secrets" \
  --entrypoint python "$APP_IMAGE" - <<'PY'
import asyncio
from pathlib import Path
from backend.app.ln_address_store import LNAddressStore
async def main():
    store=LNAddressStore(Path('/app/secrets/lnswitchboard.db'))
    await store.add_address(local_part='historical', domain='migration.invalid', min_sendable_sat=None, max_sendable_sat=None, metadata_description='historical', success_message=None, webhook_urls=[])
asyncio.run(main())
PY
printf 'different-interim-only-state' > "$APP_DATA_DIR/data/nostr_zap_signer.hex"
chmod 0600 "$APP_DATA_DIR/data/nostr_zap_signer.hex"

historical_before=$(sha256sum "$APP_DATA_DIR/data/secrets/lnswitchboard.db" | cut -d' ' -f1)
interim_before=$(sha256sum "$APP_DATA_DIR/data/nostr_zap_signer.hex" | cut -d' ' -f1)
set +e
output=$(compose run --rm --no-deps state_migrate 2>&1)
status=$?
set -e
[ "$status" -ne 0 ] || {
  echo 'disjoint dual layouts were merged instead of refused' >&2
  exit 1
}
grep -q 'both historical and interim state exist' <<<"$output"
[ "$historical_before" = "$(sha256sum "$APP_DATA_DIR/data/secrets/lnswitchboard.db" | cut -d' ' -f1)" ]
[ "$interim_before" = "$(sha256sum "$APP_DATA_DIR/data/nostr_zap_signer.hex" | cut -d' ' -f1)" ]
test ! -e "$APP_DATA_DIR/data/secrets/nostr_zap_signer.hex"
test ! -e "$APP_DATA_DIR/data/.lnswitchboard-state-backup-v1"
echo 'GREEN disjoint_dual_layout_fails_closed_without_merge'
