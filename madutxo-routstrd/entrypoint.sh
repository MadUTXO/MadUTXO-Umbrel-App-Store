#!/bin/sh
set -eu

export ROUTSTRD_DIR="${ROUTSTRD_DIR:-/data/routstrd}"
export HOME="${HOME:-/data/home}"
mkdir -p "$ROUTSTRD_DIR" "$HOME" /tmp/tmux

# One-time onboarding: creates config.json, the Nostr identity, and the wallet,
# then starts a detached daemon. Stop that daemon so supervisord owns the
# foreground daemon instead.
if [ ! -f "$ROUTSTRD_DIR/config.json" ]; then
    echo "[entrypoint] first run: onboarding routstrd"
    routstrd onboard --skip-integration
    routstrd stop || true
fi

# The container's own npub must be an admin so the web terminal can manage
# clients and npubs through the gatekeeper. Derive it from the persisted nsec.
CONTAINER_NPUB="$(cd /app/auth && bun -e '
  const { readFileSync } = await import("fs");
  let nt;
  try { nt = await import("nostr-tools"); }
  catch { nt = await import("/app/auth/node_modules/nostr-tools"); }
  const cfg = JSON.parse(readFileSync(process.argv[1], "utf8"));
  const sk = nt.nip19.decode(cfg.nsec).data;
  process.stdout.write(nt.nip19.npubEncode(nt.getPublicKey(sk)));
' "$ROUTSTRD_DIR/config.json")"

# Pre-seed admins: the container's own npub, plus the user's npub if set in the
# app settings (ROUTSTRD_ADMIN_NPUB). The container npub lets the web terminal
# manage clients/npubs through the gatekeeper; the user npub lets you manage
# this node from your own devices.
USER_NPUB="${ROUTSTRD_ADMIN_NPUB:-}"
if [ -n "$USER_NPUB" ]; then
    export ROUTSTRD_AUTH_ADMIN_NPUBS="${USER_NPUB},${CONTAINER_NPUB}"
else
    export ROUTSTRD_AUTH_ADMIN_NPUBS="${CONTAINER_NPUB}"
fi

export ROUTSTRD_AUTH_MODEL_ALLOWLIST="${APP_MADUTXO_ROUTSTRD_MODEL_ALLOWLIST:-true}"

echo "[entrypoint] admins: ${ROUTSTRD_AUTH_ADMIN_NPUBS}"
echo "[entrypoint] model allowlist: ${ROUTSTRD_AUTH_MODEL_ALLOWLIST}"

exec /usr/bin/supervisord --configuration /etc/supervisor/supervisord.conf --nodaemon
