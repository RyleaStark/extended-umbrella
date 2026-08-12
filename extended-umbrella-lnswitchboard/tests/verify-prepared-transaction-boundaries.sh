#!/usr/bin/env bash
set -euo pipefail
PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc23@sha256:3da255d3163581809d5ad58b813de316de82e77a4e93cb997386fef14ced58f9'
FIXTURE=$(mktemp -d)
cleanup() {
  docker run --rm -v "$FIXTURE:/fixture" \
    alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 \
    sh -c 'rm -rf /fixture/*' >/dev/null 2>&1 || true
  rm -rf "$FIXTURE"
}
trap cleanup EXIT
mkdir -p "$FIXTURE/base/data"
chmod 0777 "$FIXTURE/base/data"
docker run --rm -i --user 1000:1000 -v "$FIXTURE/base/data:/state" "$APP_IMAGE" python - <<'PY'
from pathlib import Path
from backend.app.connection_secret_store import ConnectionSecretStore
store=ConnectionSecretStore(Path('/state/lnswitchboard.db'), Path('/state/connection-secrets.key'))
store.set('provider', {'token':'transaction-bound-secret'})
PY
cat > "$FIXTURE/fault-runner.py" <<'PY'
from __future__ import annotations
import importlib.util
import os
import sys
from pathlib import Path

case=sys.argv[1]
spec=importlib.util.spec_from_file_location('state_migrate_under_fault', '/opt/state-migrate.py')
module=importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

if case.startswith('marker_') or case.startswith('final_marker_'):
    original=os.replace
    count=0
    target_count=1 if case.startswith('marker_') else 2
    after=case.endswith('_after')
    def replace(source, destination):
        global count
        if Path(destination) == module.MARKER:
            count += 1
            if count == target_count and not after:
                raise OSError('injected marker-before fault')
            result=original(source, destination)
            if count == target_count and after:
                raise OSError('injected marker-after fault')
            return result
        return original(source, destination)
    module.os.replace=replace
else:
    original=module.rename_noreplace
    fired=False
    after=case == 'archive_after'
    def rename(source, destination):
        global fired
        source=Path(source); destination=Path(destination)
        is_archive=(source.parent == module.ROOT and destination.parent == module.BACKUP)
        if is_archive and not fired:
            fired=True
            if not after:
                raise OSError('injected archive-before fault')
            result=original(source, destination)
            raise OSError('injected archive-after fault')
        return original(source, destination)
    module.rename_noreplace=rename
module.main()
PY
run_migrator() {
  local data=$1 runner=${2:-/opt/state-migrate.py} case=${3:-}
  docker run --rm --network none --read-only --user 0:0 \
    --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
    --security-opt no-new-privileges:true \
    --tmpfs /tmp:rw,nosuid,nodev,noexec,mode=1777 \
    --tmpfs /app-data/connectors:rw,nosuid,nodev,noexec,mode=000 \
    -v "$data:/app-data" \
    -v "$PACKAGE_DIR/hooks/state-migrate.py:/opt/state-migrate.py:ro" \
    -v "$FIXTURE/fault-runner.py:/runner.py:ro" \
    "$APP_IMAGE" python "$runner" ${case:+"$case"}
}
for case in marker_before marker_after archive_before archive_after final_marker_before final_marker_after; do
  data="$FIXTURE/$case/data"
  mkdir -p "$FIXTURE/$case"
  cp -a "$FIXTURE/base/data" "$data"
  set +e
  output=$(run_migrator "$data" /runner.py "$case" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ]
  grep -q 'injected' <<<"$output"
  if [[ "$case" == marker_before || "$case" == marker_after ]]; then
    docker run --rm -i --user 0:0 -v "$data:/app-data:ro" "$APP_IMAGE" python - "$case" <<'PY'
import json
from pathlib import Path
import sys
root=Path('/app-data')
case=sys.argv[1]
# A prepared manifest must be durable before the first canonical credential
# entry is committed. Both original authorities remain untouched here.
assert not (root/'secrets'/'lnswitchboard.db').exists(), case
assert not (root/'secrets'/'connection-secrets.key').exists(), case
assert (root/'lnswitchboard.db').is_file(), case
assert (root/'connection-secrets.key').is_file(), case
marker=root/'.lnswitchboard-state-migration-v1.json'
temporary=root/'.lnswitchboard-state-migration-v1.tmp'
if case == 'marker_before':
    assert not marker.exists(), case
    assert temporary.is_file(), case
