#!/usr/bin/env bash
set -euo pipefail
PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT
printf 'staged-bytes' > "$FIXTURE/source"
printf 'concurrent-canonical-bytes' > "$FIXTURE/destination"
python3 - "$PACKAGE_DIR/hooks/state-migrate.py" "$FIXTURE/source" "$FIXTURE/destination" <<'PY'
import importlib.util
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location('state_migrate', sys.argv[1])
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
source = Path(sys.argv[2])
destination = Path(sys.argv[3])
try:
    module.rename_noreplace(source, destination)
except FileExistsError:
    pass
else:
    raise AssertionError('rename_noreplace overwrote an existing destination')
assert source.read_text() == 'staged-bytes'
assert destination.read_text() == 'concurrent-canonical-bytes'
print('GREEN atomic_rename_refuses_existing_destination')
PY
