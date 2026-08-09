#!/usr/bin/env bash
set -euo pipefail
PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FIXTURE=$(mktemp -d)
PROJECT="lns-archive-interrupt-${RANDOM}-$$"
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
  "$APP_DATA_DIR/data/secrets" \
  "$APP_DATA_DIR/data/.lnswitchboard-state-stage-v1" \
  "$APP_DATA_DIR/data/.lnswitchboard-state-backup-v1" \
  "$APP_DATA_DIR/hooks"
chmod 0777 "$APP_DATA_DIR/data" "$APP_DATA_DIR/data/secrets"
python3 - "$APP_DATA_DIR/data/.lnswitchboard-state-backup-v1/lnswitchboard.db" <<'PY'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute('CREATE TABLE recovery_fixture(value TEXT NOT NULL)')
    db.execute("INSERT INTO recovery_fixture VALUES ('archived-history')")
PY
printf 'complete-key-material\n' > "$APP_DATA_DIR/data/.lnswitchboard-state-backup-v1/connection-secrets.key"
cp "$APP_DATA_DIR/data/.lnswitchboard-state-backup-v1/lnswitchboard.db" "$APP_DATA_DIR/data/secrets/lnswitchboard.db"
printf 'partial' > "$APP_DATA_DIR/data/.lnswitchboard-state-stage-v1/connection-secrets.key"
printf '%s\n' '{"migrated_entries":["connection-secrets.key","lnswitchboard.db"],"schema":1}' > "$APP_DATA_DIR/data/.lnswitchboard-state-migration-v1.json"
cp -a "$PACKAGE_DIR/hooks/." "$APP_DATA_DIR/hooks/"
docker run --rm -v "$APP_DATA_DIR/data:/data" \
  alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 \
  sh -c 'chown 0:0 /data/.lnswitchboard-state-backup-v1 /data/.lnswitchboard-state-stage-v1 /data/.lnswitchboard-state-migration-v1.json; chmod 0700 /data/.lnswitchboard-state-backup-v1 /data/.lnswitchboard-state-stage-v1; chmod 0600 /data/.lnswitchboard-state-migration-v1.json'
printf '%s\n' 'services:' '  app_proxy:' '    image: alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1' > "$FIXTURE/app-proxy.yml"
compose() {
  docker compose --project-name "$PROJECT" -f "$PACKAGE_DIR/docker-compose.yml" -f "$FIXTURE/app-proxy.yml" "$@"
}
compose run --rm --no-deps state_migrate
[ "$(cat "$APP_DATA_DIR/data/secrets/connection-secrets.key")" = 'complete-key-material' ]
python3 - "$APP_DATA_DIR/data/secrets/lnswitchboard.db" <<'PY'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as db:
    assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
    assert db.execute('SELECT value FROM recovery_fixture').fetchone()[0]=='archived-history'
PY
test ! -e "$APP_DATA_DIR/data/.lnswitchboard-state-stage-v1"
[ -L "$APP_DATA_DIR/data/connection-secrets.key" ]
[ -L "$APP_DATA_DIR/data/lnswitchboard.db" ]
# A completed rerun remains idempotent and refreshes the marker from live canonical entries.
compose run --rm --no-deps state_migrate
[ "$(cat "$APP_DATA_DIR/data/secrets/connection-secrets.key")" = 'complete-key-material' ]
echo 'GREEN archived_recovery_resumes_each_commit_boundary'
