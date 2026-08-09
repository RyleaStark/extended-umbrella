export APP_LITECOIN_FULCRUM_IP="10.21.24.200"
export APP_LITECOIN_FULCRUM_NODE_IP="10.21.25.200"
export APP_LITECOIN_FULCRUM_TOR_IP="10.21.24.201"
export APP_LITECOIN_FULCRUM_NODE_PORT="51002"
export APP_LITECOIN_FULCRUM_ADMIN_PORT="8000"

rpc_hidden_service_file="${EXPORTS_TOR_DATA_DIR}/app-${EXPORTS_APP_ID}-rpc/hostname"
export APP_LITECOIN_FULCRUM_RPC_HIDDEN_SERVICE="$(cat "${rpc_hidden_service_file}" 2>/dev/null || echo "notyetset.onion")"
