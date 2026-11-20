#!/bin/sh
# Manifest shape checks for every app. Requires yq.
set -eu
ROOT="${LINT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
[ -f "$ROOT/umbrel-app-store.yml" ] || { echo "FAIL: no store manifest"; exit 1; }
command -v yq >/dev/null 2>&1 || { echo "FAIL: yq required"; exit 1; }

fail=0
ports=""
required="manifestVersion id category name version tagline description releaseNotes developer website port submitter submission"

for m in "$ROOT"/madutxo-*/umbrel-app.yml; do
  app="$(basename "$(dirname "$m")")"
  id="$(yq eval '.id // ""' "$m")"
  [ "$id" = "$app" ] || { echo "FAIL: $app id '$id' must equal the directory"; fail=1; }
  for k in $required; do
    v="$(yq eval ".${k} // \"\"" "$m")"
    [ -n "$v" ] && [ "$v" != "null" ] || { echo "FAIL: $app missing $k"; fail=1; }
  done
  ver="$(yq eval '.version // ""' "$m")"
  [ "$ver" = "latest" ] && { echo "FAIL: $app version is latest"; fail=1; }
  port="$(yq eval '.port // ""' "$m")"
  case "$port" in
    ''|*[!0-9]*) echo "FAIL: $app port '$port' is not numeric"; fail=1 ;;
    *)
      case " $ports " in *" $port "*) echo "FAIL: duplicate port $port ($app)"; fail=1 ;; esac
      case "$port" in 80|443|2000) echo "FAIL: $app uses reserved port $port"; fail=1 ;; esac
      ports="$ports $port"
      ;;
  esac
  yq eval '.permissions // [] | .[]' "$m" 2>/dev/null | while read -r p; do
    [ -n "$p" ] || continue
    case "$p" in STORAGE_DOWNLOADS|GPU) ;; *) echo "FAIL: $app permission '$p' not STORAGE_DOWNLOADS|GPU"; fail=1 ;; esac
  done
done

[ "$fail" -eq 0 ] || { echo "FAIL: manifest checks"; exit 1; }
echo "✓ manifests valid"
