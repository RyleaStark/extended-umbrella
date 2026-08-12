#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc23@sha256:3da255d3163581809d5ad58b813de316de82e77a4e93cb997386fef14ced58f9'
ALPINE='alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1'
FIXTURE=$(mktemp -d)
ROOT="$FIXTURE/state"
cleanup() {
  docker run --rm -v "$FIXTURE:/fixture" "$ALPINE" \
    sh -c 'rm -rf /fixture/* /fixture/.[!.]* /fixture/..?*' >/dev/null 2>&1 || true
  rmdir "$FIXTURE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
mkdir -p "$ROOT/proxy-config"
chmod 0777 "$ROOT"

docker run --rm -v "$ROOT/proxy-config:/proxy" "$ALPINE" \
  sh -c 'chown 0:0 /proxy && chmod 0755 /proxy'

migrate() {
  docker run --rm --user 0:0 --network none --read-only \
    --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
    --security-opt no-new-privileges:true \
    --tmpfs /tmp:size=16m,mode=0700 \
    --tmpfs /app-data/connectors:size=64k,mode=000 \
    -v "$ROOT:/app-data" \
    -v "$ROOT:/host-view:ro" \
    -v "$PACKAGE_DIR/hooks/state-migrate.py:/opt/state-migrate.py:ro" \
    --entrypoint python "$APP_IMAGE" /opt/state-migrate.py
}

docker run --rm -v "$ROOT/proxy-config:/proxy" "$ALPINE" \
  sh -c "printf 'LOG_LEVEL=silent\\nPROXY_AUTH_WHITELIST=\\n' > /proxy/.app-proxy.env.tmp.123; printf 'LOG_LEVEL=silent\\n' > /proxy/app-proxy.env.tmp; chown 0:0 /proxy/.app-proxy.env.tmp.123 /proxy/app-proxy.env.tmp; chmod 0444 /proxy/.app-proxy.env.tmp.123; chmod 0600 /proxy/app-proxy.env.tmp"
migrate >/dev/null
test ! -e "$ROOT/proxy-config/.app-proxy.env.tmp.123"
test ! -e "$ROOT/proxy-config/app-proxy.env.tmp"
printf 'GREEN proxy_publication_recovery_removes_owned_complete_and_partial_temporaries\n'

printf 'outside-sentinel\n' > "$FIXTURE/outside"
outside_before=$(sha256sum "$FIXTURE/outside" | cut -d' ' -f1)
docker run --rm -v "$ROOT/proxy-config:/proxy" "$ALPINE" \
  ln -s "$FIXTURE/outside" /proxy/.app-proxy.env.tmp.124
status=0
output=$(migrate 2>&1) || status=$?
[ "$status" = 65 ]
grep -q 'App Proxy publication temporary has unsafe metadata' <<<"$output"
outside_after=$(sha256sum "$FIXTURE/outside" | cut -d' ' -f1)
[ "$outside_before" = "$outside_after" ]
docker run --rm -v "$ROOT/proxy-config:/proxy" "$ALPINE" rm /proxy/.app-proxy.env.tmp.124
printf 'GREEN proxy_publication_recovery_rejects_symlink_without_outside_mutation\n'

docker run --rm -v "$ROOT/proxy-config:/proxy" "$ALPINE" \
  sh -c "printf 'untrusted-content\\n' > /proxy/.app-proxy.env.tmp.125; chown 0:0 /proxy/.app-proxy.env.tmp.125; chmod 0444 /proxy/.app-proxy.env.tmp.125"
bad_before=$(sha256sum "$ROOT/proxy-config/.app-proxy.env.tmp.125" | cut -d' ' -f1)
status=0
output=$(migrate 2>&1) || status=$?
[ "$status" = 65 ]
grep -q 'App Proxy publication temporary has unexpected content' <<<"$output"
bad_after=$(sha256sum "$ROOT/proxy-config/.app-proxy.env.tmp.125" | cut -d' ' -f1)
[ "$bad_before" = "$bad_after" ]
docker run --rm -v "$ROOT/proxy-config:/proxy" "$ALPINE" rm /proxy/.app-proxy.env.tmp.125
printf 'GREEN proxy_publication_recovery_rejects_untrusted_content_without_mutation\n'

docker run --rm -v "$ROOT/proxy-config:/proxy" "$ALPINE" \
  sh -c "printf 'LOG_LEVEL=silent\\n' > /proxy/.app-proxy.env.tmp.126; chown 0:0 /proxy/.app-proxy.env.tmp.126; chmod 0444 /proxy/.app-proxy.env.tmp.126; ln /proxy/.app-proxy.env.tmp.126 /proxy/app-proxy.env.tmp.alias"
status=0
output=$(migrate 2>&1) || status=$?
[ "$status" = 65 ]
grep -q 'App Proxy publication temporary has unsafe metadata' <<<"$output"
printf 'GREEN proxy_publication_recovery_rejects_hardlinked_temporary\n'

docker run --rm --user 0:0 --network none --read-only --cap-drop ALL \
  --cap-add DAC_OVERRIDE --security-opt no-new-privileges:true \
  --tmpfs /tmp:size=16m,mode=0700 -v "$FIXTURE:/fixture" \
  -v "$PACKAGE_DIR/hooks/state-migrate.py:/opt/state-migrate.py:ro" \
  -v "$PACKAGE_DIR/tests/probes/proxy-retirement-race.py:/opt/probe.py:ro" \
  --entrypoint python "$APP_IMAGE" /opt/probe.py
