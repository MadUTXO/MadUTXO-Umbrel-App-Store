#!/bin/sh
set -e

# When started as root (manual `docker run`, or an older compose file) the data
# directory may still be root-owned. Umbrel's normal path runs this container as
# uid 1000 and pre-chowns /data via hooks/pre-start, so this is a fallback only.
if [ "$(id -u)" = "0" ] && [ "$(stat -c %u /data)" != "1000" ]; then
    chown -R electrs:electrs /data 2>/dev/null || true
fi

# --- Resolve Elements RPC password ---
# If exports.sh couldn't get it (Elements not running yet),
# try the persisted file from a previous successful start.
PASS_FILE="/data/.elements_rpc_pass"

if [ -z "$ELEMENTS_RPC_PASSWORD" ] && [ -f "$PASS_FILE" ] && [ -s "$PASS_FILE" ]; then
    # `|| true`: the file can disappear between -s and cat (e.g. a concurrent
    # rewrite); an empty read must not abort the script under `set -e`.
    ELEMENTS_RPC_PASSWORD="$(cat "$PASS_FILE" 2>/dev/null || true)"
    if [ -n "$ELEMENTS_RPC_PASSWORD" ]; then
        echo "[entrypoint] Loaded password from $PASS_FILE"
    fi
fi

if [ -n "$ELEMENTS_RPC_PASSWORD" ]; then
    # Persist for future restarts (restricted permissions).
    # Must never be fatal: the password is already in env and electrs
    # starts fine without the backup file (fixes restart loop exit 2
    # when the file is root-owned 600 from a previous install).
    echo "$ELEMENTS_RPC_PASSWORD" > "$PASS_FILE" 2>/dev/null || echo "[entrypoint] WARNING: cannot persist password, continuing with env"
    chmod 600 "$PASS_FILE" 2>/dev/null || true
    if [ "$(id -u)" = "0" ]; then
        chown electrs:electrs "$PASS_FILE" 2>/dev/null || true
    fi

    # Hand the credential to electrs through a 0600 cookie file instead of the
    # command line: argv is world-readable in /proc, a 0600 file is not.
    # electrs reads <daemon-dir>/<network>/.cookie, and --jsonrpc-import means
    # it never reads blk files from there, so only the cookie is used.
    COOKIE_DIR="${ELECTRS_COOKIE_DIR:-/data/.electrs}"
    mkdir -p "$COOKIE_DIR/liquidv1"
    ( umask 077; printf 'elements:%s' "$ELEMENTS_RPC_PASSWORD" > "$COOKIE_DIR/liquidv1/.cookie" )
    chmod 600 "$COOKIE_DIR/liquidv1/.cookie"
    if [ "$(id -u)" = "0" ]; then
        chown -R electrs:electrs "$COOKIE_DIR" 2>/dev/null || true
        exec gosu electrs electrs "$@" --daemon-dir "$COOKIE_DIR"
    fi
    exec electrs "$@" --daemon-dir "$COOKIE_DIR"
fi

# No password available — run as-is (will fail, restart: always retries)
echo "[entrypoint] WARNING: No Elements RPC password found"
if [ "$(id -u)" = "0" ]; then
    exec gosu electrs electrs "$@"
fi
exec electrs "$@"
