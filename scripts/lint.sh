#!/bin/sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE="$ROOT/madutxo-liquid-electrs/docker-compose.yml"
INDEX="$ROOT/madutxo-liquid-electrs/web/index.html"
echo "Lint: checking $COMPOSE..."
# Use yq if available for accurate checks, fallback to grep
if command -v yq >/dev/null 2>&1; then
  echo "Using yq for checks"
  # Check all images are digest-pinned
  if yq eval '.services[].image | select(. != null) | select(test("@sha256:")|not)' "$COMPOSE" | grep -v "null" | grep -q .; then
    echo "FAIL: Found unpinned image (missing @sha256:)"
    yq eval '.services[].image' "$COMPOSE"
    exit 1
  fi
  echo "✓ All images pinned (yq)"
  # Check no-new-privileges
  for svc in web electrs tor app_proxy; do
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
  for svc in web electrs tor app_proxy; do
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
if grep -q '^  api_cors:' "$COMPOSE"; then echo "FAIL: dead api_cors service is still present"; exit 1; fi
echo "✓ no dead api_cors service"
if grep -q 'Access-Control-Allow-Origin \*' "$COMPOSE"; then echo "FAIL: wildcard CORS * found"; exit 1; fi
echo "✓ No wildcard CORS"
# Debug logging (-v) prints full REST URIs (address/scripthash/tx) and peer IPs.
if yq eval '.services.electrs.command[] | select(. == "-v")' "$COMPOSE" 2>/dev/null | grep -q '^-v$'; then
  echo "FAIL: electrs runs with -v (debug logging leaks wallet queries)"; exit 1
fi
echo "✓ electrs not in debug verbosity"
# Unbounded json-file logs grow without limit; every service must cap them.
NO_ROTATION="$(yq eval '.services | to_entries | .[] | select(.value.logging.options["max-size"] == null) | .key' "$COMPOSE" 2>/dev/null | grep -v '^null$' || true)"
if [ -n "$NO_ROTATION" ]; then
  echo "FAIL: service(s) without log rotation: $(echo $NO_ROTATION)"
  exit 1
