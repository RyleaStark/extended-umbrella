#!/usr/bin/env bash
set -euo pipefail
umask 077
CONTROL=${ZROK_CONTROL_DIR:-/run/lnswitchboard/control}
STATUS=${ZROK_STATUS_DIR:-/run/lnswitchboard/status}
DEP_ENV=$(printf '%s' "${DEP_ENV:-DOCKER}" | tr '[:lower:]' '[:upper:]')
case "$DEP_ENV" in
  DOCKER) PUBLIC_HOST=lnswitchboard-public ;;
  UMBREL) PUBLIC_HOST=lnswitchboard_public ;;
  UMBREL_DEV) PUBLIC_HOST=extended-umbrella-lnswitchboard_public ;;
  *) printf '%s\n' "unsupported DEP_ENV" >&2; exit 1 ;;
esac
TARGET="http://${PUBLIC_HOST}:21212"
ACTIVE=${ZROK_ACTIVE_FILE:-$HOME/.lnswitchboard-active.json}
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

atomic_active() {
  local phase=$1 namespace=$2 name=$3 endpoints=${4:-'[]'} tmp="${ACTIVE}.tmp.${BASHPID}"
  jq -cn --arg phase "$phase" --arg namespace "$namespace" --arg name "$name" \
    --arg operation_id "$operation_id" --argjson frontend_endpoints "$endpoints" \
    '{phase:$phase,namespace:$namespace,name:$name,operation_id:$operation_id,frontend_endpoints:$frontend_endpoints}' >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$ACTIVE"
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
  local namespace=$1 name=$2 names
  names=$(zrok2 list names --namespace-token "$namespace" --json 2>/dev/null) || return 2
  jq -e --arg namespace "$namespace" --arg name "$name" \
    'any(.[]; .namespaceToken == $namespace and .name == $name)' <<<"$names" >/dev/null
}

cleanup_fixed_shares() {
  local shares token
  shares=$(zrok2 list shares --share-mode public --target "$TARGET" --json 2>/dev/null) || return 1
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    zrok2 delete share "$token" >/dev/null 2>&1 || return 1
  done < <(jq -r --arg target "$TARGET" '.shares[]? | select(.target == $target) | .shareToken' <<<"$shares")
}

start_share() {
  local namespace=$1 name=$2 fifo deadline state endpoints share_token
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
          .msg == "boot" and (.token | type == "string" and length >= 1 and length <= 4096) and
          (.frontend_endpoints | type == "array" and length >= 1 and length <= 8) and
          all(.frontend_endpoints[];
            type == "string" and length >= 1 and length <= 253 and
            test("^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$"))
        ' <<<"$boot" >/dev/null; then
          share_token=$(jq -er '.token' <<<"$boot")
          endpoints=$(jq -c '{frontend_endpoints:[.frontend_endpoints[] | "https://" + ascii_downcase]}' <<<"$boot")
          atomic_active active "$namespace" "$name" "$(jq -c '.frontend_endpoints' <<<"$endpoints")"
          atomic_status connected "$(jq -c --arg namespace "$namespace" --arg name "$name" '. + {namespace:$namespace,name:$name}' <<<"$endpoints")"
        else
          atomic_status error
        fi
      fi
    done <"$fifo"
  ) &
  local drain_pid=$!
  zrok2 share public "$TARGET" --backend-mode proxy --open --subordinate --force-local \
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
    cleanup_fixed_shares || { atomic_status error; token=; return 1; }
    zrok2 disable >/dev/null 2>&1 || { atomic_status error; token=; return 1; }
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
    if [ "$name_status" = 2 ] || ! zrok2 create name --namespace-token "$namespace" "$name" >/dev/null 2>&1; then
      zrok2 disable >/dev/null 2>&1 || true
      atomic_status error
      return 1
    fi
    created=true
  fi
  atomic_active starting "$namespace" "$name"
  if ! start_share "$namespace" "$name"; then
    if [ "$created" = true ]; then zrok2 delete name --namespace-token "$namespace" "$name" >/dev/null 2>&1 || true; fi
    zrok2 disable >/dev/null 2>&1 || true
    return 1
  fi
}

disconnect() {
  local namespace name
  operation_id=$(cat "$CONTROL/disconnect")
  rm -f "$CONTROL/disconnect"
  if [ ! -f "$ACTIVE" ] && ! enabled; then atomic_status disconnected; return 0; fi
  namespace=$(jq -er '.namespace' "$ACTIVE") || { atomic_status error; return 1; }
  name=$(jq -er '.name' "$ACTIVE") || { atomic_status error; return 1; }
  atomic_active cleanup "$namespace" "$name" "$(jq -c '.frontend_endpoints // []' "$ACTIVE")"
  stop_share
  cleanup_fixed_shares || { atomic_status error; return 1; }
  if name_exists "$namespace" "$name"; then
    zrok2 delete name --namespace-token "$namespace" "$name" >/dev/null 2>&1 || { atomic_status error; return 1; }
  elif [ "$?" = 2 ]; then atomic_status error; return 1; fi
  zrok2 disable >/dev/null 2>&1 || { atomic_status error; return 1; }
  rm -f "$ACTIVE"
  atomic_status disconnected
}

refresh() {
  local endpoints
  operation_id=$(cat "$CONTROL/refresh")
  rm -f "$CONTROL/refresh"
  endpoints=$(jq -c '
    select(
      (.namespace | type == "string" and length >= 1 and length <= 128) and
      (.name | type == "string" and length >= 1 and length <= 63) and
      (.frontend_endpoints | type == "array" and length >= 1 and length <= 8)
    ) |
    {frontend_endpoints,namespace,name}
  ' "$ACTIVE" 2>/dev/null || true)
  if share_alive && [ -n "$endpoints" ]; then
    atomic_status refresh_complete "$endpoints"
  else
    atomic_status error
  fi
}

trap shutdown TERM INT
trap stop_share EXIT
if [ -f "$ACTIVE" ]; then
  operation_id=$(jq -r '.operation_id // "recovery"' "$ACTIVE")
  phase=$(jq -er '.phase' "$ACTIVE")
  namespace=$(jq -er '.namespace' "$ACTIVE")
  name=$(jq -er '.name' "$ACTIVE")
  if [ "$phase" = cleanup ]; then
    printf '%s' "$operation_id" >"$CONTROL/disconnect"
    disconnect || exit 1
  elif enabled; then
    cleanup_fixed_shares || exit 1
    start_share "$namespace" "$name" || exit 1
  else
    atomic_status error
    exit 1
  fi
fi
while true; do
  if [ -n "${share_pid:-}" ] && ! share_alive; then atomic_status error; exit 1; fi
  if [ -f "$CONTROL/disconnect" ]; then disconnect || true
  elif [ -f "$CONTROL/configure.json" ]; then configure || true
  elif [ -f "$CONTROL/refresh" ]; then refresh
  fi
  sleep 1
done
