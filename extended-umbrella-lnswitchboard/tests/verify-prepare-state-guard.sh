#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc29@sha256:c9ffacd79b51f75f18dbf6eca238fad660f3fe264a1176ae5d3953f6d4758a24'
FIXTURE=$(mktemp -d)
cleanup() {
  docker run --rm -v "$FIXTURE:/fixture" \
    alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1 \
    sh -c 'rm -rf /fixture/* /fixture/.[!.]* /fixture/..?*' >/dev/null 2>&1 || true
  rmdir "$FIXTURE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

HOST="$FIXTURE/host"
OUTSIDE="$FIXTURE/outside"
mkdir -p \
  "$HOST/secrets/tailscale" \
  "$HOST/connectors/cloudflare-mesh" \
  "$HOST/connectors/cloudflare-mesh-state" \
  "$HOST/connectors/tailscale" \
  "$HOST/secrets/zrok" \
  "$HOST/connectors/zrok" \
  "$HOST/public-backend" \
  "$HOST/proxy-config" \
  "$OUTSIDE"
printf 'outside-sentinel\n' > "$OUTSIDE/sentinel"
outside_before=$(sha256sum "$OUTSIDE/sentinel" | cut -d' ' -f1)

run_guard() {
  local secrets_source=$1
  docker run --rm --network none --read-only --user 0:0 \
    --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
    --security-opt no-new-privileges:true \
    -v "$HOST:/host-view:ro" \
    -v "$secrets_source:/app-secrets" \
    -v "$HOST/connectors/cloudflare-mesh:/app-secrets/cloudflare-mesh" \
    -v "$HOST/secrets/tailscale:/tailscale-control" \
    -v "$HOST/connectors/tailscale:/tailscale-state" \
    -v "$HOST/secrets/zrok:/zrok-control" \
    -v "$HOST/connectors/zrok:/zrok-state" \
    -v "$HOST/public-backend:/public-socket" \
    -v "$HOST/proxy-config:/proxy-config" \
    -v "$HOST/connectors/cloudflare-mesh-state:/cloudflare-mesh-state" \
    -v "$PACKAGE_DIR/hooks/prepare-state-guard.py:/opt/lnswitchboard/prepare-state-guard.py:ro" \
    --entrypoint python "$APP_IMAGE" /opt/lnswitchboard/prepare-state-guard.py
}

status=0
output=$(run_guard "$OUTSIDE" 2>&1) || status=$?
[ "$status" = 65 ]
grep -q 'writable state mount does not match its validated host source' <<<"$output"
outside_after=$(sha256sum "$OUTSIDE/sentinel" | cut -d' ' -f1)
[ "$outside_before" = "$outside_after" ]
test ! -e "$HOST/proxy-config/app-proxy.env"
printf 'GREEN prepare_state_guard_rejects_bind_source_identity_mismatch\n'

ln -s "$OUTSIDE/sentinel" "$HOST/proxy-config/app-proxy.env"
status=0
output=$(run_guard "$HOST/secrets" 2>&1) || status=$?
[ "$status" = 65 ]
grep -q 'App Proxy configuration path has an unexpected type' <<<"$output"
outside_after=$(sha256sum "$OUTSIDE/sentinel" | cut -d' ' -f1)
[ "$outside_before" = "$outside_after" ]
test -L "$HOST/proxy-config/app-proxy.env"
printf 'GREEN prepare_state_guard_rejects_proxy_symlink_without_outside_mutation\n'
