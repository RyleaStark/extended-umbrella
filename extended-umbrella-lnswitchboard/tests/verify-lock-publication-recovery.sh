#!/usr/bin/env bash
set -euo pipefail
PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc26@sha256:f23473b8d89cb8b1eb521ba873ec2104a941788af74593f12e175693db78bf4d'
FIXTURE=$(mktemp -d)
cleanup() {
  docker run --rm -v "$FIXTURE:/fixture" alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 sh -c 'rm -rf /fixture/* /fixture/.[!.]* /fixture/..?*' >/dev/null 2>&1 || true
  rmdir "$FIXTURE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cat > "$FIXTURE/fault.py" <<'PY'
from __future__ import annotations
import importlib.util
import os
import sys
case = sys.argv[1]
spec = importlib.util.spec_from_file_location('state_migrate_lock_fault', '/opt/state-migrate.py')
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
original_write = module.os.write
triggered = False
def write(fd: int, payload: bytes) -> int:
    global triggered
    if not triggered:
        triggered = True
        if case == 'before_write':
            os._exit(77)
        original_write(fd, payload[:8])
        os._exit(77)
    return original_write(fd, payload)
module.os.write = write
module.main()
PY
for case in before_write partial_write; do
  root="$FIXTURE/$case"
  mkdir -p "$root"
  chmod 0775 "$root"
  status=0
  docker run --rm --user 0:0 --network none --read-only --cap-drop ALL \
    --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
    --security-opt no-new-privileges:true \
    -v "$root:/app-data" -v "$PACKAGE_DIR/hooks/state-migrate.py:/opt/state-migrate.py:ro" \
    -v "$FIXTURE/fault.py:/fault.py:ro" --entrypoint python "$APP_IMAGE" \
    /fault.py "$case" || status=$?
  [ "$status" = 77 ]
  [ ! -e "$root/.lnswitchboard-state-lock-v1.json" ]
  [ -f "$root/.lnswitchboard-state-lock-v1.tmp" ]
  [ "$(stat -c '%u:%g:%a' "$root/.lnswitchboard-state-lock-v1.tmp")" = '0:0:600' ]
  for rerun in 1 2; do
    docker run --rm --user 0:0 --network none --read-only --cap-drop ALL \
      --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
      --security-opt no-new-privileges:true \
      -v "$root:/app-data" -v "$PACKAGE_DIR/hooks/state-migrate.py:/opt/state-migrate.py:ro" \
      --entrypoint python "$APP_IMAGE" /opt/state-migrate.py
  done
  [ ! -e "$root/.lnswitchboard-state-lock-v1.json" ]
  [ ! -e "$root/.lnswitchboard-state-lock-v1.tmp" ]
  printf 'LOCK_RECOVERY_PASS case=%s\n' "$case"
done
printf 'GREEN lock_publication_recovers_after_before_and_partial_write_death\n'
