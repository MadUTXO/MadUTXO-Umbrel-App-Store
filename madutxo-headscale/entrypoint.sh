#!/bin/bash
set -e

CONFIG_FILE="/etc/headscale/config.yaml"

# Create config directory if it doesn't exist
mkdir -p /etc/headscale

# Copy config if it doesn't exist (mounted from APP_DATA_DIR)
if [ ! -f "$CONFIG_FILE" ]; then
    if [ -f "/data/config.yaml" ]; then
        cp /data/config.yaml "$CONFIG_FILE"
    elif [ -f "/data/headscale/config.yaml" ]; then
        cp /data/headscale/config.yaml "$CONFIG_FILE"
    fi
fi

# Ensure data directory exists
mkdir -p /var/lib/headscale

# Execute the main command
exec "$@"