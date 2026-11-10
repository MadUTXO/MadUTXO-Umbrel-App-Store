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
  # This script runs as root, but the file lives in the container's /data
  # volume and is rewritten by electrs (uid 1000) on every start. Hand it over
  # here: a hooks/pre-start chown is undone, because umbreld re-sources this
  # file from inside `compose up`, after the hook has run.
  chown 1000:1000 "$pass_file" 2>/dev/null || true
fi

# Tor onion address
# The hostname is interpolated into the web UI by envsubst before any client-side
# sanitisation runs, so validate it here. Accept only a v3 onion hostname
# (56 base32 chars + ".onion", 62 bytes total); anything else is dropped rather
# than exported, which removes the JS string-literal break-out path entirely.
rpc_hidden_service_file="${EXPORTS_TOR_DATA_DIR}/app-${EXPORTS_APP_ID}/main/hostname"
rpc_hidden_service="$(cat "${rpc_hidden_service_file}" 2>/dev/null | tr -d '\r\n' || true)"
case "$rpc_hidden_service" in
  *[!a-z2-7.]*|*.*.*) rpc_hidden_service="" ;;
esac
case "$rpc_hidden_service" in
  *.onion) ;;
  *) rpc_hidden_service="" ;;
esac
if [ "${#rpc_hidden_service}" -ne 62 ]; then
  rpc_hidden_service=""
fi
export APP_ELECTRS_LIQUID_RPC_HIDDEN_SERVICE="$rpc_hidden_service"


