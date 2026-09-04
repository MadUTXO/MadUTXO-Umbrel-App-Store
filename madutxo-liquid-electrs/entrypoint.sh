#!/bin/sh
set -e

# Ensure data directory is owned by electrs user
# Umbrel creates volumes as root, but electrs runs as uid 1000
if [ "$(stat -c %u /data)" != "1000" ]; then
    chown -R electrs:electrs /data
fi

# --- Resolve Elements RPC password ---
# If exports.sh couldn't get it (Elements not running yet),
# try the persisted file from a previous successful start.
PASS_FILE="/data/.elements_rpc_pass"

if [ -z "$ELEMENTS_RPC_PASSWORD" ] && [ -f "$PASS_FILE" ] && [ -s "$PASS_FILE" ]; then
    ELEMENTS_RPC_PASSWORD="$(cat "$PASS_FILE")"
    echo "[entrypoint] Loaded password from $PASS_FILE"
fi

if [ -n "$ELEMENTS_RPC_PASSWORD" ]; then
    # Persist for future restarts (restricted permissions)
    echo "$ELEMENTS_RPC_PASSWORD" > "$PASS_FILE"
    chmod 600 "$PASS_FILE"
    chown electrs:electrs "$PASS_FILE"
    # Append --cookie (clap uses last value, overrides any empty one from compose)
    exec gosu electrs electrs "$@" --cookie "elements:${ELEMENTS_RPC_PASSWORD}"
fi

# No password available — run as-is (will fail, restart: always retries)
echo "[entrypoint] WARNING: No Elements RPC password found"
exec gosu electrs electrs "$@"
