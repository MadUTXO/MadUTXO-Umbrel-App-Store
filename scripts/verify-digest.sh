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

# 2. Verify a pinned digest actually resolves in its registry.
#    rc 0 = exists, 1 = definitively missing (FAIL), 2 = could not verify (WARN).
#    A 404 is a hard failure: a well-formed but unpublished digest must not pass.
#    A network/token problem is only a warning so a registry outage cannot redden CI.
verify_manifest() {
  v_img="$1"
  v_digest="${v_img##*@}"
  case "$v_digest" in sha256:*) ;; *) echo "  ! no sha256 digest"; return 2 ;; esac

  v_ref="${v_img%%@*}"
  v_reg="docker.io"
  v_repo="$v_ref"
  case "$v_ref" in
    */*)
      v_first="${v_ref%%/*}"
      case "$v_first" in
        *.*|*:*|localhost) v_reg="$v_first"; v_repo="${v_ref#*/}" ;;
      esac
      ;;
  esac
  v_repo="${v_repo%%:*}"

  if [ "$v_reg" = "docker.io" ]; then
    case "$v_repo" in */*) ;; *) v_repo="library/$v_repo" ;; esac
    v_tokurl="https://auth.docker.io/token?service=registry.docker.io&scope=repository:${v_repo}:pull"
    v_murl="https://registry-1.docker.io/v2/${v_repo}/manifests/${v_digest}"
  else
    v_tokurl="https://${v_reg}/token?scope=repository:${v_repo}:pull&service=${v_reg}"
    v_murl="https://${v_reg}/v2/${v_repo}/manifests/${v_digest}"
  fi

  v_token=$(curl -fsSL "$v_tokurl" 2>/dev/null | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  if [ -z "$v_token" ]; then echo "  $v_reg/$v_repo: no anonymous token"; return 2; fi

  v_code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $v_token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' "$v_murl" 2>/dev/null)
  case "$v_code" in
    200) echo "  ✓ $v_reg/$v_repo digest exists"; return 0 ;;
    404) echo "  FAIL: $v_reg/$v_repo digest not found (unpublished or wrong digest)"; return 1 ;;
    *)   echo "  ⚠ $v_reg/$v_repo unverifiable (http=$v_code)"; return 2 ;;
  esac
}

# Verify every pinned image across the store. Sets VM_FAIL=1 if any digest is
# definitively missing, VM_WARN=1 if any could not be verified (network/token).
verify_all_manifests() {
  VM_FAIL=0
  VM_WARN=0
  for vm_image in \
    "$IMAGE" \
    "$LIBRE_IMAGE" \
    "$TORLINK_IMAGE" \
    "$ROUTSTRD_IMAGE"; do
    echo "Checking manifest: $vm_image"
    vm_rc=0
    verify_manifest "$vm_image" || vm_rc=$?
    case "$vm_rc" in
      1) VM_FAIL=1 ;;
      2) VM_WARN=1 ;;
    esac
  done
}

# 3. Verify Dockerfile ELECTRS_SHA matches umbrel-app version intent
SHA=$(grep -E "ARG ELECTRS_SHA=" "$DOCKERFILE" | cut -d= -f2 | tr -d '"' | head -n1)
echo "Dockerfile ELECTRS_SHA: $SHA"
if [ -z "$SHA" ]; then echo "FAIL: ELECTRS_SHA not found in Dockerfile"; exit 1; fi
echo "✓ Dockerfile ELECTRS_SHA present"

# 4. Verify the umbrel-app version pairs with the intended image series
VERSION=$(grep -E '^version: "' "$APP_YML" | head -n1 | cut -d'"' -f2)
echo "Umbrel app version: $VERSION"
IMAGE_TAG=$(echo "$IMAGE" | sed -n 's/.*electrs-liquid:\(.*\)@.*/\1/p')
echo "Image tag: $IMAGE_TAG"
# The app version series is independent of the image series; just ensure not latest.
if echo "$IMAGE" | grep -q ":latest"; then echo "FAIL: Image uses latest tag"; exit 1; fi
echo "✓ Image not latest"
# The app version (1.0.x) pairs with image 0.6.x. Guard against a typo that
# silently points the app at a different image series.
case "$VERSION" in
  1.0.*)
    case "$IMAGE_TAG" in
      0.6.*) echo "✓ App $VERSION maps to image $IMAGE_TAG" ;;
      *) echo "FAIL: App $VERSION should map to a 0.6.x image, got $IMAGE_TAG"; exit 1 ;;
    esac
    ;;
esac

echo "--- LibreTranslate digest ---"
LIBRE_COMPOSE="$ROOT/madutxo-libretranslate/docker-compose.yml"
LIBRE_IMAGE=$(grep -E "image: ghcr.io/madutxo/libretranslate:" "$LIBRE_COMPOSE" | head -n1 | awk '{print $2}' | tr -d '"')
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

echo "--- routstrd digest ---"
ROUTSTRD_COMPOSE="$ROOT/madutxo-routstrd/docker-compose.yml"
ROUTSTRD_APP="$ROOT/madutxo-routstrd/umbrel-app.yml"
ROUTSTRD_IMAGE=$(grep -E "image: ghcr.io/madutxo/routstrd:" "$ROUTSTRD_COMPOSE" | head -n1 | awk '{print $2}' | tr -d '"')
echo "routstrd image: $ROUTSTRD_IMAGE"
case "$ROUTSTRD_IMAGE" in
  *@sha256:* ) echo "✓ routstrd image pinned" ;;
  *) echo "FAIL: routstrd image not pinned with @sha256:"; exit 1 ;;
esac
if echo "$ROUTSTRD_IMAGE" | grep -q ":latest"; then echo "FAIL: routstrd image uses latest"; exit 1; fi
echo "✓ routstrd image not latest"
case "$ROUTSTRD_IMAGE" in
  *@sha256:0000000000000000000000000000000000000000000000000000000000000000)
    echo "FAIL: routstrd image uses the unpublished placeholder digest; publish the image and pin the real manifest-list digest";
    exit 1 ;;
esac
ROUTSTRD_VERSION=$(grep -E '^version: "' "$ROUTSTRD_APP" | head -n1 | cut -d'"' -f2)
ROUTSTRD_IMAGE_TAG=$(echo "$ROUTSTRD_IMAGE" | sed -n 's/.*routstrd:\(.*\)@.*/\1/p')
echo "routstrd app version: $ROUTSTRD_VERSION"
echo "routstrd image tag: $ROUTSTRD_IMAGE_TAG"
if [ "$ROUTSTRD_VERSION" != "$ROUTSTRD_IMAGE_TAG" ]; then echo "FAIL: routstrd app version and image tag differ"; exit 1; fi
echo "✓ routstrd version matches image tag"

echo "--- registry manifest checks ---"
if command -v curl >/dev/null 2>&1; then
  verify_all_manifests
  if [ "$VM_FAIL" -eq 1 ]; then
    echo "FAIL: at least one pinned digest does not resolve; publish the image or fix the digest"
    exit 1
  elif [ "$VM_WARN" -eq 1 ]; then
    echo "⚠ some digests could not be verified (registry unreachable); format checks still passed"
  else
    echo "✓ all pinned digests resolve in their registries"
  fi
else
  echo "⚠ curl not available, skipping registry manifest checks"
fi

echo "All digest format checks passed"
