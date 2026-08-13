#!/usr/bin/env bash
set -euo pipefail
PACKAGE_DIR=$(cd "$(dirname "$0")/.." && pwd)
PACKAGE_DIR="$PACKAGE_DIR" python3 - <<'PY'
import os, pathlib, yaml
p=pathlib.Path(os.environ['PACKAGE_DIR'])
c=yaml.safe_load((p/'docker-compose.yml').read_text())
z=c['services']['zrok']; public=c['services']['lnswitchboard-public']; admin=c['services']['lnswitchboard']
assert z['image']=='openziti/zrok2:2.0.4@sha256:310ab634172ce03dd23ff1ee8515195e1a564197dbc4e6cdfd57dad2fb822400'
assert z['user']=='1000:1000' and z['read_only'] is True and z['cap_drop']==['ALL']
assert z['security_opt']==['no-new-privileges:true']
assert z['networks']==['zrok-public']
assert 'zrok-public' in public['networks']
assert 'zrok-public' not in admin.get('networks', {})
assert '${APP_DATA_DIR}/data/connectors/zrok:/var/lib/zrok' in z['volumes']
assert '${APP_DATA_DIR}/data/secrets/zrok:/run/lnswitchboard' in z['volumes']
for forbidden in ('/app/secrets/lnswitchboard.db','connection-secrets.key','/lnd/','cloudflare-mesh','tailscale'):
    assert forbidden not in str(z)
script=(p/'hooks/zrok-supervisor.sh').read_text()
assert 'DEP_ENV' in script
assert 'UMBREL_DEV) PUBLIC_HOST=extended-umbrella-lnswitchboard_public' in script
assert z['environment']['DEP_ENV'] == 'UMBREL_DEV'
assert ':22121' not in script
assert 'ZROK2_API_ENDPOINT="$endpoint"' in script
assert '--open --subordinate --force-local' in script
assert '--headless --subordinate' not in script
assert 'operation_id' in script
assert 'share_token' in script
assert 'chmod 600 "$tmp"' in script
assert 'trap shutdown TERM INT' in script
assert '"https://" + ascii_downcase' in script
print('GREEN zrok connector authority contract')
PY
bash -n "$PACKAGE_DIR/hooks/zrok-supervisor.sh"
