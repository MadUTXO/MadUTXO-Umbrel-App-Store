#!/bin/sh
# Fail when a scan's image-ref is not an image deployed by the compose file.
# Some apps list a sidecar first (electrs-liquid), so compare against every
# image, not just the first one.
set -eu
scan="$1"
compose="$2"
scanned=$(grep -E "^[[:space:]]+image-ref: '" "$scan" | sed -E "s/^[[:space:]]+image-ref: '([^']+)'.*/\1/" | head -n1)
echo "compose images:"
grep -E '^[[:space:]]+image:' "$compose" | awk '{print $2}' | tr -d '"'
echo "scan:           $scanned"
[ -n "$scanned" ] || { echo "FAIL: no image-ref in $scan"; exit 1; }
found=0
for image in $(grep -E '^[[:space:]]+image:' "$compose" | awk '{print $2}' | tr -d '"'); do
  if [ "$image" = "$scanned" ]; then found=1; break; fi
done
[ "$found" -eq 1 ] || { echo "FAIL: scan target is not deployed by $compose"; exit 1; }
echo "✓ scan target matches a compose image"
