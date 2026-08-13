#!/bin/sh
set -eu

umask 077

TAILSCALED_BIN="${TS_TAILSCALED_BIN:-/usr/local/bin/tailscaled}"
TAILSCALE_BIN="${TS_TAILSCALE_BIN:-/usr/local/bin/tailscale}"
STATE_DIR="${TS_STATE_DIR:-/var/lib/tailscale}"
SOCKET="${TS_SOCKET:-/var/run/tailscale/tailscaled.sock}"
CONTROL_DIR="${TS_CONTROL_DIR:-/run/lnswitchboard/control}"
STATUS_DIR="${TS_STATUS_DIR:-/run/lnswitchboard/status}"
QUEUE_DIR="$CONTROL_DIR/queue"
OPERATION_DIR="$CONTROL_DIR/operations"
PROCESSING_DIR="$CONTROL_DIR/processing"
COMPLETED_DIR="$CONTROL_DIR/completed"
ACK_DIR="$CONTROL_DIR/acks"
RESULT_DIR="$STATUS_DIR/results"
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
ACTIVE_STATE="$STATE_DIR/.lnswitchboard-active.json"

case "$LOGIN_RETENTION_SECONDS" in
    "" | *[!0-9]*)
        printf '%s\n' "TS_LOGIN_RETENTION_SECONDS must be a non-negative integer" >&2
        exit 1
        ;;
esac

TAILSCALED_PID=""
LOGIN_PID=""
LOGIN_COMPLETED_AT=""

mkdir -p "$STATE_DIR" "$QUEUE_DIR" "$OPERATION_DIR" "$PROCESSING_DIR" "$COMPLETED_DIR" "$ACK_DIR" "$RESULT_DIR" "$(dirname "$SOCKET")"
chmod 0700 "$CONTROL_DIR" "$STATUS_DIR" "$QUEUE_DIR" "$OPERATION_DIR" "$PROCESSING_DIR" "$COMPLETED_DIR" "$ACK_DIR" "$RESULT_DIR"

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

sync_path() {
    sync -f "$1"
}

durable_remove() {
    path=$1
    parent=$(dirname "$path")
    rm -f "$path"
    sync_path "$parent"
}

durable_move() {
    source=$1
    destination=$2
    source_parent=$(dirname "$source")
    destination_parent=$(dirname "$destination")
    mv -f "$source" "$destination"
    sync_path "$destination_parent"
    if [ "$source_parent" != "$destination_parent" ]; then
        sync_path "$source_parent"
    fi
}

atomic_text() {
    destination=$1
    content=$2
    temporary="$destination.tmp.$$"
    printf '%s\n' "$content" >"$temporary"
    chmod 0600 "$temporary"
    sync_path "$temporary"
    durable_move "$temporary" "$destination"
}

publish_command() {
    destination=$1
    shift
    temporary="$destination.tmp.$$"
    if "$@" >"$temporary" 2>/dev/null; then
        chmod 0600 "$temporary"
        sync_path "$temporary"
        durable_move "$temporary" "$destination"
    else
        rm -f "$temporary" "$destination"
        sync_path "$(dirname "$destination")"
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
        sync_path "$temporary"
        durable_move "$temporary" "$destination"
    else
        unset raw_status
        rm -f "$temporary" "$destination"
        sync_path "$(dirname "$destination")"
    fi
}

json_string_field() {
    field=$1
    path=$2
    sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$path" | head -n 1
}

json_field_count() {
    field=$1
    path=$2
    grep -o "\"${field}\"[[:space:]]*:" "$path" 2>/dev/null | wc -l | tr -d ' '
}

valid_operation_id() {
    candidate=$1
    [ "${#candidate}" -eq 32 ] || return 1
    case "$candidate" in *[!0-9a-f]*) return 1 ;; esac
}

valid_device_name() {
    candidate=$1
    [ -n "$candidate" ] || return 1
    [ "${#candidate}" -le 63 ] || return 1
    case "$candidate" in *[!a-z0-9-]* | -* | *-) return 1 ;; esac
}

valid_identity() {
    [ -n "$REQUESTED_EXTERNAL_ID" ] && [ -n "$REQUESTED_HOSTNAME" ] || return 1
    [ "${#REQUESTED_EXTERNAL_ID}" -le 255 ] || return 1
    [ "${#REQUESTED_HOSTNAME}" -le 253 ] || return 1
    case "$REQUESTED_EXTERNAL_ID$REQUESTED_HOSTNAME" in *[!A-Za-z0-9._:@+-]*) return 1 ;; esac
}

