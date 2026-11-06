#!/usr/bin/env bash
set -euo pipefail

# Enforce the Routstr 21 model allowlist so unknown/expensive models are refused.
export APP_MADUTXO_ROUTSTRD_MODEL_ALLOWLIST="true"

exit 0
