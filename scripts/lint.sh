#!/bin/sh
set -e
ROOT="${LINT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
COMPOSE="$ROOT/madutxo-liquid-electrs/docker-compose.yml"
INDEX="$ROOT/madutxo-liquid-electrs/web/index.html"
# Umbrel silently drops every app whose id does not start with the store id
# (app-repository.ts: `app.id.startsWith(meta.id)`), so an unprefixed id makes
# the package vanish from the dashboard with no error.
STORE_ID="$(sed -n 's/^id:[[:space:]]*"\?\([^"]*\)"\?[[:space:]]*$/\1/p' "$ROOT/umbrel-app-store.yml")"
if [ -z "$STORE_ID" ]; then
  echo "FAIL: cannot read the store id from umbrel-app-store.yml"
  exit 1
fi
for _app_yml in "$ROOT"/madutxo-*/umbrel-app.yml; do
  _app_id="$(sed -n 's/^id:[[:space:]]*//p' "$_app_yml")"
  case "$_app_id" in
    "${STORE_ID}-"*) ;;
    *)
      echo "FAIL: $(basename "$(dirname "$_app_yml")") id '${_app_id}' must start with '${STORE_ID}-'"
      exit 1
      ;;
  esac
done
echo "✓ app ids carry the store prefix"
echo "Lint: checking $COMPOSE..."
# Use yq if available for accurate checks, fallback to grep
HAS_YQ=0
if command -v yq >/dev/null 2>&1; then HAS_YQ=1; fi
if [ "$HAS_YQ" = 1 ]; then
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
ELECTRS_DEBUG=""
if [ "$HAS_YQ" = 1 ]; then
  ELECTRS_DEBUG="$(yq eval '.services.electrs.command[] | select(. == "-v")' "$COMPOSE" 2>/dev/null || true)"
elif grep -A80 '^  electrs:' "$COMPOSE" | grep -qE '^[[:space:]]*-[[:space:]]*-v[[:space:]]*$'; then
  ELECTRS_DEBUG="-v"
fi
if [ -n "$ELECTRS_DEBUG" ]; then
  echo "FAIL: electrs runs with -v (debug logging leaks wallet queries)"; exit 1
fi
echo "✓ electrs not in debug verbosity"
# Unbounded json-file logs grow without limit; every service must cap them.
if [ "$HAS_YQ" = 1 ]; then
  NO_ROTATION="$(yq eval '.services | to_entries | .[] | select(.value.logging.options["max-size"] == null) | .key' "$COMPOSE" 2>/dev/null | grep -v '^null$' || true)"
else
  NO_ROTATION=""
  for svc in $(grep -E '^  [a-z_]+:' "$COMPOSE" | sed 's/^ *//; s/:$//'); do
    if ! grep -A80 "^  $svc:" "$COMPOSE" | grep -q 'max-size:'; then
      NO_ROTATION="$NO_ROTATION $svc"
    fi
  done
fi
if [ -n "$NO_ROTATION" ]; then
  echo "FAIL: service(s) without log rotation: $(echo $NO_ROTATION)"
  exit 1
fi
echo "✓ log rotation configured"
# electrs must not run as root: the index is host-owned and handed over by
# hooks/pre-start, so the container never needs uid 0.
if [ "$HAS_YQ" = 1 ]; then
  ELECTRS_USER="$(yq eval '.services.electrs.user' "$COMPOSE" 2>/dev/null | tr -d '"' || true)"
else
  ELECTRS_USER="$(grep -A80 '^  electrs:' "$COMPOSE" | grep -m1 -E '^[[:space:]]+user:' | sed 's/.*user:[[:space:]]*//' | tr -d '"' | tr -d '[:space:]')"
fi
if [ "$ELECTRS_USER" != "1000:1000" ]; then
  echo "FAIL: electrs must run as 1000:1000"
  exit 1
fi
echo "✓ electrs runs as 1000:1000"
# The RPC credential must never appear in argv (world-readable via /proc).
# The entrypoint passes --daemon-dir and reads a 0600 cookie file instead.
ELECTRS_COOKIE=""
if [ "$HAS_YQ" = 1 ]; then
  ELECTRS_COOKIE="$(yq eval '.services.electrs.command[] | select(. == "--cookie")' "$COMPOSE" 2>/dev/null || true)"