publish_result() {
    command_name=$1
    command_state=$2
    error_code=${3:-}
    operation_id=${4:-}
    external_id=${5:-}
    hostname=${6:-}
    destination="$RESULT_DIR/$operation_id.json"
    if [ -n "$error_code" ]; then
        payload=$(printf '{"command":"%s","state":"%s","error":"%s","operation_id":"%s","external_id":"%s","hostname":"%s"}' \
            "$command_name" "$command_state" "$error_code" "$operation_id" "$external_id" "$hostname")
    else
        payload=$(printf '{"command":"%s","state":"%s","operation_id":"%s","external_id":"%s","hostname":"%s"}' \
            "$command_name" "$command_state" "$operation_id" "$external_id" "$hostname")
    fi
    atomic_text "$destination" "$payload"
}

persist_active_identity() {
    temporary="$ACTIVE_STATE.tmp.$$"
    printf '{"external_id":"%s","hostname":"%s"}\n' \
        "$REQUESTED_EXTERNAL_ID" "$REQUESTED_HOSTNAME" >"$temporary"
    chmod 0600 "$temporary"
    sync_path "$temporary"
    durable_move "$temporary" "$ACTIVE_STATE"
}

read_claimed_command() {
    command_path=$1
    OPERATION_ID=$(json_string_field operation_id "$command_path")
    COMMAND_NAME=$(json_string_field command "$command_path")
    REQUESTED_EXTERNAL_ID=$(json_string_field external_id "$command_path")
    REQUESTED_HOSTNAME=$(json_string_field hostname "$command_path")
    DEVICE_NAME=$(json_string_field device_name "$command_path")
    valid_operation_id "$OPERATION_ID" || return 1
    [ "$(json_field_count operation_id "$command_path")" = 1 ] || return 1
    [ "$(json_field_count command "$command_path")" = 1 ] || return 1
    return 0
}

fresh_runtime_identity() {
    live_status="$STATUS_DIR/identity.json.tmp.$$"
    if ! "$TAILSCALE_BIN" --socket="$SOCKET" status --json --peers=false \
        >"$live_status" 2>/dev/null; then
        rm -f "$live_status"
        return 1
    fi
    LIVE_BACKEND_STATE=$(json_string_field BackendState "$live_status")
    current_external_id=$(json_string_field ID "$live_status")
    current_hostname=$(json_string_field DNSName "$live_status" | sed 's/\.$//')
    rm -f "$live_status"
    valid_identity || return 1
    [ "$current_external_id" = "$REQUESTED_EXTERNAL_ID" ] \
        && [ "$current_hostname" = "$REQUESTED_HOSTNAME" ]
}

begin_login() {
    if ! valid_device_name "$DEVICE_NAME"; then
        publish_result begin_login error invalid_command "$OPERATION_ID"
        return
    fi
    stop_login
    rm -f "$STATUS_DIR/login.json"
    "$TAILSCALE_BIN" --socket="$SOCKET" up --json --reset \
        --hostname="$DEVICE_NAME" --accept-dns=false \
        >"$STATUS_DIR/login.json" 2>/dev/null &
    LOGIN_PID=$!
    chmod 0600 "$STATUS_DIR/login.json"
    publish_result begin_login started "" "$OPERATION_ID"
}

cancel_login() {
    stop_login
    rm -f "$STATUS_DIR/login.json"
    publish_result cancel_login complete "" "$OPERATION_ID"
}

clear_login() {
    if [ -n "$LOGIN_PID" ]; then
        publish_result clear_login error login_active "$OPERATION_ID"
        return
    fi
    rm -f "$STATUS_DIR/login.json"
    LOGIN_COMPLETED_AT=""
    publish_result clear_login complete "" "$OPERATION_ID"
}

enable_funnel() {
    if ! fresh_runtime_identity; then
        publish_result enable error identity_mismatch "$OPERATION_ID" "$REQUESTED_EXTERNAL_ID" "$REQUESTED_HOSTNAME"
        return
    fi
    if "$TAILSCALE_BIN" --socket="$SOCKET" funnel --bg --yes "$FUNNEL_TARGET" >/dev/null 2>/dev/null; then
        persist_active_identity
        publish_result enable complete "" "$OPERATION_ID" "$REQUESTED_EXTERNAL_ID" "$REQUESTED_HOSTNAME"
    else
        publish_result enable error funnel_enable_failed "$OPERATION_ID" "$REQUESTED_EXTERNAL_ID" "$REQUESTED_HOSTNAME"
    fi
}

disable_funnel() {
    if ! fresh_runtime_identity; then
        publish_result disable error identity_mismatch "$OPERATION_ID" "$REQUESTED_EXTERNAL_ID" "$REQUESTED_HOSTNAME"
        return
    fi
    if "$TAILSCALE_BIN" --socket="$SOCKET" funnel reset >/dev/null 2>/dev/null; then
        persist_active_identity
        publish_result disable complete "" "$OPERATION_ID" "$REQUESTED_EXTERNAL_ID" "$REQUESTED_HOSTNAME"
    else
        publish_result disable error funnel_disable_failed "$OPERATION_ID" "$REQUESTED_EXTERNAL_ID" "$REQUESTED_HOSTNAME"
    fi
}

