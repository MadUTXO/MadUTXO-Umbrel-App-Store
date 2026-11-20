#!/bin/sh
# Fail when a scan's image-ref has drifted from the deployed compose image.
set -eu
scan="$1"
compose="$2"
pinned=$(grep -E '^[[:space:]]+image:' "$compose" | awk '{print $2}' | head -n1 | tr -d '"')
scanned=$(grep -E "^[[:space:]]+image-ref: '" "$scan" | sed -E "s/^[[:space:]]+image-ref: '([^']+)'.*/\1/" | head -n1)
echo "compose: $pinned"
echo "scan:    $scanned"
[ -n "$pinned" ] || { echo "FAIL: no image in $compose"; exit 1; }
[ -n "$scanned" ] || { echo "FAIL: no image-ref in $scan"; exit 1; }
[ "$pinned" = "$scanned" ] || { echo "FAIL: scan target drifted from $compose"; exit 1; }
echo "✓ scan target matches compose"
