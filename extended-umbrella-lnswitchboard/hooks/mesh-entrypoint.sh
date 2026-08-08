#!/bin/sh
# lnSwitchboard Cloudflare Mesh sidecar entrypoint wrapper.
#
# The cloudflare/mesh image reads MESH_NODE_TOKEN from the environment only,
# but lnSwitchboard provisions the node token AFTER the stack starts (there is
# no Docker socket access by design). Mirror the cloudflared --token-file
# pattern: exit until the app writes the token file, letting the compose
# restart policy re-enter until provisioning completes. Once started, supervise
# the real entrypoint so deleting or replacing the token file revokes the local
# connector even when only the lnSwitchboard application process restarts.
set -eu

TOKEN_FILE="${MESH_NODE_TOKEN_FILE:-/run/lnswitchboard/node.env}"
STATE_DIR="/var/lib/cloudflare-warp"
IDENTITY_FILE="$STATE_DIR/.lnswitchboard-node-id"

read_token_field() {
    field="$1"
    { sed -n "s/^${field}=//p" "$TOKEN_FILE" 2>/dev/null || true; } |
        tr -d '[:space:]'
}

clear_mesh_state() {
    # Keep destructive cleanup pinned to the image's dedicated state mount.
    [ "$STATE_DIR" = "/var/lib/cloudflare-warp" ] || exit 1
    mkdir -p "$STATE_DIR"
    for entry in "$STATE_DIR"/* "$STATE_DIR"/.[!.]* "$STATE_DIR"/..?*; do
        if [ -e "$entry" ] || [ -L "$entry" ]; then
            rm -rf -- "$entry"
        fi
    done
}

record_mesh_identity() {
    temporary="$IDENTITY_FILE.tmp.$$"
    umask 077
    printf '%s\n' "$NODE_ID" > "$temporary"
    mv -f "$temporary" "$IDENTITY_FILE"
}

if [ ! -s "$TOKEN_FILE" ]; then
    echo "mesh node token not provisioned yet; waiting for lnSwitchboard" >&2
    exit 1
fi

NODE_ID="$(read_token_field MESH_NODE_ID)"
TOKEN="$(read_token_field MESH_NODE_TOKEN)"
if [ -z "$NODE_ID" ] || [ -z "$TOKEN" ]; then
    echo "mesh node token file is incomplete; waiting for lnSwitchboard" >&2
    exit 1
fi

mkdir -p "$STATE_DIR"
PREVIOUS_NODE_ID="$(
    { sed -n '1p' "$IDENTITY_FILE" 2>/dev/null || true; } |
        tr -d '[:space:]'
)"
if [ "$PREVIOUS_NODE_ID" != "$NODE_ID" ]; then
    clear_mesh_state
    record_mesh_identity
fi

export MESH_NODE_TOKEN="$TOKEN"

terminate_child() {
    kill -TERM "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
}

/entrypoint "$@" &
CHILD_PID=$!
trap 'terminate_child; exit 143' HUP INT TERM

while kill -0 "$CHILD_PID" 2>/dev/null; do
    sleep 2
    CURRENT_NODE_ID="$(read_token_field MESH_NODE_ID)"
    CURRENT_TOKEN="$(read_token_field MESH_NODE_TOKEN)"
    if [ "$CURRENT_NODE_ID" != "$NODE_ID" ] || [ "$CURRENT_TOKEN" != "$TOKEN" ]; then
        echo "mesh node authorization was withdrawn; stopping connector" >&2
        terminate_child
        clear_mesh_state
        exit 1
    fi
done

set +e
wait "$CHILD_PID"
STATUS=$?
set -e
exit "$STATUS"
