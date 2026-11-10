#!/bin/sh
set -eu

STATE="${TORLINK_STATE_DIR:-/state}"
export TORLINK_STATE_DIR="$STATE"
export HOME="${HOME:-$STATE/home}"
export TMUX_TMPDIR="${TMUX_TMPDIR:-/state/tmux}"

mkdir -p "$STATE/config" "$STATE/data" "$HOME" "$TMUX_TMPDIR"

if ! mkdir -p /downloads 2>/dev/null || [ ! -w /downloads ]; then
    echo "[torlink] WARNING: /downloads is not writable; downloads will fail until it is" >&2
fi

CONFIG="$STATE/config/config.json"
if [ ! -f "$CONFIG" ]; then
    tmp="${CONFIG}.tmp.$$"
    printf '%s\n' '{"downloadDir":"/downloads","trackers":[]}' > "$tmp"
    mv "$tmp" "$CONFIG"
    chmod 600 "$CONFIG"
fi

# -O (check-origin): refuse WebSocket upgrades whose Origin host does not match
# the Host header. ttyd defaults this OFF; without it a page the operator visits
# can open a cross-site WebSocket to this writable terminal. Umbrel's ingress
# proxies with changeOrigin:false (Host preserved), so Origin and Host match for
# legitimate same-origin loads.
#
# ttyd binds loopback only. nginx listens on 7681 and refuses every
# source in the shared app bridge (10.21.0.0/16) except the Umbrel gateway, so a
# co-resident container cannot reach the writable terminal even by forging
# Host/Origin. -O is kept as defense-in-depth for browser cross-origin attacks.
nginx -g 'daemon off;' &
NGINX_PID=$!

ttyd -O -W -p 7682 -i 127.0.0.1 -w /app -t disableLeaveAlert=true -t title=TorLink node /app/dist/cli.cjs attach &
TTYD_PID=$!

# If ttyd exits, stop nginx so the container exits and `restart: on-failure`
# brings it back, instead of serving 502 forever behind a green process.
(
    while kill -0 "$TTYD_PID" 2>/dev/null; do sleep 2; done
    kill -TERM "$NGINX_PID" 2>/dev/null
) &
WATCHDOG_PID=$!

# Forward container stop to both processes so torlink can release the engine.
trap 'kill -TERM "$TTYD_PID" "$NGINX_PID" 2>/dev/null || true; exit 0' TERM INT

wait "$NGINX_PID"
kill -TERM "$TTYD_PID" 2>/dev/null || true
kill -TERM "$WATCHDOG_PID" 2>/dev/null || true
wait "$TTYD_PID" 2>/dev/null || true
exit 1
