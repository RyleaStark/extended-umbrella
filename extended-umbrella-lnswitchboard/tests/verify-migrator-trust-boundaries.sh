#!/usr/bin/env bash
set -euo pipefail
PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc20@sha256:8d5524bfbebc1f2c8c16af25d8ef4b5f888577c8644d727e9dd8efd0395224c6'
FIXTURE=$(mktemp -d)
cleanup() {
  docker run --rm -v "$FIXTURE:/fixture" alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 sh -c 'rm -rf /fixture/* /fixture/.[!.]* /fixture/..?*' >/dev/null 2>&1 || true
  rmdir "$FIXTURE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
run_migrator() {
  local root=$1
  docker run --rm --platform linux/arm64 --user 0:0 --network none --read-only \
    --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
    --security-opt no-new-privileges:true \
    --tmpfs /tmp:size=16m,mode=0700 --tmpfs /app-data/connectors:size=64k,mode=000 \
    -v "$root:/app-data" -v "$PACKAGE_DIR/hooks/state-migrate.py:/opt/lnswitchboard/state-migrate.py:ro" \
    --entrypoint python "$APP_IMAGE" /opt/lnswitchboard/state-migrate.py
}
# A pre-positioned app-owned stage is untrusted and must survive refusal unchanged.
root="$FIXTURE/app-owned-stage"
mkdir -p "$root/.lnswitchboard-state-stage-v1"
printf 'untrusted-stage\n' > "$root/.lnswitchboard-state-stage-v1/sentinel"
printf 'source-state\n' > "$root/new-state"
chmod 0700 "$root/.lnswitchboard-state-stage-v1"
before=$(sha256sum "$root/.lnswitchboard-state-stage-v1/sentinel" "$root/new-state")
set +e
output=$(run_migrator "$root" 2>&1)
status=$?
set -e
[ "$status" -ne 0 ]
grep -q 'reserved staging path must be owned by root' <<<"$output"
[ "$before" = "$(sha256sum "$root/.lnswitchboard-state-stage-v1/sentinel" "$root/new-state")" ]
# The application-owned root may pre-position the new App Proxy config path.
# A symlink must fail closed before the root migrator follows or replaces it.
root="$FIXTURE/proxy-config-symlink"
mkdir -p "$root/connectors"
printf 'connector-sentinel\n' > "$root/connectors/private"
ln -s connectors "$root/proxy-config"
before=$(sha256sum "$root/connectors/private")
set +e
output=$(run_migrator "$root" 2>&1)
status=$?
set -e
[ "$status" -ne 0 ]
grep -q 'reserved App Proxy configuration path has an unexpected type' <<<"$output"
[ "$before" = "$(sha256sum "$root/connectors/private")" ]
test -L "$root/proxy-config"
# An ordinary application-owned reserved directory is likewise untrusted.
root="$FIXTURE/proxy-config-owner"
mkdir -p "$root/proxy-config"
printf 'untrusted-proxy-config\n' > "$root/proxy-config/app-proxy.env"
before=$(sha256sum "$root/proxy-config/app-proxy.env")
set +e
output=$(run_migrator "$root" 2>&1)
status=$?
set -e
[ "$status" -ne 0 ]
grep -q 'reserved App Proxy configuration path is not trusted' <<<"$output"
[ "$before" = "$(sha256sum "$root/proxy-config/app-proxy.env")" ]
# A hard link to connector-private state is rejected before copying or archival.
root="$FIXTURE/hard-link"
mkdir -p "$root/connectors/mesh"
printf 'connector-private-token\n' > "$root/connectors/mesh/node-token"
ln "$root/connectors/mesh/node-token" "$root/leaked-token-link"
before=$(sha256sum "$root/connectors/mesh/node-token" "$root/leaked-token-link")
set +e
output=$(run_migrator "$root" 2>&1)
status=$?
set -e
[ "$status" -ne 0 ]
grep -q 'hard-linked state entry is not safe to migrate' <<<"$output"
[ "$before" = "$(sha256sum "$root/connectors/mesh/node-token" "$root/leaked-token-link")" ]
test ! -e "$root/secrets/leaked-token-link"
# Replacing the backup path after its first validation must be caught before archive access.
root="$FIXTURE/backup-swap"
mkdir -p "$root/connectors"
printf 'private-connector-state\n' > "$root/connectors/private"
printf 'interim-state\n' > "$root/new-state"
cat > "$FIXTURE/fault-runner.py" <<'PY'
import importlib.util
from pathlib import Path
spec=importlib.util.spec_from_file_location('state_migrate','/opt/lnswitchboard/state-migrate.py')
module=importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
original=module.validate_reserved_paths
swapped=False
def validate_then_swap():
    global swapped
    original()
    if not swapped:
        swapped=True
        module.BACKUP.symlink_to('/app-data/connectors')
module.validate_reserved_paths=validate_then_swap
module.main()
PY
before_connector=$(sha256sum "$root/connectors/private")
set +e
output=$(docker run --rm --platform linux/arm64 --user 0:0 --network none --read-only \
  --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
  --security-opt no-new-privileges:true \
  --tmpfs /tmp:size=16m,mode=0700 --tmpfs /app-data/connectors:size=64k,mode=000 \
  -v "$root:/app-data" \
  -v "$PACKAGE_DIR/hooks/state-migrate.py:/opt/lnswitchboard/state-migrate.py:ro" \
  -v "$FIXTURE/fault-runner.py:/fault-runner.py:ro" \
  --entrypoint python "$APP_IMAGE" /fault-runner.py 2>&1)
status=$?
set -e
[ "$status" -ne 0 ]
grep -Eq 'reserved backup path (has an unexpected type|changed during migration)' <<<"$output"
[ "$before_connector" = "$(sha256sum "$root/connectors/private")" ]
test -f "$root/new-state"
test ! -e "$root/.lnswitchboard-state-migration-v1.json"
echo 'GREEN migrator_trust_boundaries_fail_closed'
