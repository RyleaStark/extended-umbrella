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
  local state=$1 payload=${2:-'{}'} tmp="$STATUS/.status.json.tmp.${BASHPID}"
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
enabled() { zrok2 status 2>/dev/null | grep -q 'EnvZId.*<<SET>>'; }
share_alive() { [ -n "${share_pid:-}" ] && jobs -pr | grep -qx "$share_pid"; }

name_exists() {
  local namespace=$1 name=$2
  local names
  names=$(zrok2 list names --namespace-token "$namespace" --json 2>/dev/null) || return 2
  jq -e --arg namespace "$namespace" --arg name "$name" \
    'any(.[]; .namespaceToken == $namespace and .name == $name)' <<<"$names" >/dev/null
}

start_share() {
  local namespace=$1 name=$2 fifo deadline state endpoints
  stop_share
  rm -f "$STATUS/status.json"
  fifo="$STATUS/share.$$"
  mkfifo -m 600 "$fifo"
  (
    first=1
    while IFS= read -r boot; do
      if [ "$first" = 1 ]; then
        first=0
        if jq -e '
          .msg == "boot" and
          (.frontend_endpoints | type == "array" and length >= 1 and length <= 8) and
          all(.frontend_endpoints[];
            type == "string" and length >= 1 and length <= 253 and
            test("^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$"))
        ' <<<"$boot" >/dev/null; then
          endpoints=$(jq -c '{frontend_endpoints:[.frontend_endpoints[] | "https://" + ascii_downcase]}' <<<"$boot")
          atomic_status connected "$endpoints"
        else
          atomic_status error
        fi
      fi
    done <"$fifo"
  ) &
  local drain_pid=$!
  zrok2 share public "$TARGET" --backend-mode proxy --open --headless --subordinate --force-local \
    --name-selection "$namespace:$name" >"$fifo" 2>/dev/null &
  share_pid=$!
  deadline=$((SECONDS + 30))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ -s "$STATUS/status.json" ]; then break; fi
    if ! share_alive; then break; fi
    sleep 1
  done
  rm -f "$fifo"
  state=$(jq -r --arg operation_id "$operation_id" 'select(.operation_id == $operation_id) | .state' "$STATUS/status.json" 2>/dev/null || true)
  if [ "$state" != connected ] || ! share_alive; then
    kill "$drain_pid" 2>/dev/null || true
    stop_share
    atomic_status error
    return 1
  fi
}

configure() {
  local cfg=$CONTROL/configure.json payload endpoint token namespace name created=false
  payload=$(cat "$cfg")
  rm -f "$cfg"
  operation_id=$(jq -er '.operation_id | select(type == "string" and length == 32)' <<<"$payload")
  endpoint=$(jq -er '.api_endpoint | select(type == "string")' <<<"$payload")
  token=$(jq -er '.account_token | select(type == "string" and length >= 1 and length <= 4096)' <<<"$payload")
  namespace=$(jq -er '.namespace | select(type == "string")' <<<"$payload")
  name=$(jq -er '.name | select(type == "string")' <<<"$payload")
  payload=
  stop_share
  if enabled; then
    if ! zrok2 disable >/dev/null 2>&1; then
      atomic_status error
      token=
      return 1
    fi
  fi
  if ! ZROK2_API_ENDPOINT="$endpoint" zrok2 enable --headless --description lnswitchboard "$token" >/dev/null 2>&1; then
    token=
    atomic_status error
    return 1
  fi
  token=
  if name_exists "$namespace" "$name"; then
    :
  else
    local name_status=$?
    if [ "$name_status" = 2 ]; then
      zrok2 disable >/dev/null 2>&1 || true
      atomic_status error
      return 1
    fi
    if ! zrok2 create name --namespace-token "$namespace" "$name" >/dev/null 2>&1; then
      zrok2 disable >/dev/null 2>&1 || true
      atomic_status error
      return 1
    fi
    created=true
  fi
  if ! start_share "$namespace" "$name"; then
    if [ "$created" = true ]; then
      zrok2 delete name --namespace-token "$namespace" "$name" >/dev/null 2>&1 || true
    fi
    zrok2 disable >/dev/null 2>&1 || true
    return 1
  fi
  printf '{"namespace":%s,"name":%s}\n' \
    "$(jq -Rn --arg value "$namespace" '$value')" \
    "$(jq -Rn --arg value "$name" '$value')" >"$CONTROL/.active.json.tmp.$$"
  chmod 640 "$CONTROL/.active.json.tmp.$$"
  mv -f "$CONTROL/.active.json.tmp.$$" "$CONTROL/active.json"
}

disconnect() {
  local namespace name
  operation_id=$(cat "$CONTROL/disconnect")
  rm -f "$CONTROL/disconnect"
  namespace=$(jq -er '.namespace' "$CONTROL/active.json") || { atomic_status error; return 1; }
  name=$(jq -er '.name' "$CONTROL/active.json") || { atomic_status error; return 1; }
  stop_share
  if name_exists "$namespace" "$name"; then
    if ! zrok2 delete name --namespace-token "$namespace" "$name" >/dev/null 2>&1; then
      atomic_status error
      return 1
    fi
  else
    local name_status=$?
    if [ "$name_status" = 2 ]; then
      atomic_status error
      return 1
    fi
  fi
  if ! zrok2 disable >/dev/null 2>&1; then
    atomic_status error
    return 1
  fi
  rm -f "$CONTROL/configure.json" "$CONTROL/active.json"
  atomic_status disconnected
}

refresh() {
  operation_id=$(cat "$CONTROL/refresh")
  rm -f "$CONTROL/refresh"
  if share_alive && [ -s "$STATUS/status.json" ]; then
    atomic_status refresh_complete "$(jq -c 'del(.state,.operation_id)' "$STATUS/status.json")"
  else
    atomic_status error
  fi
}

trap shutdown TERM INT
trap stop_share EXIT
if [ -f "$CONTROL/active.json" ] && enabled; then
  namespace=$(jq -er '.namespace' "$CONTROL/active.json")
  name=$(jq -er '.name' "$CONTROL/active.json")
  start_share "$namespace" "$name" || exit 1
fi
while true; do
  if [ -n "${share_pid:-}" ] && ! share_alive; then
    atomic_status error
    exit 1
  fi
  if [ -f "$CONTROL/disconnect" ]; then disconnect || true
  elif [ -f "$CONTROL/configure.json" ]; then configure || true
  elif [ -f "$CONTROL/refresh" ]; then refresh
  fi
  sleep 1
done