else:
    payload=json.loads(marker.read_text())
    assert payload['schema'] == 2 and payload['phase'] == 'prepared', payload
PY
  fi
  run_migrator "$data" >/dev/null
  docker run --rm -i --user 1000:1000 -v "$data/secrets:/state" "$APP_IMAGE" python - <<'PY'
from pathlib import Path
from backend.app.connection_secret_store import ConnectionSecretStore
value=ConnectionSecretStore(Path('/state/lnswitchboard.db'), Path('/state/connection-secrets.key')).get('provider')
assert value == {'token':'transaction-bound-secret'}, value
PY
  docker run --rm -i --user 0:0 -v "$data:/app-data:ro" "$APP_IMAGE" python - <<'PY'
import json
from pathlib import Path
root=Path('/app-data')
marker=json.loads((root/'.lnswitchboard-state-migration-v1.json').read_text())
assert marker['schema'] == 2 and marker['phase'] == 'complete', marker
assert set(marker['managed_entries']) == {
    'connection-secrets.key', 'lnswitchboard.db', 'lnswitchboard.db-journal'
}, marker
for name, record in marker['authorities'].items():
    path=root/'.lnswitchboard-state-backup-v1'/record['archive_name']
    assert path.exists(), (name, record)
assert (root/'connection-secrets.key').is_symlink()
assert (root/'lnswitchboard.db').is_symlink()
assert not (root/'lnswitchboard.db-journal').exists()
assert not (root/'lnswitchboard.db-journal').is_symlink()
PY
  printf 'GREEN prepared_transaction_recovers_%s\n' "$case"
done
recovery_data="$FIXTURE/final_marker_after/data"
docker run --rm -v "$recovery_data:/app-data" \
  alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 \
  sh -c 'rm -rf /app-data/secrets /app-data/connection-secrets.key /app-data/lnswitchboard.db /app-data/lnswitchboard.db-journal'
run_migrator "$recovery_data" >/dev/null
docker run --rm -i --user 1000:1000 -v "$recovery_data/secrets:/state" "$APP_IMAGE" python - <<'PY'
from pathlib import Path
from backend.app.connection_secret_store import ConnectionSecretStore
value=ConnectionSecretStore(Path('/state/lnswitchboard.db'), Path('/state/connection-secrets.key')).get('provider')
assert value == {'token':'transaction-bound-secret'}, value
PY
printf 'GREEN completed_manifest_recovers_bound_database_and_key\n'
docker run --rm -i --user 0:0 \
  -v "$PACKAGE_DIR/hooks/state-migrate.py:/opt/state-migrate.py:ro" \
  "$APP_IMAGE" python - <<'PY'
import copy
import importlib.util
spec=importlib.util.spec_from_file_location('state_migrate_marker_validation', '/opt/state-migrate.py')
module=importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
base={
    'schema':2,
    'transaction_id':'0'*32,
    'phase':'prepared',
    'managed_entries':['lnswitchboard.db'],
    'migrated_entries':['lnswitchboard.db'],
    'authorities':{
        'lnswitchboard.db':{
            'archive_name':'lnswitchboard.db',
            'sha256':'0'*64,
            'temp_name':'.txn-'+'0'*32+'-0.tmp',
        },
    },
    'archives':{},
}
cases=[]
state=copy.deepcopy(base)
state['managed_entries']=state['migrated_entries']=['..']
state['authorities']={'..': state['authorities']['lnswitchboard.db']}
cases.append(state)
archive=copy.deepcopy(base)
archive['authorities']['lnswitchboard.db']['archive_name']='..'
cases.append(archive)
temporary=copy.deepcopy(base)
temporary['authorities']['lnswitchboard.db']['temp_name']='..'
cases.append(temporary)
for payload in cases:
    try:
        module.validate_transaction_marker(payload)
    except SystemExit as exc:
        assert exc.code == 65, exc.code
    else:
        raise AssertionError(payload)
PY
printf 'GREEN transaction_marker_rejects_dotdot_path_components\n'
printf 'GREEN prepared_transaction_all_commit_archive_marker_boundaries\n'
