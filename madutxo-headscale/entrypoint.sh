#!/bin/bash
set -e

# Create directories
mkdir -p /etc/headscale /var/lib/headscale

# Generate config if not exists
if [ ! -f /etc/headscale/config.yaml ]; then
    echo "Generating Headscale config..."
    /usr/local/bin/headscale configtest > /etc/headscale/config.yaml 2>&1 || true
    # If that didn't work, try the generate subcommand with output redirect
    if [ ! -s /etc/headscale/config.yaml ]; then
        /usr/local/bin/headscale configtest > /etc/headscale/config.yaml 2>&1
    fi
fi

# Execute the main command
exec /usr/local/bin/headscale "$@"