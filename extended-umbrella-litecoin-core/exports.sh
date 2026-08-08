# Network services
export APP_LITECOIN_NODE_IP="10.21.23.8"
export APP_LITECOIN_TOR_PROXY_IP="10.21.23.10"

# Persistent node state
export APP_LITECOIN_DATA_DIR="${EXPORTS_APP_DIR}/data/litecoin"

# Litecoin mainnet listeners
export APP_LITECOIN_RPC_PORT="9332"
export APP_LITECOIN_P2P_PORT="9333"
export APP_LITECOIN_P2P_WHITEBIND_PORT="9335"
export APP_LITECOIN_TOR_PORT="9334"
export APP_LITECOIN_ZMQ_RAWBLOCK_PORT="29332"
export APP_LITECOIN_ZMQ_RAWTX_PORT="29333"
export APP_LITECOIN_ZMQ_HASHBLOCK_PORT="29334"
export APP_LITECOIN_ZMQ_SEQUENCE_PORT="29335"
export APP_LITECOIN_ZMQ_HASHTX_PORT="29336"
export APP_LITECOIN_NETWORK="mainnet"

# Persist generated RPC credentials across restarts and upgrades.
LITECOIN_ENV_FILE="${EXPORTS_APP_DIR}/.env"
if [[ ! -f "${LITECOIN_ENV_FILE}" ]]; then
  LITECOIN_RPC_USER="umbrel"
  LITECOIN_RPC_DETAILS=$("${EXPORTS_APP_DIR}/scripts/rpcauth.py" "${LITECOIN_RPC_USER}")
  LITECOIN_RPC_PASS=$(printf '%s\n' "${LITECOIN_RPC_DETAILS}" | tail -1)
  printf "export APP_LITECOIN_RPC_USER='%s'\nexport APP_LITECOIN_RPC_PASS='%s'\n" "${LITECOIN_RPC_USER}" "${LITECOIN_RPC_PASS}" > "${LITECOIN_ENV_FILE}"
fi
. "${LITECOIN_ENV_FILE}"

# Tor hidden-service hostnames are absent until Tor has started once.
rpc_hidden_service_file="${EXPORTS_TOR_DATA_DIR}/app-${EXPORTS_APP_ID}-rpc/hostname"
p2p_hidden_service_file="${EXPORTS_TOR_DATA_DIR}/app-${EXPORTS_APP_ID}-p2p/hostname"
export APP_LITECOIN_RPC_HIDDEN_SERVICE="$(cat "${rpc_hidden_service_file}" 2>/dev/null || echo "notyetset.onion")"
export APP_LITECOIN_P2P_HIDDEN_SERVICE="$(cat "${p2p_hidden_service_file}" 2>/dev/null || echo "notyetset.onion")"
