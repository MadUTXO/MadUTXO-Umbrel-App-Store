#!/bin/sh
set -eu

STATE="${TORLINK_STATE_DIR:-/state}"
export TORLINK_STATE_DIR="$STATE"
export HOME="${HOME:-$STATE/home}"
export TMUX_TMPDIR="${TMUX_TMPDIR:-/tmp/tmux}"

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

exec ttyd -W -p 7681 -w /app -t disableLeaveAlert=true node /app/dist/cli.cjs attach
