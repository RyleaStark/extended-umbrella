#!/usr/bin/env bash
set -euo pipefail
PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc39@sha256:5cb80b766a02604ac5f190b35515a58d88a082e356676fa6e226b2e379bcf237'
docker run --rm --user 0:0 --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges:true --tmpfs /fixture:size=16m,mode=0700 \
  -v "$PACKAGE_DIR/hooks/state-migrate.py:/opt/state-migrate.py:ro" \
  --entrypoint python -i "$APP_IMAGE" <<'PY'
from __future__ import annotations
import importlib.util
from pathlib import Path
spec=importlib.util.spec_from_file_location('state_migrate_connector_links','/opt/state-migrate.py')
module=importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
canonical=Path('/fixture/secrets')
operations=canonical/'tailscale'/'control'/'operations'
queue=canonical/'tailscale'/'control'/'queue'
operations.mkdir(parents=True)
queue.mkdir(parents=True)
operation=operations/('a'*32+'.json')
operation.write_text('{"command":"enable"}\n',encoding='utf-8')
(queue/operation.name).hardlink_to(operation)
module.CANONICAL=canonical
module.validate_canonical_tree()
owned=canonical/'lnswitchboard.db'
owned.write_bytes(b'app-state')
(canonical/'unexpected-alias').hardlink_to(owned)
try:
 module.validate_canonical_tree()
except SystemExit as exc:
 assert exc.code==65
else:
 raise AssertionError('hard-linked application-owned canonical state was accepted')
print('GREEN connector protocol hardlinks isolated from migration state validation')
PY

FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/secrets/tailscale/control/operations" \
  "$FIXTURE/secrets/tailscale/control/queue" "$FIXTURE/secrets/tailscale/status" \
  "$FIXTURE/tailscale-state" "$FIXTURE/secrets/zrok" "$FIXTURE/zrok-state" \
  "$FIXTURE/public-socket" "$FIXTURE/secrets/cloudflare-mesh"
operation="$FIXTURE/secrets/tailscale/control/operations/$(printf 'b%.0s' {1..32}).json"
printf '%s\n' '{"command":"enable"}' > "$operation"
chmod 600 "$operation"
ln "$operation" "$FIXTURE/secrets/tailscale/control/queue/$(basename "$operation")"
docker run --rm --user 0:0 --network none --read-only --cap-drop ALL \
  --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
  --security-opt no-new-privileges:true \
  -v "$FIXTURE/secrets:/app-secrets" \
  -v "$FIXTURE/secrets/tailscale:/tailscale-control" \
  -v "$FIXTURE/tailscale-state:/tailscale-state" \
  -v "$FIXTURE/secrets/zrok:/zrok-control" \
  -v "$FIXTURE/zrok-state:/zrok-state" \
  -v "$FIXTURE/public-socket:/public-socket" \
  --entrypoint /usr/local/bin/lnswitchboard-prepare-state "$APP_IMAGE"
[ "$(stat -c %h "$operation")" = 2 ]
[ "$(stat -c %a "$operation")" = 600 ]
printf 'GREEN exact_rc39_initializer_preserves_connector_protocol_hardlinks\n'
