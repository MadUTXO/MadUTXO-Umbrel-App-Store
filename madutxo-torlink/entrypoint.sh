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
exec ttyd -O -W -p 7681 -w /app -t disableLeaveAlert=true -t title=TorLink node /app/dist/cli.cjs attach
