#!/bin/bash
set -e

DATA_DIR="/var/lib/headscale"
KEY_FILE="$DATA_DIR/api_key.txt"

echo "=== Headscale Setup ==="

if [ ! -f "$KEY_FILE" ]; then
    echo "Generating API key..."
    sleep 5
    KEY=$(headscale apikeys create --expiration 8760h 2>&1 | grep -oP 'Key: \K[^\s]+' || true)
    if [ -n "$KEY" ]; then
        echo "$KEY" > "$KEY_FILE"
        chmod 600 "$KEY_FILE"
        echo "API key generated!"
        echo "========================================"
        echo "API Key: $KEY"
        echo "========================================"
    else
        echo "Warning: Could not extract API key"
    fi
else
    echo "API key already exists"
fi

exec "$@"