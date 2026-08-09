#!/usr/bin/env bash
set -euo pipefail
PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MESH_IMAGE='cloudflare/mesh:2026.7.0@sha256:18fad6d500e8ca48b7e4d5ae1905d65e8a50c1f5f5e21eba020d54d5cbf82571'
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT
mkdir "$FIXTURE/token"
printf 'MESH_NODE_TOKEN=fixture-not-a-secret\n' > "$FIXTURE/token/node.env"
chmod 0750 "$FIXTURE/token"
chmod 0640 "$FIXTURE/token/node.env"
group_id=$(python3 - "$PACKAGE_DIR/docker-compose.yml" <<'PY'
import sys, yaml
compose=yaml.safe_load(open(sys.argv[1], encoding='utf-8'))
groups=compose['services']['cloudflare-mesh'].get('group_add', [])
assert len(groups) == 1
print(groups[0])
PY
)
[ "$group_id" = '1000' ]
docker run --rm --platform linux/arm64 \
  --network none \
  --user 0:0 \
  --group-add "$group_id" \
  --cap-drop ALL \
  -v "$FIXTURE/token:/run/lnswitchboard:ro" \
  --entrypoint sh "$MESH_IMAGE" \
  -c '. /run/lnswitchboard/node.env; test "$MESH_NODE_TOKEN" = fixture-not-a-secret'
echo 'GREEN mesh_reads_uid1000_token_with_declared_group'
