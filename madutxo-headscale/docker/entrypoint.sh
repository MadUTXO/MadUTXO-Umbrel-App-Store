#!/bin/bash
set -e

DATA_DIR="/var/lib/headscale"
CONFIG_DIR="/etc/headscale"
KEY_FILE="$DATA_DIR/api_key.txt"
COOKIE_FILE="$DATA_DIR/cookie_secret"
HEADPLANE_CONFIG="/etc/headplane/config.yaml"

echo "=== Headscale First-Start Setup ==="

mkdir -p "$DATA_DIR" "$CONFIG_DIR" "/etc/headplane" "/var/lib/headplane"

if [ ! -f "$CONFIG_DIR/config.yaml" ]; then
    echo "Creating default config.yaml..."
    cat > "$CONFIG_DIR/config.yaml" << EOF
server:
  listen_addr: 0.0.0.0:8080
  metrics_listen_addr: 0.0.0.0:9090
  grpc_listen_addr: 0.0.0.0:9090
  grpc_allow_insecure: false
  private_key_path: $DATA_DIR/private.key
  noise:
    private_key_path: $DATA_DIR/noise_private.key
  tls_letsencrypt:
    hostname: ""
    challenge_type: ""
  tls_cert_path: ""
  tls_key_path: ""
  base_domain: headscale.internal
  ephemeral_node_inactivity_timeout: 30m
  node_update_check_interval: 10s
  db_type: sqlite3
  db_path: $DATA_DIR/db.sqlite
  acme_url: https://acme-v02.api.letsencrypt.org/directory
  acme_email: ""
  logs:
    format: text
    level: info
  dns:
    base_ip: 100.64.0.1
    nameservers:
      - 1.1.1.1
      - 1.0.0.1
    magic_dns: true
    base_domain: headscale.internal
  unix_socket: $DATA_DIR/headscale.sock
  unix_socket_permission: "0770"
  grpc_socket_permission: "0770"
EOF
fi

if [ ! -f "$KEY_FILE" ]; then
    echo "Waiting for Headscale socket..."
    for i in $(seq 1 30); do
        if [ -S "$DATA_DIR/headscale.sock" ]; then
            break
        fi
        sleep 2
    done
    
    if [ -S "$DATA_DIR/headscale.sock" ]; then
        echo "Generating API key..."
        KEY=$(headscale -c "$CONFIG_DIR/config.yaml" apikeys create --expiration 8760h 2>&1 | grep -oP 'Key: \K[^\s]+' || true)
        if [ -n "$KEY" ]; then
            echo "$KEY" > "$KEY_FILE"
            chmod 600 "$KEY_FILE"
            echo "API key generated: ${KEY:0:20}..."
        else
            echo "Warning: Could not extract API key, will retry on next start"
        fi
    fi
fi

if [ ! -f "$COOKIE_FILE" ]; then
    echo "Generating cookie secret..."
    openssl rand -base64 24 > "$COOKIE_FILE"
    chmod 600 "$COOKIE_FILE"
fi

if [ ! -f "$HEADPLANE_CONFIG" ]; then
    echo "Creating Headplane config.yaml..."
    cat > "$HEADPLANE_CONFIG" << EOF
server:
  host: "0.0.0.0"
  port: 3000
  data_path: /var/lib/headplane

headscale:
  url: http://127.0.0.1:8080
  api_key_path: $KEY_FILE

integration:
  docker:
    enabled: false
EOF
fi

echo "=== Starting Headscale ==="
exec headscale -c "$CONFIG_DIR/config.yaml" serve
