#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc22@sha256:00c90371af0e20df84752b0ec52718ab8fc877baa1cafe3260d7b8cecd629f53'
RC21_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc21@sha256:36d07b3f077b29f923a91a7a6b071c5a0c98b928d239e140902c941764f0f765'
FIXTURE=$(mktemp -d)
ROOT="$FIXTURE/state"
cleanup() {
  docker run --rm -v "$FIXTURE:/fixture" \
    alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 \
    sh -c 'rm -rf /fixture/* /fixture/.[!.]* /fixture/..?*' >/dev/null 2>&1 || true
  rmdir "$FIXTURE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
mkdir -p "$ROOT"
chmod 0777 "$ROOT"

migrate() {
  docker run --rm --user 0:0 --network none --read-only \
    --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
    --security-opt no-new-privileges:true \
    --tmpfs /tmp:size=16m,mode=0700 \
    --tmpfs /app-data/connectors:size=64k,mode=000 \
    -v "$ROOT:/app-data" \
    -v "$ROOT:/host-view:ro" \
    -v "$PACKAGE_DIR/hooks/state-migrate.py:/opt/state-migrate.py:ro" \
    --entrypoint python "$APP_IMAGE" /opt/state-migrate.py
}

write_generation() {
  local image=$1 mount=$2 value=$3
  docker run --rm -i --user 1000:1000 \
    -v "$mount:/app/secrets" --entrypoint python "$image" - "$value" <<'PY'
import sys
from pathlib import Path
from backend.app.connection_secret_store import ConnectionSecretStore
store = ConnectionSecretStore(
    Path('/app/secrets/lnswitchboard.db'),
    Path('/app/secrets/connection-secrets.key'),
)
store.set('generation', {'value': sys.argv[1]})
PY
}

ln -s secrets/lnswitchboard.db-journal "$ROOT/lnswitchboard.db-journal"
status=0
output=$(migrate 2>&1) || status=$?
[ "$status" = 65 ]
grep -q 'transient compatibility link lacks durable migration authority' <<<"$output"
[ -L "$ROOT/lnswitchboard.db-journal" ]
rm "$ROOT/lnswitchboard.db-journal"
printf 'GREEN transient_sidecar_link_requires_schema_v2_archive_authority\n'

write_generation "$APP_IMAGE" "$ROOT" before-rollback
migrate >/dev/null
[ -L "$ROOT/lnswitchboard.db" ]
[ -L "$ROOT/connection-secrets.key" ]
test ! -L "$ROOT/lnswitchboard.db-journal"
test ! -L "$ROOT/lnswitchboard.db-wal"
test ! -L "$ROOT/lnswitchboard.db-shm"

# Reproduce the exact shape emitted by superseded package bytes: a generated
# sidecar compatibility link whose transient canonical target later vanishes.
ln -s secrets/lnswitchboard.db-journal "$ROOT/lnswitchboard.db-journal"
write_generation "$RC21_IMAGE" "$ROOT/secrets" during-rc21-rollback
[ -L "$ROOT/lnswitchboard.db-journal" ]
test ! -e "$ROOT/secrets/lnswitchboard.db-journal"

migrate >/dev/null
test ! -e "$ROOT/lnswitchboard.db-journal"
test ! -L "$ROOT/lnswitchboard.db-journal"

docker run --rm -i --user 1000:1000 \
  -v "$ROOT/secrets:/app/secrets" --entrypoint python "$APP_IMAGE" - <<'PY'
from pathlib import Path
from backend.app.connection_secret_store import ConnectionSecretStore
store = ConnectionSecretStore(
    Path('/app/secrets/lnswitchboard.db'),
    Path('/app/secrets/connection-secrets.key'),
)
assert store.get('generation') == {'value': 'during-rc21-rollback'}
store.set('generation', {'value': 'after-rc22-reupgrade'})
PY

migrate >/dev/null
test ! -L "$ROOT/lnswitchboard.db-journal"
test ! -L "$ROOT/lnswitchboard.db-wal"
test ! -L "$ROOT/lnswitchboard.db-shm"
printf 'GREEN rc21_rollback_reupgrade_removes_only_generated_transient_sidecar_links\n'

db_before=$(sha256sum "$ROOT/secrets/lnswitchboard.db" | cut -d' ' -f1)
printf 'outside-sentinel\n' > "$FIXTURE/outside-sentinel"
outside_before=$(sha256sum "$FIXTURE/outside-sentinel" | cut -d' ' -f1)
ln -s "$FIXTURE/outside-sentinel" "$ROOT/lnswitchboard.db-journal"
status=0
output=$(migrate 2>&1) || status=$?
[ "$status" = 65 ]
grep -q 'transient compatibility link has an unexpected target' <<<"$output"
db_after=$(sha256sum "$ROOT/secrets/lnswitchboard.db" | cut -d' ' -f1)
outside_after=$(sha256sum "$FIXTURE/outside-sentinel" | cut -d' ' -f1)
[ "$db_before" = "$db_after" ]
[ "$outside_before" = "$outside_after" ]
rm "$ROOT/lnswitchboard.db-journal"
printf 'GREEN transient_sidecar_link_rejects_untrusted_target_without_mutation\n'

ln -s secrets/lnswitchboard.db-journal "$ROOT/lnswitchboard.db-journal"
ln -P "$ROOT/lnswitchboard.db-journal" "$FIXTURE/journal-link-alias"
status=0
output=$(migrate 2>&1) || status=$?
[ "$status" = 65 ]
grep -q 'transient compatibility link has an unsafe link count' <<<"$output"
db_after=$(sha256sum "$ROOT/secrets/lnswitchboard.db" | cut -d' ' -f1)
[ "$db_before" = "$db_after" ]
printf 'GREEN transient_sidecar_link_rejects_extra_hardlink_without_mutation\n'
