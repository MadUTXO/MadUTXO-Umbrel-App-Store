export APP_ELECTRS_LIQUID_NODE_PORT="60601"

# Elements RPC password - try Umbrel's derive_entropy first (no docker needed)
elements_rpc_pass=""
if command -v derive_entropy >/dev/null 2>&1; then
  elements_rpc_pass="$(derive_entropy "app-elements-seed-APP_PASSWORD" 2>/dev/null || true)"
fi

# Fallback: persisted file from previous run
pass_file="${EXPORTS_APP_DIR}/data/electrs/.elements_rpc_pass"
if [ -z "$elements_rpc_pass" ] && [ -f "$pass_file" ]; then
  elements_rpc_pass="$(cat "$pass_file" 2>/dev/null || true)"
fi

# Last resort: docker inspect (keep for compatibility, guard with || true for set -e)
if [ -z "$elements_rpc_pass" ]; then
  elements_container="$(docker ps --filter name=elements --format '{{.Names}}' 2>/dev/null | grep -E 'elements.node' | head -1 || true)"
  if [ -n "$elements_container" ]; then
    elements_rpc_pass="$(docker inspect "$elements_container" --format '{{range .Config.Cmd}}{{.}} {{end}}' 2>/dev/null | grep -oP '(?<=-rpcpassword=)\S+' | head -1 || true)"
  fi
fi

# Persist for entrypoint fallback
if [ -n "$elements_rpc_pass" ]; then
  (echo "$elements_rpc_pass" > "$pass_file" && chmod 600 "$pass_file") 2>/dev/null || true
fi
export APP_ELECTRS_LIQUID_ELEMENTS_RPC_PASS="${elements_rpc_pass:-}"

# Tor onion address
rpc_hidden_service_file="${EXPORTS_TOR_DATA_DIR}/app-${EXPORTS_APP_ID}/main/hostname"
export APP_ELECTRS_LIQUID_RPC_HIDDEN_SERVICE="$(cat "${rpc_hidden_service_file}" 2>/dev/null || echo "")"


