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

# Persist for entrypoint fallback (atomic, 600)
if [ -n "$elements_rpc_pass" ]; then
  (umask 077; tmpf="$(mktemp "${pass_file}.tmp.XXXXXX" 2>/dev/null)" && printf '%s' "$elements_rpc_pass" > "$tmpf" && chmod 600 "$tmpf" && mv -f "$tmpf" "$pass_file") 2>/dev/null || (echo "$elements_rpc_pass" > "$pass_file" && chmod 600 "$pass_file") 2>/dev/null || true
fi
export APP_ELECTRS_LIQUID_ELEMENTS_RPC_PASS="${elements_rpc_pass:-}"

# Tor onion address
rpc_hidden_service_file="${EXPORTS_TOR_DATA_DIR}/app-${EXPORTS_APP_ID}/main/hostname"
export APP_ELECTRS_LIQUID_RPC_HIDDEN_SERVICE="$(cat "${rpc_hidden_service_file}" 2>/dev/null || echo "")"


