#!/bin/bash
#
# Headscale Entrypoint - Suppresses key from logs, saves to file for UI
#

set -e

KEY_FILE="/var/lib/headscale/preauth_key.txt"

echo "=== Starting Headscale ==="

# Run headscale init in background
/opt/src/run.sh &
HS_PID=$!

# Wait for initialization
for i in $(seq 1 30); do
    if [ -S /var/run/headscale/headscale.sock ]; then
        break
    fi
    sleep 1
done

# Generate pre-auth key (suppress output to logs)
if [ ! -f "$KEY_FILE" ]; then
    KEY_OUTPUT=$(headscale -c /etc/headscale/config.yaml preauthkeys create --reusable --expiration 720h 2>/dev/null)
    KEY=$(echo "$KEY_OUTPUT" | grep -oP 'Key: \K[^\s]+' || echo "")
    if [ -n "$KEY" ]; then
        echo "$KEY" > "$KEY_FILE"
        chmod 600 "$KEY_FILE"
    fi
fi

# Wait for headscale process
wait $HS_PID