disconnect_journal_path() {
    printf '%s/.lnswitchboard-disconnect-%s.json' "$STATE_DIR" "$OPERATION_ID"
}

write_disconnect_phase() {
    phase=$1
    journal=$(disconnect_journal_path)
    payload=$(printf '{"command":"disconnect","operation_id":"%s","external_id":"%s","hostname":"%s","phase":"%s"}' \
        "$OPERATION_ID" "$REQUESTED_EXTERNAL_ID" "$REQUESTED_HOSTNAME" "$phase")
    atomic_text "$journal" "$payload"
}

resume_disconnect() {
    journal=$(disconnect_journal_path)
    phase=$(json_string_field phase "$journal")

    # Only the initial transition may authorize teardown. It carries one fresh,
    # exact identity snapshot into the durable journal; recovery never falls
    # back to cached status or historical active-node metadata.
    if [ "$phase" = prepared ]; then
        if ! fresh_runtime_identity || [ "$LIVE_BACKEND_STATE" != Running ]; then
            publish_result disconnect error identity_mismatch "$OPERATION_ID" "$REQUESTED_EXTERNAL_ID" "$REQUESTED_HOSTNAME"
            return
        fi
        write_disconnect_phase funnel_disabling
        phase=funnel_disabling
    fi

    # Intent phases are written before each side effect. Replaying reset/logout
    # is safe, so a crash after the provider call cannot strand the operation.
    if [ "$phase" = funnel_disabling ]; then
        if ! "$TAILSCALE_BIN" --socket="$SOCKET" funnel reset >/dev/null 2>/dev/null; then
            publish_result disconnect error funnel_disable_failed "$OPERATION_ID" "$REQUESTED_EXTERNAL_ID" "$REQUESTED_HOSTNAME"
            return
        fi
        write_disconnect_phase funnel_disabled
        phase=funnel_disabled
    fi
    if [ "$phase" = funnel_disabled ]; then
        write_disconnect_phase provider_logging_out
        phase=provider_logging_out
    fi
    if [ "$phase" = provider_logging_out ]; then
        if ! "$TAILSCALE_BIN" --socket="$SOCKET" logout >/dev/null 2>/dev/null; then
            # A successful logout followed by a crash is observed as NeedsLogin.
            # This is accepted only with the durable, previously identity-bound
            # provider_logging_out intent—not from status or active metadata alone.
            logout_status="$STATUS_DIR/logout-status.json.tmp.$$"
            if ! "$TAILSCALE_BIN" --socket="$SOCKET" status --json --peers=false >"$logout_status" 2>/dev/null \
                || [ "$(json_string_field BackendState "$logout_status")" != NeedsLogin ]; then
                rm -f "$logout_status"
                publish_result disconnect error logout_failed "$OPERATION_ID" "$REQUESTED_EXTERNAL_ID" "$REQUESTED_HOSTNAME"
                return
            fi
            rm -f "$logout_status"
        fi
        write_disconnect_phase provider_logged_out
        phase=provider_logged_out
    fi
    if [ "$phase" = provider_logged_out ]; then
        write_disconnect_phase local_state_deleting
        phase=local_state_deleting
    fi
    if [ "$phase" = local_state_deleting ]; then
        stop_login
        rm -f "$STATUS_DIR/login.json"
        if [ -n "$TAILSCALED_PID" ]; then
            kill "$TAILSCALED_PID" 2>/dev/null || true
            wait "$TAILSCALED_PID" 2>/dev/null || true
            TAILSCALED_PID=""
        fi
        find "$STATE_DIR" -mindepth 1 -maxdepth 1 \
            ! -name ".lnswitchboard-disconnect-$OPERATION_ID.json" -exec rm -rf '{}' ';'
        rm -f "$SOCKET"
        write_disconnect_phase local_state_deleted
        start_daemon
        phase=local_state_deleted
    fi
    if [ "$phase" = local_state_deleted ] || [ "$phase" = complete ]; then
        write_disconnect_phase complete
        publish_result disconnect complete "" "$OPERATION_ID" "$REQUESTED_EXTERNAL_ID" "$REQUESTED_HOSTNAME"
    fi
}

