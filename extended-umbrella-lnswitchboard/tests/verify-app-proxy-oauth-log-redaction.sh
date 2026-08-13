#!/usr/bin/env bash
set -euo pipefail
PROXY_IMAGE='getumbrel/app-proxy:1.7.0@sha256:ec0de0b944a2e63d52fdd82b3760d90a35f8b442d17a8407afdee3af3e842d5a'
ALPINE_IMAGE='alpine:3.22.1@sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1'
APP_IMAGE='ghcr.io/ryleastark/lnswitchboard:0.4.0.rc30@sha256:27323c9b90dccde55f235ce66fc99526a0e0c1646409dbe7d4888d3ab43cf568'
FIXTURE=$(mktemp -d)
NETWORK="lns-proxy-privacy-${RANDOM}-$$"
BACKEND="${NETWORK}-backend"
PROXY="${NETWORK}-proxy"
cleanup() {
  docker rm -f "$PROXY" "$BACKEND" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  rm -rf "$FIXTURE"
}
trap cleanup EXIT
cat > "$FIXTURE/umbrel-app.yml" <<'YAML'
manifestVersion: 1
id: extended-umbrella-lnswitchboard
name: lnSwitchboard
YAML
mkdir -p "$FIXTURE/app-data/proxy-config"
printf 'LOG_LEVEL=silent\nPROXY_AUTH_WHITELIST=\n' > "$FIXTURE/app-data/proxy-config/app-proxy.env"
chmod 0444 "$FIXTURE/app-data/proxy-config/app-proxy.env"
docker network create "$NETWORK" >/dev/null
docker run -d --name "$BACKEND" --network "$NETWORK" --network-alias backend \
  "$APP_IMAGE" python -m http.server 18080 --directory /tmp >/dev/null
docker run -d --name "$PROXY" --network "$NETWORK" -p 127.0.0.1::4000 \
  --user 1000:1000 \
  -e APP_HOST=backend -e APP_PORT=18080 -e PROXY_PORT=4000 \
  -e LOG_LEVEL=info \
  -e PROXY_AUTH_WHITELIST= \
  -e CUSTOM_DOTENV_FILE=/data/proxy-config/app-proxy.env \
  -e JWT_SECRET=fixture-jwt-secret -e UMBREL_AUTH_SECRET=fixture-auth-secret \
  -e MANAGER_IP=127.0.0.1 \
  -e APP_MANIFEST_FILE=/extra/umbrel-app.yml \
  -v "$FIXTURE/umbrel-app.yml:/extra/umbrel-app.yml:ro" \
  -v "$FIXTURE/app-data:/data:ro" \
  "$PROXY_IMAGE" >/dev/null
port=$(docker inspect --format '{{(index (index .NetworkSettings.Ports "4000/tcp") 0).HostPort}}' "$PROXY")
ready=0
for _ in $(seq 1 40); do
  if curl -sS --max-time 1 -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null; then ready=1; break; fi
  sleep 0.25
done
if [ "$ready" -ne 1 ]; then
  docker logs "$PROXY" >&2 || true
  exit 1
fi
code='PROXY_CLASSIFIED_OAUTH_CODE_SECRET'
state='PROXY_CLASSIFIED_OAUTH_STATE_SECRET'
curl -sS --max-time 8 -D "$FIXTURE/headers" -o "$FIXTURE/body" \
  -H 'Content-Type: application/json' \
  --data "{\"code\":\"$code\",\"state\":\"$state\"}" \
  "http://127.0.0.1:$port/api/cloudflare/oauth/complete" || true
sleep 0.5
docker logs "$PROXY" > "$FIXTURE/stdout" 2> "$FIXTURE/stderr" || true
for secret in "$code" "$state"; do
  ! grep -Fq "$secret" "$FIXTURE/headers"
  ! grep -Fq "$secret" "$FIXTURE/body"
  ! grep -Fq "$secret" "$FIXTURE/stdout"
  ! grep -Fq "$secret" "$FIXTURE/stderr"
done
grep -qi '^location:' "$FIXTURE/headers"
! grep -Fq '/api/cloudflare/oauth/complete' "$FIXTURE/stdout"
! grep -Fq '/api/cloudflare/oauth/complete' "$FIXTURE/stderr"
printf 'GREEN inherited_app_proxy_keeps_admin_authenticated_and_does_not_log_oauth_body\n'

# Defense in depth only: simulate a future/inherited overlay that accidentally
# re-whitelists the query callback. Even then, the exact silent-log override
# must keep a failed upstream request from persisting or reflecting its query.
docker rm -f "$PROXY" >/dev/null
chmod 0644 "$FIXTURE/app-data/proxy-config/app-proxy.env"
printf 'LOG_LEVEL=silent\nPROXY_AUTH_WHITELIST=/api/cloudflare/oauth/callback\n' > \
  "$FIXTURE/app-data/proxy-config/app-proxy.env"
chmod 0444 "$FIXTURE/app-data/proxy-config/app-proxy.env"
docker run -d --name "$PROXY" --network "$NETWORK" -p 127.0.0.1::4000 \
  --user 1000:1000 \
  -e APP_HOST=backend -e APP_PORT=18080 -e PROXY_PORT=4000 \
  -e LOG_LEVEL=info \
  -e PROXY_AUTH_WHITELIST= \
  -e CUSTOM_DOTENV_FILE=/data/proxy-config/app-proxy.env \
  -e JWT_SECRET=fixture-jwt-secret -e UMBREL_AUTH_SECRET=fixture-auth-secret \
  -e MANAGER_IP=127.0.0.1 \
  -e APP_MANIFEST_FILE=/extra/umbrel-app.yml \
  -v "$FIXTURE/umbrel-app.yml:/extra/umbrel-app.yml:ro" \
  -v "$FIXTURE/app-data:/data:ro" \
  "$PROXY_IMAGE" >/dev/null
port=$(docker inspect --format '{{(index (index .NetworkSettings.Ports "4000/tcp") 0).HostPort}}' "$PROXY")
ready=0
for _ in $(seq 1 40); do
  if curl -sS --max-time 1 -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null; then ready=1; break; fi
  sleep 0.25
done
[ "$ready" -eq 1 ]
docker stop "$BACKEND" >/dev/null
query_code='PROXY_FAILURE_QUERY_CODE_SECRET'
query_state='PROXY_FAILURE_QUERY_STATE_SECRET'
curl -sS --max-time 8 -D "$FIXTURE/failure-headers" -o "$FIXTURE/failure-body" \
  "http://127.0.0.1:$port/api/cloudflare/oauth/callback?code=$query_code&state=$query_state" || true
sleep 0.5
docker logs "$PROXY" > "$FIXTURE/failure-stdout" 2> "$FIXTURE/failure-stderr" || true
for secret in "$query_code" "$query_state"; do
  ! grep -Fq "$secret" "$FIXTURE/failure-headers"
  ! grep -Fq "$secret" "$FIXTURE/failure-body"
  ! grep -Fq "$secret" "$FIXTURE/failure-stdout"
  ! grep -Fq "$secret" "$FIXTURE/failure-stderr"
done
printf 'GREEN app_proxy_silent_override_is_secondary_fail_closed_defense\n'
