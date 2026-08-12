#!/usr/bin/env bash
set -euo pipefail
PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc26@sha256:f23473b8d89cb8b1eb521ba873ec2104a941788af74593f12e175693db78bf4d'
FIXTURE=$(mktemp -d)
PROJECT="lns-legacy-ambiguity-${RANDOM}-$$"
export APP_ID="$PROJECT"
export APP_DATA_DIR="$FIXTURE/app-data"
cleanup() {
  docker compose -p "$PROJECT" -f "$PACKAGE_DIR/docker-compose.yml" -f "$FIXTURE/app-proxy.yml" down --remove-orphans -v >/dev/null 2>&1 || true
  docker run --rm -v "$FIXTURE:/fixture" alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 sh -c 'rm -rf /fixture/* /fixture/.[!.]* /fixture/..?*' >/dev/null 2>&1 || true
  rmdir "$FIXTURE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
mkdir -p "$APP_DATA_DIR/data" "$APP_DATA_DIR/hooks" "$FIXTURE/a" "$FIXTURE/b"
cp "$PACKAGE_DIR/hooks/state-migrate.py" "$APP_DATA_DIR/hooks/state-migrate.py"
chmod 0555 "$APP_DATA_DIR/hooks/state-migrate.py"
chmod 0777 "$APP_DATA_DIR/data" "$FIXTURE/a" "$FIXTURE/b"
docker run --rm --user 1000:1000 -v "$FIXTURE/a:/state" --entrypoint python "$APP_IMAGE" -c "from pathlib import Path; from backend.app.connection_secret_store import ConnectionSecretStore; ConnectionSecretStore(Path('/state/lnswitchboard.db'),Path('/state/connection-secrets.key'))"
docker run --rm -i --user 1000:1000 -v "$FIXTURE/b:/state" --entrypoint python "$APP_IMAGE" <<'PY'
from pathlib import Path
from backend.app.connection_secret_store import ConnectionSecretStore
store=ConnectionSecretStore(Path('/state/lnswitchboard.db'),Path('/state/connection-secrets.key'))
store.set('provider',{'token':'retained-authority'})
PY
backup="$APP_DATA_DIR/data/.lnswitchboard-state-backup-v1"
mkdir -p "$backup"
chmod 0700 "$backup"
cp "$FIXTURE/a/lnswitchboard.db" "$backup/lnswitchboard.db.2"
cp "$FIXTURE/a/connection-secrets.key" "$backup/connection-secrets.key"
cp "$FIXTURE/b/lnswitchboard.db" "$backup/lnswitchboard.db"
cp "$FIXTURE/b/connection-secrets.key" "$backup/connection-secrets.key.2"
printf '%s\n' '{"schema":1,"migrated_entries":["connection-secrets.key","lnswitchboard.db"]}' > "$APP_DATA_DIR/data/.lnswitchboard-state-migration-v1.json"
chmod 0600 "$APP_DATA_DIR/data/.lnswitchboard-state-migration-v1.json"
docker run --rm -v "$APP_DATA_DIR/data:/data" alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 sh -c 'chown 0:0 /data/.lnswitchboard-state-backup-v1 /data/.lnswitchboard-state-migration-v1.json'
printf '%s\n' 'services:' '  app_proxy:' '    image: alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1' > "$FIXTURE/app-proxy.yml"
before=$(docker run --rm -v "$APP_DATA_DIR/data:/data:ro" alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 sha256sum /data/.lnswitchboard-state-backup-v1/lnswitchboard.db /data/.lnswitchboard-state-backup-v1/lnswitchboard.db.2 /data/.lnswitchboard-state-backup-v1/connection-secrets.key /data/.lnswitchboard-state-backup-v1/connection-secrets.key.2)
set +e
output=$(docker compose -p "$PROJECT" -f "$PACKAGE_DIR/docker-compose.yml" -f "$FIXTURE/app-proxy.yml" run --rm state_migrate 2>&1)
status=$?
set -e
[ "$status" = 65 ]
grep -q 'does not bind a unique archived generation' <<<"$output"
[ ! -e "$APP_DATA_DIR/data/secrets" ]
after=$(docker run --rm -v "$APP_DATA_DIR/data:/data:ro" alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 sha256sum /data/.lnswitchboard-state-backup-v1/lnswitchboard.db /data/.lnswitchboard-state-backup-v1/lnswitchboard.db.2 /data/.lnswitchboard-state-backup-v1/connection-secrets.key /data/.lnswitchboard-state-backup-v1/connection-secrets.key.2)
[ "$before" = "$after" ]
printf 'GREEN ambiguous_schema1_archive_generations_fail_closed_without_mutation\n'