elif grep -A80 '^  electrs:' "$COMPOSE" | grep -qE '^[[:space:]]*-[[:space:]]*--cookie[[:space:]]*$'; then
  ELECTRS_COOKIE="--cookie"
fi
if [ -n "$ELECTRS_COOKIE" ]; then
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
if [ "$HAS_YQ" = 1 ]; then
  ELECTRS_CAPS="$(yq eval '.services.electrs.cap_add | length' "$COMPOSE" 2>/dev/null || echo 0)"
else
  if grep -A80 '^  electrs:' "$COMPOSE" | grep -qE '^[[:space:]]+cap_add:'; then ELECTRS_CAPS=1; else ELECTRS_CAPS=0; fi
fi
if [ "$ELECTRS_CAPS" != "0" ]; then
  echo "FAIL: electrs must not add capabilities (runs as 1000:1000)"
  exit 1
fi
echo "✓ electrs adds no capabilities"
# The web frontend listens on 8080, so it never needs NET_BIND_SERVICE.
if [ "$HAS_YQ" = 1 ]; then
  WEB_BIND="$(yq eval '.services.web.cap_add[] | select(. == "NET_BIND_SERVICE")' "$COMPOSE" 2>/dev/null || true)"
else
  WEB_BIND="$(grep -A80 '^  web:' "$COMPOSE" | grep -v '^[[:space:]]*#' | grep NET_BIND_SERVICE || true)"
fi
if [ -n "$WEB_BIND" ]; then
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
if [ "$HAS_YQ" = 1 ]; then
  if yq eval '.services.main.read_only' "$LIBRE_COMPOSE" | grep -q "true"; then echo "✓ LibreTranslate read_only"; else echo "FAIL: LibreTranslate main missing read_only:true"; exit 1; fi
elif grep -A40 "  main:" "$LIBRE_COMPOSE" | grep -q "read_only: true"; then
  echo "✓ LibreTranslate read_only"
else
  echo "FAIL: LibreTranslate main missing read_only:true"; exit 1
fi
# The baked model tree is ~1.2 GiB, so the recursive chown must stay guarded.
if [ ! -x "$ROOT/madutxo-libretranslate/hooks/pre-start" ]; then
  echo "FAIL: LibreTranslate hooks/pre-start missing or not executable"
  exit 1
fi
if ! grep -q 'if \[ "$(stat -c %u "$STATE")" != "1000" \]' "$ROOT/madutxo-libretranslate/hooks/pre-start"; then
  echo "FAIL: LibreTranslate hooks/pre-start must guard the chown behind a uid check"
  exit 1
fi
echo "✓ LibreTranslate hook chown guarded"

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
if [ ! -x "$ROOT/madutxo-torlink/hooks/pre-start" ]; then
  echo "FAIL: torlink hooks/pre-start missing or not executable"
  exit 1
fi
if ! grep -q 'if \[ "$(stat -c %u "$STATE")" != "1000" \]' "$ROOT/madutxo-torlink/hooks/pre-start"; then
  echo "FAIL: torlink hooks/pre-start must guard the chown behind a uid check"
  exit 1
fi
echo "✓ torlink hook chown guarded"

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

