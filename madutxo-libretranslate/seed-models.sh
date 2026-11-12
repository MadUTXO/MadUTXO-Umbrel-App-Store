#!/bin/sh
# Seed baked language models into the data volume on first start, then hand
# off to the upstream entrypoint unchanged.
#
# The image bakes the 12 Argos pairs and MiniSBD models into /opt/lt-seed, but
# ${APP_DATA_DIR}/data is a bind mount over the path the app reads
# (XDG_DATA_HOME=/data/.local/share), so the baked copy would be shadowed.
# Copying into the volume is the only way to make the bake effective.
#
# Safety rules:
#   - Only seed when the destination has no Argos packages yet. An existing
#     install is never overwritten, so a model update done by the app is not
#     silently reverted on the next restart.
#   - Never fail the container: if seeding breaks, the app falls back to its
#     boot-time download path, which is worse but not fatal.
set -eu

seed="/opt/lt-seed/share/argos-translate"
data="${XDG_DATA_HOME:-/data/.local/share}/argos-translate"

if [ -d "$seed" ]; then
    have=$(find "$data/packages" -mindepth 2 -maxdepth 2 -name metadata.json 2>/dev/null | wc -l)
    if [ "$have" -lt 12 ]; then
        echo "Seeding baked models into $data (found $have installed)"
        mkdir -p "$data"
        cp -a "$seed/." "$data/" 2>/dev/null || echo "WARNING: model seed copy incomplete"
        echo "Seeded $(find "$data/packages" -mindepth 2 -maxdepth 2 -name metadata.json 2>/dev/null | wc -l) packages"
    else
        echo "Models already present ($have packages), not seeding"
    fi
fi

# Hand off to the upstream entrypoint, forwarding any runtime arguments. This
# is explicit rather than `exec "$@"` so that `docker run img --flag` still
# reaches the real entrypoint instead of being exec'd as a program.
exec /app/scripts/entrypoint.sh "$@"
