#!/bin/bash
#
# Pre-setup script for Headscale Umbrel app
# This runs once to initialize Headscale and create a pre-auth key
#

set -e

echo "=== Headscale Pre-Setup for Umbrel ==="

# Run the normal headscale init (generates config, creates admin user, creates key)
/opt/src/run.sh &

# Wait for headscale to start and initialize
sleep 10

# Wait for the unix socket
echo "Waiting for Headscale to initialize..."
for i in {1..30}; do
    if [ -S /var/run/headscale/headscale.sock ]; then
        echo "Headscale socket is ready!"
        break
    fi
    sleep 1
done

# Create a pre-auth key that doesn't expire (or expires in 30 days)
echo "Creating pre-auth key..."
KEY_OUTPUT=$(headscale -c /etc/headscale/config.yaml preauthkeys create --reusable --expiration 720h 2>&1 || true)

# Save the key to a file accessible from host
echo "$KEY_OUTPUT" > /var/lib/headscale/preauth_key.txt
echo "Key saved to /var/lib/headscale/preauth_key.txt"

# Also print it to logs
echo "=== PRE-AUTH KEY ==="
echo "$KEY_OUTPUT"
echo "==================="

# Keep container running
wait
