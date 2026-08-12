#!/usr/bin/env bash
set -euo pipefail
umask 027
CONTROL=${ZROK_CONTROL_DIR:-/run/lnswitchboard/control}
STATUS=${ZROK_STATUS_DIR:-/run/lnswitchboard/status}
TARGET=http://public:21212
mkdir -p "$STATUS"
share_pid=
operation_id=recovery
atomic_status() {
  local state=$1 payload=${2:-'{}'} tmp="$STATUS/.status.json.tmp.$$"
  jq -cn --arg state "$state" --arg operation_id "$operation_id" --argjson payload "$payload" \
    '$payload + {state:$state,operation_id:$operation_id}' >"$tmp"
  chmod 640 "$tmp"
  mv -f "$tmp" "$STATUS/status.json"
}
stop_share() {
  if [ -n "${share_pid:-}" ]; then
    kill "$share_pid" 2>/dev/null || true
    wait "$share_pid" 2>/dev/null || true
    share_pid=
  fi
}
shutdown() { stop_share; exit 0; }
disconnect() {
  operation_id=$(cat "$CONTROL/disconnect")
  rm -f "$CONTROL/disconnect"
  stop_share
  zrok2 disable >/dev/null 2>&1 || true
  rm -f "$CONTROL/configure.json" "$CONTROL/active.json"
  atomic_status disconnected
}
enabled() { zrok2 status 2>/dev/null | grep -q 'EnvZId.*<<SET>>'; }
start_share() {
  local namespace=$1 name=$2 fifo deadline
  stop_share
  rm -f "$STATUS/status.json"
  fifo="$STATUS/share.$$"
  mkfifo -m 600 "$fifo"
  (
    first=1
    while IFS= read -r boot; do
      if [ "$first" = 1 ]; then
        first=0
        if jq -e '.msg=="boot" and (.token|type=="string") and (.frontend_endpoints|type=="array")' <<<"$boot" >/dev/null; then
          atomic_status connected "$(jq -c '{frontend_endpoints:.frontend_endpoints}' <<<"$boot")"
        else
          atomic_status error
        fi
      fi
    done <"$fifo"
  ) &
  local drain_pid=$!
  zrok2 share public "$TARGET" --backend-mode proxy --open --subordinate --force-local -n "$namespace:$name" >"$fifo" 2>/dev/null &
  share_pid=$!
  deadline=$((SECONDS + 30))
  while [ "$SECONDS" -lt "$deadline" ] && [ ! -s "$STATUS/status.json" ]; do sleep 1; done
  rm -f "$fifo"
  if [ ! -s "$STATUS/status.json" ]; then
    kill "$drain_pid" 2>/dev/null || true
    atomic_status error
    return 1
  fi
}
configure() {
  local cfg=$CONTROL/configure.json endpoint token namespace name
  operation_id=$(jq -er '.operation_id' "$cfg")
  endpoint=$(jq -er '.api_endpoint' "$cfg")
  token=$(jq -er '.account_token' "$cfg")
  namespace=$(jq -er '.namespace' "$cfg")
  name=$(jq -er '.name' "$cfg")
  rm -f "$cfg"
  stop_share
  if enabled; then zrok2 disable >/dev/null 2>&1 || true; fi
  ZROK2_API_ENDPOINT="$endpoint" zrok2 enable --headless --description lnswitchboard "$token" >/dev/null 2>&1
  token=
  zrok2 create name -n "$namespace" "$name" >/dev/null 2>&1 || true
  start_share "$namespace" "$name"
  printf '{"namespace":%s,"name":%s}\n' "$(jq -Rn --arg value "$namespace" '$value')" "$(jq -Rn --arg value "$name" '$value')" >"$CONTROL/.active.json.tmp.$$"
  chmod 640 "$CONTROL/.active.json.tmp.$$"
  mv -f "$CONTROL/.active.json.tmp.$$" "$CONTROL/active.json"
}
refresh() {
  operation_id=$(cat "$CONTROL/refresh")
  rm -f "$CONTROL/refresh"
  if [ -n "${share_pid:-}" ] && kill -0 "$share_pid" 2>/dev/null && [ -s "$STATUS/status.json" ]; then
    atomic_status refresh_complete "$(jq -c 'del(.state,.operation_id)' "$STATUS/status.json")"
  else
    atomic_status error
  fi
}
trap shutdown EXIT TERM INT
if [ -f "$CONTROL/active.json" ] && enabled; then
  namespace=$(jq -er '.namespace' "$CONTROL/active.json")
  name=$(jq -er '.name' "$CONTROL/active.json")
  start_share "$namespace" "$name" || atomic_status error
fi
while true; do
  if [ -f "$CONTROL/disconnect" ]; then disconnect || atomic_status error
  elif [ -f "$CONTROL/configure.json" ]; then configure || atomic_status error
  elif [ -f "$CONTROL/refresh" ]; then refresh
  fi
  sleep 1
done
