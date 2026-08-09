#!/usr/bin/env bash
set -euo pipefail
PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc21@sha256:36d07b3f077b29f923a91a7a6b071c5a0c98b928d239e140902c941764f0f765'
docker run --rm --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges:true \
  -v "$PACKAGE_DIR/hooks/state-migrate.py:/opt/state-migrate.py:ro" \
  --entrypoint python -i "$APP_IMAGE" <<'PY'
from __future__ import annotations
import copy
import importlib.util
spec=importlib.util.spec_from_file_location('state_migrate_marker_namespace','/opt/state-migrate.py')
module=importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
tx='1'*32
base={
 'schema':2,'transaction_id':tx,'phase':'prepared',
 'managed_entries':['a','b'],'migrated_entries':['a','b'],
 'authorities':{
  'a':{'archive_name':'a','sha256':'a'*64,'temp_name':f'.txn-{tx}-0.tmp'},
  'b':{'archive_name':'b','sha256':'b'*64,'temp_name':f'.txn-{tx}-1.tmp'},
 },'archives':{},
}
cases=[]
p=copy.deepcopy(base);p['authorities']['b']['archive_name']='a';cases.append(p)
p=copy.deepcopy(base);p['authorities']['b']['temp_name']=p['authorities']['a']['temp_name'];cases.append(p)
p=copy.deepcopy(base);p['authorities']['a']['temp_name']='a';cases.append(p)
p=copy.deepcopy(base);p['authorities']['a']['temp_name']='b';cases.append(p)
p=copy.deepcopy(base);p['archives']={'legacy':{'archive_name':p['authorities']['a']['temp_name'],'sha256':'c'*64}};cases.append(p)
p=copy.deepcopy(base);p['authorities']['a']['temp_name']='unbound.tmp';cases.append(p)
for payload in cases:
 try:
  module.validate_transaction_marker(payload)
 except SystemExit as exc:
  assert exc.code==65
 else:
  raise AssertionError('malformed control namespace was accepted')
try:
 module.unique_json_object([('authorities',{}),('authorities',{})])
except ValueError:
 pass
else:
 raise AssertionError('duplicate JSON object keys were accepted')
print('MARKER_NAMESPACE_REJECTIONS',len(cases)+1)
PY
printf 'GREEN marker_control_names_are_globally_bound_and_disjoint\n'
