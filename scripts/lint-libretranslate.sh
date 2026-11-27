#!/bin/sh
set -eu
ROOT="${LINT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
COMPOSE="$ROOT/madutxo-libretranslate/docker-compose.yml"
APP="$ROOT/madutxo-libretranslate/umbrel-app.yml"
DOCKERFILE="$ROOT/madutxo-libretranslate/Dockerfile"
WSGI="$ROOT/madutxo-libretranslate/wsgi.py"
SEED="$ROOT/madutxo-libretranslate/seed-models.sh"

fail() { echo "FAIL: $*"; exit 1; }

[ -f "$COMPOSE" ] || fail "missing $COMPOSE"
[ -f "$APP" ] || fail "missing $APP"
[ -f "$DOCKERFILE" ] || fail "missing $DOCKERFILE"
[ -f "$WSGI" ] || fail "missing $WSGI"
[ -f "$SEED" ] || fail "missing $SEED"

grep -Eq '^version: "1\.9\.15"$' "$APP" || fail "manifest version must be 1.9.15"
grep -Eq 'image: ghcr.io/madutxo/libretranslate:1\.9\.[0-9]+@sha256:' "$COMPOSE" || fail "compose must pin a 1.9.x digest"
if grep -E 'image:.*:[^ ]+' "$COMPOSE" | grep -v '@sha256:' | grep -v '^#' | grep -q .; then fail "unpinned image"; fi
grep -q 'PROXY_AUTH_ADD: "true"' "$COMPOSE" || fail "app_proxy must keep standard auth"
grep -q 'PROXY_AUTH_WHITELIST: "/translate,/languages,/health"' "$COMPOSE" || fail "wrong API whitelist"
for path in /detect /translate_file /suggest /frontend; do
  grep -F 'PROXY_AUTH_WHITELIST' "$COMPOSE" | grep -q -- "$path" && fail "whitelist must not contain $path"
done
if grep -Eq '^[[:space:]]+ports:' "$COMPOSE"; then fail "compose must not publish a host port"; fi
for line in \
  'LT_CHAR_LIMIT=5000' \
  'LT_BATCH_LIMIT=50' \
  'LT_REQ_LIMIT=180' \
  'LT_REQ_FLOOD_THRESHOLD=360' \
  'LT_HOURLY_REQ_LIMIT=1200' \
  'LT_ALTERNATIVES_LIMIT=3' \
  'LT_API_KEYS=true' \
  'LT_API_KEYS_DB_PATH=/data/api_keys.db' \
  'LT_MAX_CONTENT_LENGTH=2000000' \
  'LT_MAX_CONTENT_LENGTH_FILE=67108864'; do
  grep -q -- "- $line" "$COMPOSE" || fail "missing $line"
done
grep -q 'LT_CORS_ORIGINS=' "$COMPOSE" || fail "missing LT_CORS_ORIGINS"
grep -q 'COPY .*wsgi.py /app/wsgi.py' "$DOCKERFILE" || fail "Dockerfile must install wsgi.py"
grep -q '^umask 077$' "$SEED" || fail "seed-models.sh must set umask 077"
grep -q '413 Request Entity Too Large' "$WSGI" || fail "wsgi.py missing 413 guard"
grep -q 'LT_MAX_CONTENT_LENGTH_FILE' "$WSGI" || fail "wsgi.py missing file cap"
grep -q 'LT_CORS_ORIGINS' "$WSGI" || fail "wsgi.py missing CORS guard"
echo "✓ LibreTranslate API whitelist exact"
echo "✓ LibreTranslate limits and body caps"
echo "✓ LibreTranslate optional key DB on /data"
echo "✓ LibreTranslate wsgi guard installed"