echo "--- rustdesk-server checks ---"
RUSTDESK_COMPOSE="$ROOT/madutxo-rustdesk-server/docker-compose.yml"
RUSTDESK_APP="$ROOT/madutxo-rustdesk-server/umbrel-app.yml"
echo "Lint: checking $RUSTDESK_COMPOSE..."
if command -v yq >/dev/null 2>&1; then
  if yq eval '.services[].image | select(. != null) | select(test("@sha256:")|not)' "$RUSTDESK_COMPOSE" | grep -v "null" | grep -q .; then
    echo "FAIL: rustdesk-server unpinned image"
    yq eval '.services[].image' "$RUSTDESK_COMPOSE"
    exit 1
  fi
  echo "✓ rustdesk-server images pinned (yq)"
  for svc in hbbs hbbr web; do
    if ! yq eval ".services.$svc.security_opt[] | select(. == \"no-new-privileges:true\")" "$RUSTDESK_COMPOSE" | grep -q "no-new-privileges"; then
      echo "FAIL: rustdesk-server $svc missing no-new-privileges"
      exit 1
    fi
  done
  echo "✓ rustdesk-server no-new-privileges present"
  for svc in hbbs hbbr web; do
    if [ "$(yq eval ".services.$svc.read_only" "$RUSTDESK_COMPOSE")" != "true" ]; then
      echo "FAIL: rustdesk-server $svc missing read_only:true"
      exit 1
    fi
  done
  echo "✓ rustdesk-server read_only"
  for svc in hbbs hbbr web; do
    if ! yq eval ".services.$svc.cap_drop[] | select(. == \"ALL\")" "$RUSTDESK_COMPOSE" | grep -q "ALL"; then
      echo "FAIL: rustdesk-server $svc missing cap_drop: ALL"
      exit 1
    fi
  done
  echo "✓ rustdesk-server cap_drop ALL"
  for svc in hbbs hbbr; do
    if [ "$(yq eval ".services.$svc.user" "$RUSTDESK_COMPOSE" | tr -d '"')" != "1000:1000" ]; then
      echo "FAIL: rustdesk-server $svc must run as 1000:1000"
      exit 1
    fi
  done
  echo "✓ rustdesk-server hbbs/hbbr run as 1000:1000"
  # The nginx image needs its root entrypoint to drop to the nginx user, so it
  # must not be forced to 1000:1000; it must add the drop-privilege caps
  # instead, and it must not need NET_BIND_SERVICE (it listens on 8080).
  WEB_USER="$(yq eval '.services.web.user' "$RUSTDESK_COMPOSE" 2>/dev/null | tr -d '"')"
  if [ -n "$WEB_USER" ] && [ "$WEB_USER" != "null" ]; then
    echo "FAIL: rustdesk-server web must not force a user (nginx drops privileges itself)"
    exit 1
  fi
  for cap in CHOWN SETGID SETUID; do
    if ! yq eval ".services.web.cap_add[] | select(. == \"$cap\")" "$RUSTDESK_COMPOSE" | grep -q "$cap"; then
      echo "FAIL: rustdesk-server web missing cap_add $cap"
      exit 1
    fi
  done
  echo "✓ rustdesk-server web drops privileges via cap_add"
  if yq eval '.services.web.cap_add[] | select(. == "NET_BIND_SERVICE")' "$RUSTDESK_COMPOSE" | grep -q NET_BIND_SERVICE; then
    echo "FAIL: rustdesk-server web adds NET_BIND_SERVICE but listens on 8080"
    exit 1
  fi
  echo "✓ rustdesk-server web does not add NET_BIND_SERVICE"
  # app_proxy.APP_PORT must match the port the web service actually listens on.
  if [ "$(yq eval '.services.app_proxy.environment.APP_PORT' "$RUSTDESK_COMPOSE" | tr -d '"')" != "$(yq eval '.services.web.expose[0]' "$RUSTDESK_COMPOSE" | tr -d '"')" ]; then
    echo "FAIL: rustdesk-server APP_PORT does not match the web service listen port"
    exit 1
  fi
  echo "✓ rustdesk-server APP_PORT matches the web listen port"
else
  if grep -E "image:.*:[^ ]+" "$RUSTDESK_COMPOSE" | grep -v "@sha256:" | grep -v "^#"; then echo "FAIL: rustdesk-server unpinned"; exit 1; fi
  echo "✓ rustdesk-server images pinned"
  for svc in hbbs hbbr web; do
    if ! grep -A40 "  $svc:" "$RUSTDESK_COMPOSE" | grep -q "no-new-privileges:true"; then echo "FAIL: rustdesk-server $svc missing no-new-privileges"; exit 1; fi
  done
  echo "✓ rustdesk-server no-new-privileges present"
  for svc in hbbs hbbr web; do
    if ! grep -A40 "  $svc:" "$RUSTDESK_COMPOSE" | grep -q "read_only: true"; then echo "FAIL: rustdesk-server $svc missing read_only"; exit 1; fi
  done
  echo "✓ rustdesk-server read_only"
  for svc in hbbs hbbr web; do
    if ! grep -A40 "  $svc:" "$RUSTDESK_COMPOSE" | grep -q -- "- ALL"; then echo "FAIL: rustdesk-server $svc missing cap_drop: ALL"; exit 1; fi
  done
  echo "✓ rustdesk-server cap_drop ALL"
  for svc in hbbs hbbr; do
    if ! grep -A40 "  $svc:" "$RUSTDESK_COMPOSE" | grep -q 'user: "1000:1000"'; then echo "FAIL: rustdesk-server $svc must run as 1000:1000"; exit 1; fi
  done
  echo "✓ rustdesk-server hbbs/hbbr run as 1000:1000"
  if grep -A40 "  web:" "$RUSTDESK_COMPOSE" | grep -qE '^[[:space:]]+user:'; then
    echo "FAIL: rustdesk-server web must not force a user (nginx drops privileges itself)"
    exit 1
  fi
  echo "✓ rustdesk-server web does not force a user"
fi
if grep -q "privileged: true" "$RUSTDESK_COMPOSE"; then echo "FAIL: rustdesk-server privileged"; exit 1; fi
echo "✓ rustdesk-server No privileged"
if grep -q "docker.sock" "$RUSTDESK_COMPOSE"; then echo "FAIL: rustdesk-server docker.sock mount"; exit 1; fi
echo "✓ rustdesk-server No docker.sock"
# rustdesk-server intentionally publishes host ports (21115-21119); this is required.
if ! grep -Eq '^[[:space:]]+ports:' "$RUSTDESK_COMPOSE"; then echo "FAIL: rustdesk-server missing host ports (required for relay)"; exit 1; fi
echo "✓ rustdesk-server host ports present (required)"
# APP_HOST must be the Umbrel-injected container name <app-id>_<service>_1.
# A stale name (e.g. upstream's) makes app_proxy unable to resolve the web
# service, so the app opens to a broken page.
RUSTDESK_ID="$(grep -E '^id: ' "$RUSTDESK_APP" | awk '{print $2}')"
if ! grep -q "APP_HOST: ${RUSTDESK_ID}_web_1" "$RUSTDESK_COMPOSE"; then
  echo "FAIL: rustdesk-server APP_HOST must be ${RUSTDESK_ID}_web_1"
  exit 1
fi
echo "✓ rustdesk-server APP_HOST matches app id"
# app_proxy must stay environment-only (Umbrel app spec). In umbrelOS 2.0 no
# app_proxy container runs at all, so it must carry no image and no runtime
# keys, and must not publish or expose anything.
if grep -A5 "  app_proxy:" "$RUSTDESK_COMPOSE" | grep -Eq '^[[:space:]]+(image|ports|expose|security_opt|cap_drop|cap_add|read_only|tmpfs|container_name|volumes):'; then
  echo "FAIL: rustdesk-server app_proxy must be environment-only"
  exit 1
fi
echo "✓ rustdesk-server app_proxy is environment-only"
if ! grep -q 'PROXY_AUTH_ADD: "true"' "$RUSTDESK_COMPOSE"; then
  echo "FAIL: rustdesk-server web page is reachable without the Umbrel login"
  exit 1
fi
echo "✓ rustdesk-server web page sits behind the Umbrel login"
# The web UI is fronted by app_proxy. Raw-publishing the manifest port (21080)
# or the internal port (80) collides with the app_proxy host port space.
if grep -A40 "  web:" "$RUSTDESK_COMPOSE" | grep -Eq '^[[:space:]]+-[[:space:]]*"?[0-9]+:[0-9]+'; then
  echo "FAIL: rustdesk-server web service must not raw-publish a host port (app_proxy fronts it)"
  exit 1
fi
echo "✓ rustdesk-server web service publishes no host port"
# nginx must end up with a server block. Either the image's conf.d is left
# intact, or the package renders its own default.conf into the conf.d tmpfs.
# Masking conf.d with an EMPTY tmpfs leaves nginx with zero server blocks: it
# starts cleanly and serves nothing.
if grep -A40 "  web:" "$RUSTDESK_COMPOSE" | grep -v '^[[:space:]]*#' | grep -q "/etc/nginx/conf.d"; then
  if ! grep -q "default.conf" "$RUSTDESK_COMPOSE"; then
    echo "FAIL: rustdesk-server masks /etc/nginx/conf.d but never writes a server block"
    exit 1
  fi
  echo "✓ rustdesk-server renders its own nginx server block"
else
  echo "✓ rustdesk-server keeps the nginx image server block"
fi
if ! grep -q "access_log off;" "$RUSTDESK_COMPOSE"; then
  echo "FAIL: rustdesk-server web writes access logs for a static page"
  exit 1
fi
echo "✓ rustdesk-server web does not log requests"
if ! grep -q "network_mode: host" "$RUSTDESK_COMPOSE"; then echo "✓ rustdesk-server no network_mode: host"; else echo "FAIL: rustdesk-server uses network_mode: host"; exit 1; fi
# hbbs/hbbr run as 1000:1000, so the data root must be handed over before the
# containers start. hooks/ is update-whitelisted and data/ is not, so this has
# to be a hook; the recursive chown must stay behind a uid check.
if [ ! -x "$ROOT/madutxo-rustdesk-server/hooks/pre-start" ]; then
  echo "FAIL: rustdesk-server hooks/pre-start missing or not executable"
  exit 1
fi
if ! grep -q 'chown -R 1000:1000' "$ROOT/madutxo-rustdesk-server/hooks/pre-start"; then
  echo "FAIL: rustdesk-server hooks/pre-start does not chown the data dir to 1000:1000"
  exit 1
fi
if ! grep -q 'if \[ "$(stat -c %u "$_dir")" != "1000" \]' "$ROOT/madutxo-rustdesk-server/hooks/pre-start"; then
  echo "FAIL: rustdesk-server hooks/pre-start must guard the chown behind a uid check"
  exit 1
fi
echo "✓ rustdesk-server hooks/pre-start hands the data dir to uid 1000"
# umbrelOS refreshes hooks/ on update but not data/, so hooks/assets is the
# update-path copy of the seeded web root. The two must stay byte-identical or
# an update serves different markup than a fresh install.
if ! cmp -s "$ROOT/madutxo-rustdesk-server/data/www/index.html" \
  "$ROOT/madutxo-rustdesk-server/hooks/assets/index.html"; then
  echo "FAIL: rustdesk-server hooks/assets/index.html is missing or out of date"
  exit 1
fi
echo "✓ rustdesk-server web assets mirrored under hooks/assets"
if ! grep -q "hooks/assets" "$ROOT/madutxo-rustdesk-server/hooks/post-start"; then
  echo "FAIL: rustdesk-server hooks/post-start does not sync hooks/assets into app-data"
  exit 1
fi
echo "✓ rustdesk-server hooks/post-start syncs web assets"
# The setup page must name the ports hbbs/hbbr actually listen on: 21116 for
# the ID server and 21117 for the relay. 21115 is only the NAT-test port.
RUSTDESK_PAGE="$ROOT/madutxo-rustdesk-server/data/www/index.html"
for rs_pair in "id-server:21116" "relay-server:21117"; do
  if ! grep -q "${rs_pair%%:*}\"></code>:<code>${rs_pair#*:}" "$RUSTDESK_PAGE"; then
    echo "FAIL: rustdesk-server setup page gives the wrong ${rs_pair%%:*} port (want ${rs_pair#*:})"
    exit 1
  fi
done
echo "✓ rustdesk-server setup page uses the listening ports"
if ! grep -q "dataRoot: data" "$RUSTDESK_APP"; then echo "FAIL: rustdesk-server missing storage.dataRoot"; exit 1; fi
echo "✓ rustdesk-server storage root"

echo "All lint checks passed"
# Historical regression tests (informational, not failing)
echo "--- Historical checks (should fail on old configs) ---"
for rev in HEAD~3 HEAD~2 HEAD~1; do
  if git cat-file -e "$rev:madutxo-liquid-electrs/docker-compose.yml" 2>/dev/null; then
    echo "Testing $rev..."
    git show "$rev:madutxo-liquid-electrs/docker-compose.yml" 2>/dev/null | grep -q '"3000:3000"' && echo "  $rev: would FAIL Host 3000 (expected for old)" || echo "  $rev: PASS Host 3000"
  fi
done
