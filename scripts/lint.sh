#!/bin/sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="$ROOT/madutxo-liquid-electrs/docker-compose.yml"
INDEX="$ROOT/madutxo-liquid-electrs/web/index.html"
echo "Lint: checking $COMPOSE..."
# Check all images are digest-pinned (contain @sha256:)
if grep -E "image:.*:[^ ]+" "$COMPOSE" | grep -v "@sha256:" | grep -v "^#"; then
  echo "FAIL: Found unpinned image (missing @sha256:)"
  grep -E "image:.*:[^ ]+" "$COMPOSE" | grep -v "@sha256:"
  exit 1
fi
echo "✓ All images pinned"
if grep -q "privileged: true" "$COMPOSE"; then echo "FAIL: privileged: true found"; exit 1; fi
echo "✓ No privileged"
if grep -q "docker.sock" "$COMPOSE"; then echo "FAIL: docker.sock mount found"; exit 1; fi
echo "✓ No docker.sock"
for svc in web api_cors electrs tor app_proxy; do
  if ! grep -A30 "  $svc:" "$COMPOSE" | grep -q "no-new-privileges:true"; then echo "FAIL: $svc missing no-new-privileges"; exit 1; fi
done
echo "✓ no-new-privileges present"
if grep -q '"3000:3000"' "$COMPOSE"; then echo "FAIL: Host 3000 still exposed"; exit 1; fi
echo "✓ Host 3000 not exposed"
if grep -q '9130:9130' "$COMPOSE"; then echo "FAIL: 9130 host-exposed"; exit 1; fi
echo "✓ 9130 not host-exposed, CORS restrictive"
if grep -q "Access-Control-Allow-Origin \\*" "$COMPOSE"; then echo "FAIL: wildcard CORS * found"; exit 1; fi
echo "✓ No wildcard CORS"
if grep -q "ELECTRS_TOR_ADDRESS" "$INDEX"; then echo "FAIL: index.html still contains ELECTRS_TOR_ADDRESS interpolation"; exit 1; fi
echo "✓ No direct ELECTRS_TOR_ADDRESS interpolation"
echo "All lint checks passed"
