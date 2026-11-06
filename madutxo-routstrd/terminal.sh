#!/bin/sh
export ROUTSTRD_DIR="${ROUTSTRD_DIR:-/data/routstrd}"
export HOME="${HOME:-/data/home}"

cat <<'BANNER'

  Routstr on Umbrel
  -----------------
  This is the official routstrd command line.

  Useful commands:
    routstrd status                         daemon and wallet status
    routstrd balance                        wallet balance
    routstrd receive 2100                   top up with Lightning (2100 sats)
    routstrd clients add -n "My Laptop"     create an API key for an agent
    routstrd clients list                   list API keys
    routstrd monitor                        usage dashboard (htop-like)
    routstrd --help                         all commands

  Point your agent (OpenCode, Hermes, ...) at this app's URL with the API key
  from "routstrd clients add".

BANNER

exec /bin/sh