fi
echo "✓ log rotation configured"
# electrs must not run as root: the index is host-owned and handed over by
# hooks/pre-start, so the container never needs uid 0.
if [ "$(yq eval '.services.electrs.user' "$COMPOSE" 2>/dev/null | tr -d '"')" != "1000:1000" ]; then
  echo "FAIL: electrs must run as 1000:1000"
  exit 1
fi
echo "✓ electrs runs as 1000:1000"
# The RPC credential must never appear in argv (world-readable via /proc).
# The entrypoint passes --daemon-dir and reads a 0600 cookie file instead.
if yq eval '.services.electrs.command[] | select(. == "--cookie")' "$COMPOSE" 2>/dev/null | grep -q '^--cookie$'; then
  echo "FAIL: electrs takes --cookie on the command line (argv is world-readable)"
  exit 1
fi
if grep -q 'exec gosu electrs electrs .*--cookie' "$ROOT/madutxo-liquid-electrs/entrypoint.sh"; then
  echo "FAIL: entrypoint passes --cookie on the command line"
  exit 1
fi
echo "✓ electrs credential not in argv"
# The credential must not be passed through the container environment: env is
# exposed by `docker inspect` and /proc/1/environ. exports.sh writes a 0600 file
# and the entrypoint reads it instead.
if grep -q 'ELEMENTS_RPC_PASSWORD:' "$COMPOSE"; then
  echo "FAIL: ELEMENTS_RPC_PASSWORD passed via container env (visible to docker inspect)"
  exit 1
fi
echo "✓ electrs credential not in container env"
# Umbrel's update path copies hooks/ but not arbitrary files, so the host-side
# chown must live in hooks/pre-start.
if [ ! -x "$ROOT/madutxo-liquid-electrs/hooks/pre-start" ]; then
  echo "FAIL: hooks/pre-start missing or not executable"
  exit 1
fi
if ! grep -q 'chown -R 1000:1000' "$ROOT/madutxo-liquid-electrs/hooks/pre-start"; then
  echo "FAIL: hooks/pre-start does not chown the data dir to 1000:1000"
  exit 1
fi
# exports.sh runs as root and rewrites the password file from inside
# `compose up`, i.e. after hooks/pre-start. If it leaves the file root-owned,
# the container (uid 1000) can neither read nor rewrite it, so the ownership
# hand-over must happen there and not in the hook.
if ! grep -q 'chown 1000:1000 "$pass_file"' "$ROOT/madutxo-liquid-electrs/exports.sh"; then
  echo "FAIL: exports.sh does not hand the password file to uid 1000"
  exit 1
fi
# A hook-side repair would be silently undone by exports.sh; assert it is gone.
if grep -q '\.elements_rpc_pass' "$ROOT/madutxo-liquid-electrs/hooks/pre-start"; then
  echo "FAIL: hooks/pre-start repairs the password file, but exports.sh rewrites it afterwards"
  exit 1
fi
# The recursive chown of the data dir must stay behind a uid check, otherwise
# every start walks millions of index files.
if ! grep -q 'if \[ "$(stat -c %u "$STATE")" != "1000" \]' "$ROOT/madutxo-liquid-electrs/hooks/pre-start"; then
  echo "FAIL: hooks/pre-start must guard the recursive chown behind a uid check"
  exit 1
fi
echo "✓ hooks/pre-start hands the data dir to uid 1000"
echo "✓ exports.sh hands the password file to uid 1000"
# electrs runs as uid 1000 and drops all capabilities; adding any back would only
# widen the attack surface for the root fallback nobody uses under Umbrel.
if [ "$(yq eval '.services.electrs.cap_add | length' "$COMPOSE" 2>/dev/null || echo 0)" != "0" ]; then
  echo "FAIL: electrs must not add capabilities (runs as 1000:1000)"
  exit 1
fi
echo "✓ electrs adds no capabilities"
# The web frontend listens on 8080, so it never needs NET_BIND_SERVICE.
if yq eval '.services.web.cap_add[] | select(. == "NET_BIND_SERVICE")' "$COMPOSE" 2>/dev/null | grep -q NET_BIND_SERVICE; then
  echo "FAIL: web adds NET_BIND_SERVICE but listens on 8080"
  exit 1
fi
echo "✓ web does not add NET_BIND_SERVICE"
# Umbrel's update path copies hooks/ but not web/ or the root icon, so the UI
# assets are mirrored under hooks/assets/ and synced by hooks/pre-start. The two
# copies must stay byte-identical or the refreshed UI would differ by update path.
for pair in \
  "web/index.html:hooks/assets/index.html" \
  "web/umbrel-qr-icon.svg:hooks/assets/umbrel-qr-icon.svg" \
  "icon.svg:hooks/assets/icon.svg"; do
  asset_src="$ROOT/madutxo-liquid-electrs/${pair%%:*}"
  asset_dst="$ROOT/madutxo-liquid-electrs/${pair#*:}"
  if [ ! -f "$asset_dst" ] || ! cmp -s "$asset_src" "$asset_dst"; then
    echo "FAIL: hooks/assets copy of ${pair%%:*} is missing or out of date"
    exit 1
  fi
done
echo "✓ web assets mirrored under hooks/assets"
if ! grep -q 'hooks/assets' "$ROOT/madutxo-liquid-electrs/hooks/pre-start"; then
  echo "FAIL: hooks/pre-start does not sync hooks/assets into app-data"
  exit 1
fi
echo "✓ hooks/pre-start syncs web assets"
# A failed password-file read must not abort the entrypoint under `set -e`.
if ! grep -Fq 'cat "$PASS_FILE" 2>/dev/null || true' "$ROOT/madutxo-liquid-electrs/entrypoint.sh"; then
  echo "FAIL: entrypoint password-file read is not guarded with || true"
  exit 1
fi
echo "✓ entrypoint password-file read is non-fatal"
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
# Check nginx security headers (config is inlined in the web service command
# because Umbrel's update path does not copy web/ files)
if ! grep -q "Content-Security-Policy" "$COMPOSE"; then echo "FAIL: CSP missing in web nginx config"; exit 1; fi
echo "✓ CSP present"
# X-XSS-Protection is deprecated and ignored (and can introduce XSS in old
# browsers); object-src/base-uri/form-action close the remaining CSP gaps.
if grep -q "X-XSS-Protection" "$COMPOSE"; then
  echo "FAIL: deprecated X-XSS-Protection header present"
  exit 1
fi
if ! grep -q "object-src 'none'" "$COMPOSE"; then
  echo "FAIL: CSP missing object-src/base-uri/form-action hardening"
  exit 1
fi
echo "✓ headers hardened (no X-XSS-Protection, CSP tightened)"
# The scheduled strict scan must target the image actually deployed in compose.
ELECTRS_DIGEST="$(grep -E '^[[:space:]]+image: ghcr.io/madutxo/electrs-liquid:0' "$COMPOSE" | sed 's/.*@//' | tr -d '[:space:]')"
if [ -z "$ELECTRS_DIGEST" ]; then
  echo "FAIL: cannot read the electrs image digest from compose"
  exit 1
fi
if ! grep -q "$ELECTRS_DIGEST" "$ROOT/.github/workflows/scan-electrs-liquid.yml"; then
  echo "FAIL: scheduled scan does not target the deployed electrs image ($ELECTRS_DIGEST)"
  exit 1
fi
echo "✓ scheduled scan targets the deployed image"
# Check for Tor hostname endpoint
if ! grep -q "location = /tor-address" "$COMPOSE"; then echo "FAIL: /tor-address not found"; exit 1; fi
echo "✓ Tor endpoint present"
echo "--- LibreTranslate checks ---"
LIBRE_COMPOSE="$ROOT/madutxo-libretranslate/docker-compose.yml"
echo "Lint: checking $LIBRE_COMPOSE..."
if command -v yq >/dev/null 2>&1; then
  if yq eval '.services[].image | select(. != null) | select(test("@sha256:")|not)' "$LIBRE_COMPOSE" | grep -v "null" | grep -q .; then
    echo "FAIL: LibreTranslate unpinned image"
    yq eval '.services[].image' "$LIBRE_COMPOSE"
    exit 1
  fi
  echo "✓ LibreTranslate images pinned (yq)"
  for svc in main app_proxy; do
    if ! yq eval ".services.$svc.security_opt[] | select(. == \"no-new-privileges:true\")" "$LIBRE_COMPOSE" | grep -q "no-new-privileges"; then
      echo "FAIL: LibreTranslate $svc missing no-new-privileges"
      exit 1
    fi
  done
  echo "✓ LibreTranslate no-new-privileges present"
else
  if grep -E "image:.*:[^ ]+" "$LIBRE_COMPOSE" | grep -v "@sha256:" | grep -v "^#"; then echo "FAIL: LibreTranslate unpinned"; exit 1; fi
  echo "✓ LibreTranslate images pinned"
fi
if grep -q "privileged: true" "$LIBRE_COMPOSE"; then echo "FAIL: LibreTranslate privileged"; exit 1; fi
echo "✓ LibreTranslate No privileged"
if yq eval '.services.main.read_only' "$LIBRE_COMPOSE" | grep -q "true"; then echo "✓ LibreTranslate read_only"; else echo "FAIL: LibreTranslate main missing read_only:true"; exit 1; fi

echo "--- onion address checks ---"
# Onion addresses are secrets: a committed address exposes a live node. Fail on
# any v3 (56-char) or v2 (16-char) address in tracked files. Generic `.onion`
# references (suffix checks, regex patterns, dummy.onion) are not addresses.
if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  ONION_HITS="$(git -C "$ROOT" grep -I -n -E '([a-z2-7]{56}|[a-z2-7]{16})\.onion' -- . 2>/dev/null || true)"
else
  ONION_HITS="$(grep -R -I -n -E '([a-z2-7]{56}|[a-z2-7]{16})\.onion' "$ROOT" --exclude-dir=.git --exclude-dir=node_modules 2>/dev/null || true)"
fi
if [ -n "$ONION_HITS" ]; then
  echo "FAIL: onion address found in tracked files (never commit an onion address)"
  echo "$ONION_HITS" | sed -E 's/[a-z2-7]{16,56}\.onion/<redacted>.onion/g'
  exit 1
fi
echo "✓ no onion addresses in tracked files"
# Retroactive: once pushed to a public repo, an address stays in history.
if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  # Print only commit:path so the address itself never reaches the log.
  ONION_HISTORY="$(git -C "$ROOT" rev-list --all \
    | while read -r rev; do
        git -C "$ROOT" grep -I -l -E '([a-z2-7]{56}|[a-z2-7]{16})\.onion' "$rev" -- . 2>/dev/null
      done || true)"
  if [ -n "$ONION_HISTORY" ]; then
    echo "FAIL: onion address found in git history (it is already public; rotate the service)"
    echo "$ONION_HISTORY" | sort -u | head -20
    exit 1
  fi
  echo "✓ no onion addresses in git history"
