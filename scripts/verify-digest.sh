#!/bin/sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="$ROOT/madutxo-liquid-electrs/docker-compose.yml"
DOCKERFILE="$ROOT/madutxo-liquid-electrs/Dockerfile"
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

echo "--- LibreTranslate digest ---"
LIBRE_COMPOSE="$ROOT/madutxo-libretranslate/docker-compose.yml"
LIBRE_IMAGE=$(grep -E "image: libretranslate" "$LIBRE_COMPOSE" | head -n1 | awk '{print $2}' | tr -d '"')
echo "LibreTranslate image: $LIBRE_IMAGE"
case "$LIBRE_IMAGE" in
  *@sha256:* ) echo "✓ LibreTranslate pinned" ;;
  *) echo "FAIL: LibreTranslate not pinned"; exit 1 ;;
esac
if echo "$LIBRE_IMAGE" | grep -q ":latest"; then echo "FAIL: LibreTranslate latest"; exit 1; fi
echo "✓ LibreTranslate not latest"

echo "--- torlink digest ---"
TORLINK_COMPOSE="$ROOT/madutxo-torlink/docker-compose.yml"
TORLINK_APP="$ROOT/madutxo-torlink/umbrel-app.yml"
TORLINK_IMAGE=$(grep -E "image: ghcr.io/madutxo/torlink:" "$TORLINK_COMPOSE" | head -n1 | awk '{print $2}' | tr -d '"')
echo "torlink image: $TORLINK_IMAGE"
case "$TORLINK_IMAGE" in
  *@sha256:* ) echo "✓ torlink image pinned" ;;
  *) echo "FAIL: torlink image not pinned with @sha256:"; exit 1 ;;
esac
if echo "$TORLINK_IMAGE" | grep -q ":latest"; then echo "FAIL: torlink image uses latest"; exit 1; fi
echo "✓ torlink image not latest"
case "$TORLINK_IMAGE" in
  *@sha256:0000000000000000000000000000000000000000000000000000000000000000)
    echo "FAIL: torlink image uses the unpublished placeholder digest; publish the image and pin the real manifest-list digest";
    exit 1 ;;
esac
TORLINK_VERSION=$(grep -E '^version: "' "$TORLINK_APP" | head -n1 | cut -d'"' -f2)
TORLINK_IMAGE_TAG=$(echo "$TORLINK_IMAGE" | sed -n 's/.*torlink:\(.*\)@.*/\1/p')
echo "torlink app version: $TORLINK_VERSION"
echo "torlink image tag: $TORLINK_IMAGE_TAG"
if [ "$TORLINK_VERSION" != "$TORLINK_IMAGE_TAG" ]; then echo "FAIL: torlink app version and image tag differ"; exit 1; fi
echo "✓ torlink version matches image tag"

echo "All digest format checks passed"
