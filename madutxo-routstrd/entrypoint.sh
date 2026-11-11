#!/bin/sh
set -eu

export ROUTSTRD_DIR="${ROUTSTRD_DIR:-/data/routstrd}"
export HOME="${HOME:-/data/home}"
mkdir -p "$ROUTSTRD_DIR" "$HOME" /tmp/tmux

# Call the real CLI directly so onboarding/stop bypass the user-facing wrapper
# in /usr/local/bin/routstrd (which blocks lifecycle commands for users).
ROUTSTRD_BIN=/usr/local/bun/install/global/node_modules/routstrd/dist/index.js
routstrd_internal() { /usr/local/bin/bun "$ROUTSTRD_BIN" "$@"; }

# One-time onboarding: creates config.json, the Nostr identity, and the wallet,
# then starts a detached daemon. That daemon owns the wallet lock, so stop it
# and wait for the lock to be released before supervisord starts the foreground
# daemon. Without the wait the daemon fails to claim the wallet and exits.
if [ ! -f "$ROUTSTRD_DIR/config.json" ]; then
    echo "[entrypoint] first run: onboarding routstrd"
    # Capture onboarding output so the wallet mnemonic is never written to the
    # container logs. It is saved to a 0600 file the user can read in the
    # browser terminal (behind Umbrel login) and delete after writing it down.
    _onboard_log="$(mktemp)"
    if ! routstrd_internal onboard --skip-integration >"$_onboard_log" 2>&1; then
        echo "[entrypoint] onboarding failed" >&2
        sed -E 's/([Mm][Nn][Ee][Mm][Oo][Nn][Ii][Cc][[:space:]]*:).*/\1 [REDACTED]/' "$_onboard_log" >&2 || true
        rm -f "$_onboard_log"
        exit 1
    fi
    # Match "Mnemonic:" regardless of case and surrounding whitespace. Upstream
    # wording can change; a case-sensitive match would both lose the phrase and
    # (without the redaction below) let it fall through to the logs.
    _mnemonic="$(sed -n -E 's/.*[Mm][Nn][Ee][Mm][Oo][Nn][Ii][Cc][[:space:]]*:[[:space:]]*//p' "$_onboard_log" | head -1)"
    if [ -n "$_mnemonic" ]; then
        printf '%s\n' "$_mnemonic" > "$ROUTSTRD_DIR/mnemonic.txt"
        chmod 600 "$ROUTSTRD_DIR/mnemonic.txt"
        echo "[entrypoint] wallet mnemonic saved to $ROUTSTRD_DIR/mnemonic.txt (0600); view it in the terminal"
    else
        echo "[entrypoint] warning: onboarding succeeded but no mnemonic was found in its output; the wallet exists but the recovery phrase was not saved. Do not delete the wallet database." >&2
    fi
    # Never echo the captured onboarding output: only the status lines above are
    # safe to print. This removes the log-leak path entirely if the wording changes.
    rm -f "$_onboard_log"
    routstrd_internal stop || true

    _waited=0
    while [ "$_waited" -lt 60 ]; do
        _pid="$(cat "$ROUTSTRD_DIR/wallet/wallet.pid" 2>/dev/null || true)"
        if [ -z "$_pid" ] || ! kill -0 "$_pid" 2>/dev/null; then
            break
        fi
        routstrd_internal stop >/dev/null 2>&1 || true
        sleep 1
        _waited=$((_waited + 1))
    done

    _pid="$(cat "$ROUTSTRD_DIR/wallet/wallet.pid" 2>/dev/null || true)"
    if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
        echo "[entrypoint] warning: onboarding daemon $_pid still up; terminating"
        kill "$_pid" 2>/dev/null || true
        sleep 2
    fi
fi

# Let the CLI authenticate to the gatekeeper (needed for `routstrd npubs`, and to
# scope usage) and disable the upstream npm update check, which cannot work in a
# read-only, pinned image and only nags users to run `routstrd update`. The
# daemon rewrites config.json at startup but preserves these keys verbatim.
if [ -f "$ROUTSTRD_DIR/config.json" ]; then
    /usr/local/bin/bun -e '
      const fs = require("fs");
      const p = process.argv[1];
      const wantAuth = "http://127.0.0.1:8008";
      let cfg;
      try { cfg = JSON.parse(fs.readFileSync(p, "utf8")); } catch { process.exit(0); }
      if (cfg.authUrl === wantAuth && cfg.updateCheck === false) process.exit(0);
      cfg.authUrl = wantAuth;
      cfg.updateCheck = false;
      const tmp = p + ".tmp." + process.pid;
      fs.writeFileSync(tmp, JSON.stringify(cfg, null, 2), { mode: 0o600 });
      fs.renameSync(tmp, p);
      try { fs.chmodSync(p, 0o600); } catch {}
    ' "$ROUTSTRD_DIR/config.json" || true
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

ADMIN_COUNT=$(printf '%s' "${ROUTSTRD_AUTH_ADMIN_NPUBS}" | awk -F, '{print NF}')
echo "[entrypoint] admins configured: ${ADMIN_COUNT}"
echo "[entrypoint] model allowlist: ${ROUTSTRD_AUTH_MODEL_ALLOWLIST}"

exec /usr/bin/supervisord --configuration /etc/supervisor/supervisord.conf --nodaemon
