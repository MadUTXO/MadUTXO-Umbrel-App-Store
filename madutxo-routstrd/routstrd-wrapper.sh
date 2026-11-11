#!/bin/sh
# Umbrel-managed routstrd CLI wrapper.
#
# The daemon is supervised by the app (supervisord). Commands that would start,
# stop or duplicate the daemon, re-onboard the wallet, self-update the pinned
# package, or install a PM2 system service cannot work here and are refused with
# a clear message. `start`/`restart` are routed through supervisord so the
# daemon always stays under the app's supervision. Every other command is passed
# through to the real CLI.
REAL=/usr/local/bun/install/global/node_modules/routstrd/dist/index.js

supervisor() {
    /usr/bin/supervisorctl -c /etc/supervisor/supervisord.conf "$@"
}

case "$1" in
    update)
        echo "routstrd: 'update' is disabled in this app." >&2
        echo "Updates are delivered through the Umbrel dashboard." >&2
        exit 1 ;;
    onboard)
        echo "routstrd: 'onboard' is disabled; onboarding is managed by the app." >&2
        exit 1 ;;
    daemon)
        echo "routstrd: 'daemon' is disabled; the daemon is managed by the app." >&2
        exit 1 ;;
    service)
        echo "routstrd: 'service' is disabled; this app does not use PM2." >&2
        exit 1 ;;
    stop)
        echo "routstrd: 'stop' is disabled; the daemon is managed by the app." >&2
        echo "Use 'routstrd restart' or the Umbrel dashboard instead." >&2
        exit 1 ;;
    start)
        supervisor start routstrd
        exit $? ;;
    restart)
        supervisor restart routstrd
        exit $? ;;
esac

exec /usr/local/bin/bun "$REAL" "$@"
