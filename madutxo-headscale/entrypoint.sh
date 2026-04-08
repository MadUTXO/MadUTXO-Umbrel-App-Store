#!/bin/bash
#
# Headscale Umbrel Entrypoint
# Pre-generates config, creates admin user, and saves pre-auth key to volume
#

set -e

CONFIG_MARKER="/var/lib/headscale/.initialized"
KEY_FILE="/var/lib/headscale/preauth_key.txt"

echo "=== Headscale Umbrel Setup ==="

# If already initialized, just run headscale
if [ -f "$CONFIG_MARKER" ] && [ -f "$KEY_FILE" ]; then
    echo "Headscale already initialized. Starting server..."
    exec /usr/local/bin/headscale serve -c /etc/headscale/config.yaml
fi

# Run the image's init (generates config, creates user, creates pre-auth key)
/opt/src/run.sh &
HS_PID=$!

# Wait for headscale to initialize (up to 30 seconds)
echo "Waiting for Headscale to initialize..."
for i in {1..30}; do
    if [ -S /var/run/headscale/headscale.sock ]; then
        echo "Headscale socket ready!"
        break
    fi
    sleep 1
done

# Create a reusable pre-auth key that expires in 30 days
echo "Creating pre-auth key..."
KEY_OUTPUT=$(headscale -c /etc/headscale/config.yaml preauthkeys create --reusable --expiration 720h 2>&1) || true

# Extract the key (format: "Key: <key>")
KEY=$(echo "$KEY_OUTPUT" | grep -oP 'Key: \K[^$]+' || echo "$KEY_OUTPUT")

# Save key to volume
echo "$KEY" > "$KEY_FILE"
echo "Key saved to $KEY_FILE"

echo "=== PRE-AUTH KEY (save this!) ==="
echo "$KEY"
echo "================================="

# Mark as initialized
touch "$CONFIG_MARKER"

# Wait for the original process
wait $HS_PID