process_claim() {
    command_path=$1
    filename=$(basename "$command_path")
    filename_operation=${filename%.json}
    if ! read_claimed_command "$command_path" || [ "$filename_operation" != "$OPERATION_ID" ]; then
        if valid_operation_id "$filename_operation"; then
            OPERATION_ID=$filename_operation
            publish_result invalid error invalid_command "$OPERATION_ID"
        fi
        durable_remove "$command_path"
        return
    fi
    case "$COMMAND_NAME" in
        begin_login) begin_login ;;
        cancel_login) cancel_login ;;
        clear_login) clear_login ;;
        enable) enable_funnel ;;
        disable) disable_funnel ;;
        disconnect)
            journal=$(disconnect_journal_path)
            if [ ! -f "$journal" ]; then
                valid_identity || {
                    publish_result disconnect error invalid_command "$OPERATION_ID"
                    durable_remove "$command_path"
                    return
                }
                write_disconnect_phase prepared
            fi
            resume_disconnect
            ;;
        *) publish_result "$COMMAND_NAME" error invalid_command "$OPERATION_ID" ;;
    esac
    durable_remove "$command_path"
}

recover_disconnect_journals() {
    for journal in "$STATE_DIR"/.lnswitchboard-disconnect-*.json; do
        [ -f "$journal" ] || continue
        OPERATION_ID=$(json_string_field operation_id "$journal")
        REQUESTED_EXTERNAL_ID=$(json_string_field external_id "$journal")
        REQUESTED_HOSTNAME=$(json_string_field hostname "$journal")
        COMMAND_NAME=disconnect
        if ! valid_operation_id "$OPERATION_ID" || ! valid_identity; then
            continue
        fi
        if [ -f "$RESULT_DIR/$OPERATION_ID.json" ]; then
            continue
        fi
        resume_disconnect
    done
}

recover_operation_records() {
    for operation in "$OPERATION_DIR"/*.json; do
        [ -f "$operation" ] || continue
        operation_id=$(basename "$operation" .json)
        valid_operation_id "$operation_id" || continue
        [ -f "$QUEUE_DIR/$operation_id.json" ] && continue
        [ -f "$PROCESSING_DIR/$operation_id.json" ] && continue
        [ -f "$RESULT_DIR/$operation_id.json" ] && continue
        [ -f "$ACK_DIR/$operation_id.ack" ] && continue
        [ -f "$COMPLETED_DIR/$operation_id.json" ] && continue
        if ln "$operation" "$QUEUE_DIR/$operation_id.json" 2>/dev/null; then
            sync_path "$QUEUE_DIR"
        fi
    done
}

cleanup_completed_operations() {
    for completed in "$COMPLETED_DIR"/*.json; do
        [ -f "$completed" ] || continue
        operation_id=$(basename "$completed" .json)
        valid_operation_id "$operation_id" || continue
        [ -f "$ACK_DIR/$operation_id.ack" ] && continue
        durable_remove "$OPERATION_DIR/$operation_id.json"
    done
}

consume_results() {
    for acknowledgement in "$ACK_DIR"/*.ack; do
        [ -f "$acknowledgement" ] || continue
        operation_id=$(basename "$acknowledgement" .ack)
        if valid_operation_id "$operation_id" \
            && [ "$(tr -d '\r\n' <"$acknowledgement")" = "$operation_id" ]; then
            if [ -f "$OPERATION_DIR/$operation_id.json" ] \
                && [ ! -f "$COMPLETED_DIR/$operation_id.json" ]; then
                atomic_text "$COMPLETED_DIR/$operation_id.json" \
                    "$(cat "$OPERATION_DIR/$operation_id.json")"
            fi
            durable_remove "$RESULT_DIR/$operation_id.json"
            durable_remove "$STATE_DIR/.lnswitchboard-disconnect-$operation_id.json"
        fi
        durable_remove "$acknowledgement"
        cleanup_completed_operations
    done
}

claim_next_command() {
    for command_path in "$PROCESSING_DIR"/*.json; do
        [ -f "$command_path" ] || continue
        process_claim "$command_path"
        return
    done
    for command_path in "$QUEUE_DIR"/*.json; do
        [ -f "$command_path" ] || continue
        claimed="$PROCESSING_DIR/$(basename "$command_path")"
        if durable_move "$command_path" "$claimed" 2>/dev/null; then
            process_claim "$claimed"
        fi
        return
    done
}

expire_login_artifact() {
    [ -n "$LOGIN_COMPLETED_AT" ] || return 0
    now=$(date +%s)
    if [ $((now - LOGIN_COMPLETED_AT)) -ge "$LOGIN_RETENTION_SECONDS" ]; then
        rm -f "$STATUS_DIR/login.json"
        LOGIN_COMPLETED_AT=""
    fi
}

start_daemon
recover_disconnect_journals
recover_operation_records

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
    consume_results
    recover_disconnect_journals
    recover_operation_records
    cleanup_completed_operations
    claim_next_command
    publish_node_status
    publish_command "$STATUS_DIR/funnel.json" \
        "$TAILSCALE_BIN" --socket="$SOCKET" funnel status --json
    sleep "$POLL_INTERVAL" &
    wait $! 2>/dev/null || true
done
