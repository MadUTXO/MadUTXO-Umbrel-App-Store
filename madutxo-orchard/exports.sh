#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export APP_ORCHARD_IP="10.21.21.94"
export APP_ORCHARD_PORT="3321"

hidden_service_file="${EXPORTS_TOR_DATA_DIR}/app-${EXPORTS_APP_ID}/hostname"
export APP_ORCHARD_HIDDEN_SERVICE="$(cat "${hidden_service_file}" 2>/dev/null || echo "")"

exit 0
