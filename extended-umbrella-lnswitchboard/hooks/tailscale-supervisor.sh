#!/bin/sh
set -eu

umask 077

TAILSCALED_BIN="${TS_TAILSCALED_BIN:-/usr/local/bin/tailscaled}"
TAILSCALE_BIN="${TS_TAILSCALE_BIN:-/usr/local/bin/tailscale}"
STATE_DIR="${TS_STATE_DIR:-/var/lib/tailscale}"
SOCKET="${TS_SOCKET:-/var/run/tailscale/tailscaled.sock}"
CONTROL_DIR="${TS_CONTROL_DIR:-/run/lnswitchboard/control}"
STATUS_DIR="${TS_STATUS_DIR:-/run/lnswitchboard/status}"
POLL_INTERVAL="${TS_POLL_INTERVAL:-2}"
LOGIN_RETENTION_SECONDS="${TS_LOGIN_RETENTION_SECONDS:-300}"
DEP_ENV=$(printf '%s' "${DEP_ENV:-DOCKER}" | tr '[:lower:]' '[:upper:]')
case "$DEP_ENV" in
    DOCKER) PUBLIC_HOST=lnswitchboard-public ;;
    UMBREL) PUBLIC_HOST=lnswitchboard_public ;;
    UMBREL_DEV) PUBLIC_HOST=extended-umbrella-lnswitchboard_public ;;
    *) printf '%s\n' "unsupported DEP_ENV" >&2; exit 1 ;;
esac
FUNNEL_TARGET="http://${PUBLIC_HOST}:21212"

case "$LOGIN_RETENTION_SECONDS" in
    "" | *[!0-9]*)
        printf '%s\n' "TS_LOGIN_RETENTION_SECONDS must be a non-negative integer" >&2
        exit 1
        ;;
esac

TAILSCALED_PID=""
LOGIN_PID=""
LOGIN_COMPLETED_AT=""

mkdir -p "$STATE_DIR" "$CONTROL_DIR" "$STATUS_DIR" "$(dirname "$SOCKET")"
chmod 0700 "$CONTROL_DIR" "$STATUS_DIR"

if [ -f "$STATUS_DIR/login.json" ]; then
    LOGIN_COMPLETED_AT=$(stat -c %Y "$STATUS_DIR/login.json" 2>/dev/null || date +%s)
fi

stop_login() {
    if [ -n "$LOGIN_PID" ]; then
        kill "$LOGIN_PID" 2>/dev/null || true
        wait "$LOGIN_PID" 2>/dev/null || true
        LOGIN_PID=""
    fi
    LOGIN_COMPLETED_AT=""
}

stop_children() {
    stop_login
    if [ -n "$TAILSCALED_PID" ]; then
        kill "$TAILSCALED_PID" 2>/dev/null || true
        wait "$TAILSCALED_PID" 2>/dev/null || true
        TAILSCALED_PID=""
    fi
}

trap 'stop_children; exit 0' TERM INT HUP

start_daemon() {
    "$TAILSCALED_BIN" \
        --tun=userspace-networking \
        --state="$STATE_DIR/tailscaled.state" \
        --statedir="$STATE_DIR" \
        --socket="$SOCKET" \
        >/dev/null 2>/dev/null &
    TAILSCALED_PID=$!
}

publish_command() {
    destination=$1
    shift
    temporary="$destination.tmp.$$"
    if "$@" >"$temporary" 2>/dev/null; then
        chmod 0600 "$temporary"
        mv -f "$temporary" "$destination"
    else
        rm -f "$temporary" "$destination"
    fi
}

publish_node_status() {
    destination="$STATUS_DIR/node.json"
    temporary="$destination.tmp.$$"
    raw_status=""
    if raw_status=$("$TAILSCALE_BIN" --socket="$SOCKET" status --json --peers=false 2>/dev/null); then
        printf '%s\n' "$raw_status" | sed -E \
            -e 's/"AuthURL"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*,[[:space:]]*//' \
            -e 's/,[[:space:]]*"AuthURL"[[:space:]]*:[[:space:]]*"[^"]*"//' \
            -e 's/"AuthURL"[[:space:]]*:[[:space:]]*"[^"]*"//' \
            >"$temporary"
        unset raw_status
        chmod 0600 "$temporary"
        mv -f "$temporary" "$destination"
    else
        unset raw_status
        rm -f "$temporary" "$destination"
    fi
}

publish_ack() {
    command_name=$1
    command_state=$2
    error_code=${3:-}
    temporary="$STATUS_DIR/command.json.tmp.$$"
    if [ -n "$error_code" ]; then
        printf '{"command":"%s","state":"%s","error":"%s"}\n' \
            "$command_name" "$command_state" "$error_code" >"$temporary"
    else
        printf '{"command":"%s","state":"%s"}\n' \
            "$command_name" "$command_state" >"$temporary"
    fi
    chmod 0600 "$temporary"
    mv -f "$temporary" "$STATUS_DIR/command.json"
}

valid_device_name() {
    candidate=$1
    [ -n "$candidate" ] || return 1
    [ "${#candidate}" -le 63 ] || return 1
    case "$candidate" in
        *[!a-z0-9-]* | -* | *-) return 1 ;;
    esac
    return 0
}

