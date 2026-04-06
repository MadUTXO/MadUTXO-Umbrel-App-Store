#!/bin/bash
set -e

CONFIG_FILE="/etc/headscale/config.yaml"

# Create directories
mkdir -p /etc/headscale /var/lib/headscale

# If config doesn't exist, download from GitHub
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Downloading Headscale config from GitHub..."
    wget -q -O "$CONFIG_FILE" "https://raw.githubusercontent.com/MadUTXO/community-umbrel-apps/master/madutxo-headscale/config.yaml"
fi

# Execute the main command
exec "$@"