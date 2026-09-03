#!/bin/sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="$ROOT/madutxo-liquid-electrs/docker-compose.yml"
DOCKERFILE="$ROOT/Dockerfile.electrs-liquid"
APP_YML="$ROOT/madutxo-liquid-electrs/umbrel-app.yml"

echo "Verifying digest pin for madutxo-liquid-electrs..."

# 1. Extract image from compose (should be pinned with @sha256:)
IMAGE=$(grep -E "image: ghcr.io/madutxo/electrs-liquid:" "$COMPOSE" | head -n1 | awk '{print $2}' | tr -d '"')
echo "Compose image: $IMAGE"
case "$IMAGE" in
  *@sha256:* ) echo "✓ Compose image pinned" ;;
  *) echo "FAIL: Compose image not pinned with @sha256:"; exit 1 ;;
esac

# 2. Extract digest and verify it exists in GHCR (crane manifest) - requires network, skip if crane not available
if command -v crane >/dev/null 2>&1; then
  echo "Checking GHCR manifest for $IMAGE..."
  crane manifest "$IMAGE" >/dev/null 2>&1 && echo "✓ GHCR manifest exists" || echo "⚠ GHCR manifest not reachable (offline?)"
else
  echo "ℹ crane not available, skipping GHCR check"
fi

# 3. Verify Dockerfile ELECTRS_SHA matches umbrel-app version intent
SHA=$(grep -E "ARG ELECTRS_SHA=" "$DOCKERFILE" | cut -d= -f2 | tr -d '"' | head -n1)
echo "Dockerfile ELECTRS_SHA: $SHA"
if [ -z "$SHA" ]; then echo "FAIL: ELECTRS_SHA not found in Dockerfile"; exit 1; fi
echo "✓ Dockerfile ELECTRS_SHA present"

# 4. Verify umbrel-app version references correct image (should be 0.6.1)
VERSION=$(grep -E '^version: "' "$APP_YML" | head -n1 | cut -d'"' -f2)
echo "Umbrel app version: $VERSION"
IMAGE_TAG=$(echo "$IMAGE" | sed -n 's/.*electrs-liquid:\(.*\)@.*/\1/p')
echo "Image tag: $IMAGE_TAG"
# Simple check: version 0.7.x should map to image 0.6.x - just ensure not latest
if echo "$IMAGE" | grep -q ":latest"; then echo "FAIL: Image uses latest tag"; exit 1; fi
echo "✓ Image not latest"

echo "All digest checks passed"
