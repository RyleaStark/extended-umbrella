#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FIXTURE=$(mktemp -d)
PROJECT="lns-partial-${RANDOM}-$$"
export APP_ID="$PROJECT"
export APP_DATA_DIR="$FIXTURE/app-data"
export APP_LIGHTNING_NODE_IP=127.0.0.1
export APP_LIGHTNING_NODE_DATA_DIR="$FIXTURE/lightning"
export APP_BITCOIN_NETWORK=mainnet
export CLOUDFLARE_OAUTH_CLIENT_ID=''
export CLOUDFLARE_OAUTH_REDIRECT_LOOPBACK=''
export CLOUDFLARE_OAUTH_REDIRECT_PAGE=''
mkdir -p "$APP_DATA_DIR/data/secrets" "$APP_DATA_DIR/data/.lnswitchboard-state-stage-v1" "$APP_DATA_DIR/hooks" "$APP_LIGHTNING_NODE_DATA_DIR/data/chain/bitcoin/mainnet"
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

python3 - "$APP_DATA_DIR/data/lnswitchboard.db" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute('CREATE TABLE interrupted_fixture (value TEXT NOT NULL)')
    db.execute("INSERT INTO interrupted_fixture VALUES ('preserved')")
PY
printf 'fixture-key-material\n' > "$APP_DATA_DIR/data/connection-secrets.key"
# Model a power cut after the database commit but before the second state item
# and before source archival. Also leave stale stage/marker-temp artifacts.
cp -p "$APP_DATA_DIR/data/lnswitchboard.db" "$APP_DATA_DIR/data/secrets/lnswitchboard.db"
printf 'stale stage bytes\n' > "$APP_DATA_DIR/data/.lnswitchboard-state-stage-v1/stale"
printf 'stale marker bytes\n' > "$APP_DATA_DIR/data/.lnswitchboard-state-migration-v1.tmp"

compose run --rm --no-deps state_migrate

test -s "$APP_DATA_DIR/data/secrets/lnswitchboard.db"
test -s "$APP_DATA_DIR/data/secrets/connection-secrets.key"
test ! -e "$APP_DATA_DIR/data/.lnswitchboard-state-stage-v1"
test -s "$APP_DATA_DIR/data/.lnswitchboard-state-migration-v1.json"
python3 - "$APP_DATA_DIR/data/secrets/lnswitchboard.db" <<'PY'
import sqlite3, sys
with sqlite3.connect(sys.argv[1]) as db:
    assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
    assert db.execute('SELECT value FROM interrupted_fixture').fetchone()[0] == 'preserved'
print('GREEN interrupted_migration_resumes_without_record_loss')
PY