fi

echo "--- torlink checks ---"
TORLINK_COMPOSE="$ROOT/madutxo-torlink/docker-compose.yml"
TORLINK_APP="$ROOT/madutxo-torlink/umbrel-app.yml"
echo "Lint: checking $TORLINK_COMPOSE..."
if command -v yq >/dev/null 2>&1; then
  if yq eval '.services[].image | select(. != null) | select(test("@sha256:")|not)' "$TORLINK_COMPOSE" | grep -v "null" | grep -q .; then
    echo "FAIL: torlink unpinned image"
    yq eval '.services[].image' "$TORLINK_COMPOSE"
    exit 1
  fi
  echo "✓ torlink images pinned (yq)"
  for svc in torlink app_proxy; do
    if ! yq eval ".services.$svc.security_opt[] | select(. == \"no-new-privileges:true\")" "$TORLINK_COMPOSE" | grep -q "no-new-privileges"; then
      echo "FAIL: torlink $svc missing no-new-privileges"
      exit 1
    fi
  done
  echo "✓ torlink no-new-privileges present"
  if [ "$(yq eval '.services.torlink.read_only' "$TORLINK_COMPOSE")" != "true" ]; then
    echo "FAIL: torlink missing read_only:true"
    exit 1
  fi
  echo "✓ torlink read_only"
  if ! yq eval '.services.torlink.cap_drop[] | select(. == "ALL")' "$TORLINK_COMPOSE" | grep -q "ALL"; then
    echo "FAIL: torlink missing cap_drop: ALL"
    exit 1
  fi
  echo "✓ torlink cap_drop ALL"
  if [ "$(yq eval '.services.torlink.user' "$TORLINK_COMPOSE" | tr -d '"')" != "1000:1000" ]; then
    echo "FAIL: torlink must run as 1000:1000"
    exit 1
  fi
  echo "✓ torlink runs as 1000:1000"
else
  if grep -E "image:.*:[^ ]+" "$TORLINK_COMPOSE" | grep -v "@sha256:" | grep -v "^#"; then echo "FAIL: torlink unpinned"; exit 1; fi
  echo "✓ torlink images pinned"
  for svc in torlink app_proxy; do
    if ! grep -A30 "  $svc:" "$TORLINK_COMPOSE" | grep -q "no-new-privileges:true"; then echo "FAIL: torlink $svc missing no-new-privileges"; exit 1; fi
  done
  echo "✓ torlink no-new-privileges present"
  if ! grep -A30 "  torlink:" "$TORLINK_COMPOSE" | grep -q "read_only: true"; then echo "FAIL: torlink missing read_only:true"; exit 1; fi
  echo "✓ torlink read_only"
  if ! grep -A30 "  torlink:" "$TORLINK_COMPOSE" | grep -q -- "- ALL"; then echo "FAIL: torlink missing cap_drop: ALL"; exit 1; fi
  echo "✓ torlink cap_drop ALL"
fi
if grep -q "privileged: true" "$TORLINK_COMPOSE"; then echo "FAIL: torlink privileged"; exit 1; fi
echo "✓ torlink No privileged"
if grep -q "docker.sock" "$TORLINK_COMPOSE"; then echo "FAIL: torlink docker.sock mount"; exit 1; fi
echo "✓ torlink No docker.sock"
if grep -Eq '^[[:space:]]+ports:' "$TORLINK_COMPOSE"; then echo "FAIL: torlink publishes a host port"; exit 1; fi
echo "✓ torlink no host ports"
for env in TORLINK_NO_WEBRTC TORLINK_NO_UTP TORLINK_NO_UPDATE_CHECK; do
  if ! grep -q "$env" "$TORLINK_COMPOSE"; then echo "FAIL: torlink missing $env"; exit 1; fi
done
echo "✓ torlink runtime hardening env present"
if ! grep -q "STORAGE_DOWNLOADS" "$TORLINK_APP"; then echo "FAIL: torlink missing STORAGE_DOWNLOADS permission"; exit 1; fi
if ! grep -q "dataRoot: data" "$TORLINK_APP"; then echo "FAIL: torlink missing storage.dataRoot"; exit 1; fi
echo "✓ torlink downloads permission and storage root"

echo "--- routstrd checks ---"
ROUTSTRD_COMPOSE="$ROOT/madutxo-routstrd/docker-compose.yml"
ROUTSTRD_APP="$ROOT/madutxo-routstrd/umbrel-app.yml"
echo "Lint: checking $ROUTSTRD_COMPOSE..."
if command -v yq >/dev/null 2>&1; then
  if yq eval '.services[].image | select(. != null) | select(test("@sha256:")|not)' "$ROUTSTRD_COMPOSE" | grep -v "null" | grep -q .; then
    echo "FAIL: routstrd unpinned image"
    yq eval '.services[].image' "$ROUTSTRD_COMPOSE"
    exit 1
  fi
  echo "✓ routstrd images pinned (yq)"
  for svc in app app_proxy; do
    if ! yq eval ".services.$svc.security_opt[] | select(. == \"no-new-privileges:true\")" "$ROUTSTRD_COMPOSE" | grep -q "no-new-privileges"; then
      echo "FAIL: routstrd $svc missing no-new-privileges"
      exit 1
    fi
  done
  echo "✓ routstrd no-new-privileges present"
  if [ "$(yq eval '.services.app.read_only' "$ROUTSTRD_COMPOSE")" != "true" ]; then
    echo "FAIL: routstrd missing read_only:true"
    exit 1
  fi
  echo "✓ routstrd read_only"
  if ! yq eval '.services.app.cap_drop[] | select(. == "ALL")' "$ROUTSTRD_COMPOSE" | grep -q "ALL"; then
    echo "FAIL: routstrd missing cap_drop: ALL"
    exit 1
  fi
  echo "✓ routstrd cap_drop ALL"
  if [ "$(yq eval '.services.app.user' "$ROUTSTRD_COMPOSE" | tr -d '"')" != "1000:1000" ]; then
    echo "FAIL: routstrd must run as 1000:1000"
    exit 1
  fi
  echo "✓ routstrd runs as 1000:1000"
else
  if grep -E "image:.*:[^ ]+" "$ROUTSTRD_COMPOSE" | grep -v "@sha256:" | grep -v "^#"; then echo "FAIL: routstrd unpinned"; exit 1; fi
  echo "✓ routstrd images pinned"
  for svc in app app_proxy; do
    if ! grep -A30 "  $svc:" "$ROUTSTRD_COMPOSE" | grep -q "no-new-privileges:true"; then echo "FAIL: routstrd $svc missing no-new-privileges"; exit 1; fi
  done
  echo "✓ routstrd no-new-privileges present"
  if ! grep -A30 "  app:" "$ROUTSTRD_COMPOSE" | grep -q "read_only: true"; then echo "FAIL: routstrd missing read_only:true"; exit 1; fi
  echo "✓ routstrd read_only"
  if ! grep -A30 "  app:" "$ROUTSTRD_COMPOSE" | grep -q -- "- ALL"; then echo "FAIL: routstrd missing cap_drop: ALL"; exit 1; fi
  echo "✓ routstrd cap_drop ALL"
fi
if grep -q "privileged: true" "$ROUTSTRD_COMPOSE"; then echo "FAIL: routstrd privileged"; exit 1; fi
echo "✓ routstrd No privileged"
if grep -q "docker.sock" "$ROUTSTRD_COMPOSE"; then echo "FAIL: routstrd docker.sock mount"; exit 1; fi
echo "✓ routstrd No docker.sock"
if grep -Eq '^[[:space:]]+ports:' "$ROUTSTRD_COMPOSE"; then echo "FAIL: routstrd publishes a host port"; exit 1; fi
echo "✓ routstrd no host ports"
if ! grep -q "PROXY_AUTH_WHITELIST" "$ROUTSTRD_COMPOSE"; then echo "FAIL: routstrd missing PROXY_AUTH_WHITELIST"; exit 1; fi
echo "✓ routstrd API whitelist present"
if ! grep -q "dataRoot: data" "$ROUTSTRD_APP"; then echo "FAIL: routstrd missing storage.dataRoot"; exit 1; fi
echo "✓ routstrd storage root"

echo "All lint checks passed"
# Historical regression tests (informational, not failing)
echo "--- Historical checks (should fail on old configs) ---"
for rev in HEAD~3 HEAD~2 HEAD~1; do
  if git cat-file -e "$rev:madutxo-liquid-electrs/docker-compose.yml" 2>/dev/null; then
    echo "Testing $rev..."
    git show "$rev:madutxo-liquid-electrs/docker-compose.yml" 2>/dev/null | grep -q '"3000:3000"' && echo "  $rev: would FAIL Host 3000 (expected for old)" || echo "  $rev: PASS Host 3000"
  fi
done