begin_login() {
    rm -f "$CONTROL_DIR/begin-login"
    if [ ! -f "$CONTROL_DIR/login.device-name" ]; then
        publish_ack "begin_login" "error" "invalid_device_name"
        return
    fi

    requested_name=$(cat "$CONTROL_DIR/login.device-name" 2>/dev/null || true)
    rm -f "$CONTROL_DIR/login.device-name"
    device_name=$(printf '%s' "$requested_name" | tr '[:upper:]' '[:lower:]')
    if ! valid_device_name "$device_name"; then
        publish_ack "begin_login" "error" "invalid_device_name"
        return
    fi

    stop_login
    rm -f "$STATUS_DIR/login.json"
    "$TAILSCALE_BIN" --socket="$SOCKET" up --json --reset \
        --hostname="$device_name" \
        --accept-dns=false \
        >"$STATUS_DIR/login.json" 2>/dev/null &
    LOGIN_PID=$!
    chmod 0600 "$STATUS_DIR/login.json"
    publish_ack "begin_login" "started"
}

cancel_login() {
    rm -f "$CONTROL_DIR/cancel-login"
    stop_login
    rm -f "$STATUS_DIR/login.json"
    publish_ack "cancel_login" "complete"
}

clear_login() {
    rm -f "$CONTROL_DIR/clear-login"
    if [ -n "$LOGIN_PID" ]; then
        publish_ack "clear_login" "error" "login_active"
        return
    fi
    rm -f "$STATUS_DIR/login.json"
    LOGIN_COMPLETED_AT=""
    publish_ack "clear_login" "complete"
}

expire_login_artifact() {
    if [ -z "$LOGIN_COMPLETED_AT" ]; then
        return 0
    fi
    now=$(date +%s)
    if [ $((now - LOGIN_COMPLETED_AT)) -ge "$LOGIN_RETENTION_SECONDS" ]; then
        rm -f "$STATUS_DIR/login.json"
        LOGIN_COMPLETED_AT=""
    fi
}

enable_funnel() {
    rm -f "$CONTROL_DIR/enable"
    if "$TAILSCALE_BIN" --socket="$SOCKET" funnel --bg --yes "$FUNNEL_TARGET" \
        >/dev/null 2>/dev/null; then
        publish_ack "enable" "complete"
    else
        publish_ack "enable" "error" "funnel_enable_failed"
    fi
}

disable_funnel() {
    rm -f "$CONTROL_DIR/disable"
    if "$TAILSCALE_BIN" --socket="$SOCKET" funnel reset \
        >/dev/null 2>/dev/null; then
        publish_ack "disable" "complete"
    else
        publish_ack "disable" "error" "funnel_disable_failed"
    fi
}

disconnect_node() {
    rm -f "$CONTROL_DIR/disconnect"
    stop_login
    rm -f "$STATUS_DIR/login.json"

    node_state=""
    if [ -f "$STATUS_DIR/node.json" ]; then
        node_state=$(sed -n 's/.*"BackendState": *"\([^"]*\)".*/\1/p' "$STATUS_DIR/node.json" | head -n 1)
    fi

    case "$node_state" in
        NeedsLogin|Stopped|"")
            # An unauthenticated node is not funneling anything, and Funnel
            # reset/logout are guaranteed to fail here (for example after the
            # device key expired). Teardown must proceed so the operator can
            # re-authenticate instead of being trapped in a dead connection.
            ;;
        *)
            # A live node may still be serving Funnel traffic: stay
            # fail-closed so a reported disconnect never leaves exposure.
            if ! "$TAILSCALE_BIN" --socket="$SOCKET" funnel reset \
                >/dev/null 2>/dev/null; then
                publish_ack "disconnect" "error" "funnel_disable_failed"
                return
            fi
            if ! "$TAILSCALE_BIN" --socket="$SOCKET" logout \
                >/dev/null 2>/dev/null; then
                publish_ack "disconnect" "error" "logout_failed"
                return
            fi
            ;;
    esac

    if [ -n "$TAILSCALED_PID" ]; then
        kill "$TAILSCALED_PID" 2>/dev/null || true
        wait "$TAILSCALED_PID" 2>/dev/null || true
        TAILSCALED_PID=""
    fi
    find "$STATE_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf '{}' ';'
    rm -f "$SOCKET"
    start_daemon
    publish_ack "disconnect" "complete"
}

start_daemon

while :; do
    if ! kill -0 "$TAILSCALED_PID" 2>/dev/null; then
        wait "$TAILSCALED_PID" 2>/dev/null || true
        start_daemon
    fi

    if [ -n "$LOGIN_PID" ] && ! kill -0 "$LOGIN_PID" 2>/dev/null; then
        wait "$LOGIN_PID" 2>/dev/null || true
        LOGIN_PID=""
        LOGIN_COMPLETED_AT=$(date +%s)
    fi

    expire_login_artifact

    if [ -f "$CONTROL_DIR/disconnect" ]; then
        disconnect_node
    elif [ -f "$CONTROL_DIR/disable" ]; then
        disable_funnel
    elif [ -f "$CONTROL_DIR/enable" ]; then
        enable_funnel
    elif [ -f "$CONTROL_DIR/cancel-login" ]; then
        cancel_login
    elif [ -f "$CONTROL_DIR/clear-login" ]; then
        clear_login
    elif [ -f "$CONTROL_DIR/begin-login" ]; then
        begin_login
    fi

    publish_node_status
    publish_command \
        "$STATUS_DIR/funnel.json" \
        "$TAILSCALE_BIN" --socket="$SOCKET" funnel status --json

    sleep "$POLL_INTERVAL" &
    wait $! 2>/dev/null || true
done
