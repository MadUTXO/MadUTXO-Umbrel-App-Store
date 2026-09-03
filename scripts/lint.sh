#!/bin/sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="$ROOT/madutxo-liquid-electrs/docker-compose.yml"
INDEX="$ROOT/madutxo-liquid-electrs/web/index.html"
NGINX="$ROOT/madutxo-liquid-electrs/web/nginx.conf"
echo "Lint: checking $COMPOSE..."
# Use yq if available for accurate checks, fallback to grep
if command -v yq >/dev/null 2>&1; then
  echo "Using yq for checks"
  # Check all images are digest-pinned
  if yq eval '.services[].image | select(test("@sha256:")|not)' "$COMPOSE" | grep -v "null" | grep -q .; then
    echo "FAIL: Found unpinned image (missing @sha256:)"
    yq eval '.services[].image' "$COMPOSE"
    exit 1
  fi
  echo "✓ All images pinned (yq)"
  # Check no-new-privileges
  for svc in web api_cors electrs tor app_proxy; do
    if ! yq eval ".services.$svc.security_opt[] | select(. == \"no-new-privileges:true\")" "$COMPOSE" | grep -q "no-new-privileges"; then
      echo "FAIL: $svc missing no-new-privileges (yq)"
      exit 1
    fi
  done
  echo "✓ no-new-privileges present (yq)"
else
  echo "yq not available, using grep fallback"
  if grep -E "image:.*:[^ ]+" "$COMPOSE" | grep -v "@sha256:" | grep -v "^#"; then
    echo "FAIL: Found unpinned image (missing @sha256:)"
    exit 1
  fi
  echo "✓ All images pinned"
  for svc in web api_cors electrs tor app_proxy; do
    if ! grep -A30 "  $svc:" "$COMPOSE" | grep -q "no-new-privileges:true"; then echo "FAIL: $svc missing no-new-privileges"; exit 1; fi
  done
  echo "✓ no-new-privileges present"
fi
if grep -q "privileged: true" "$COMPOSE"; then echo "FAIL: privileged: true found"; exit 1; fi
echo "✓ No privileged"
if grep -q "docker.sock" "$COMPOSE"; then echo "FAIL: docker.sock mount found"; exit 1; fi
echo "✓ No docker.sock"
if grep -q '"3000:3000"' "$COMPOSE"; then echo "FAIL: Host 3000 still exposed"; exit 1; fi
echo "✓ Host 3000 not exposed"
if grep -q '9130:9130' "$COMPOSE"; then echo "FAIL: 9130 host-exposed"; exit 1; fi
echo "✓ 9130 not host-exposed"
if grep -q 'Access-Control-Allow-Origin \*' "$COMPOSE"; then echo "FAIL: wildcard CORS * found"; exit 1; fi
echo "✓ No wildcard CORS"
# SEC-005: Allow baked ELECTRS_TOR_ADDRESS if sanitized (contains replace/sanitize), but not raw unsanitized
if grep -q "ELECTRS_TOR_ADDRESS" "$INDEX"; then
  if ! grep -q "replace.*a-zA-Z0-9" "$INDEX"; then
    echo "FAIL: index.html contains ELECTRS_TOR_ADDRESS without sanitize"
    exit 1
  fi
  echo "✓ ELECTRS_TOR_ADDRESS interpolation sanitized"
else
  echo "✓ No direct ELECTRS_TOR_ADDRESS interpolation (fetch only)"
fi
# Check nginx security headers
if ! grep -q "Content-Security-Policy" "$NGINX"; then echo "FAIL: CSP missing in nginx.conf"; exit 1; fi
echo "✓ CSP present"
# Check for Tor hostname endpoint
if ! grep -q "location = /tor-address" "$NGINX"; then echo "FAIL: /tor-address not found"; exit 1; fi
echo "✓ Tor endpoint present"
echo "All lint checks passed"
# Historical regression tests (informational, not failing)
echo "--- Historical checks (should fail on old configs) ---"
for rev in HEAD~3 HEAD~2 HEAD~1; do
  if git cat-file -e "$rev:madutxo-liquid-electrs/docker-compose.yml" 2>/dev/null; then
    echo "Testing $rev..."
    git show "$rev:madutxo-liquid-electrs/docker-compose.yml" 2>/dev/null | grep -q '"3000:3000"' && echo "  $rev: would FAIL Host 3000 (expected for old)" || echo "  $rev: PASS Host 3000"
  fi
done
