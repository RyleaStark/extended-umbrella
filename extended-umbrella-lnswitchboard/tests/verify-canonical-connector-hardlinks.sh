#!/usr/bin/env bash
set -euo pipefail
PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc35@sha256:7d0faaff3c270e2cc6ffe0a91b0da852e5c04d36537e2dc62be20350d5a50fab'
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
