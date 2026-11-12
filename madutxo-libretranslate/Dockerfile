# Fork of the upstream LibreTranslate image, pinned to the v1.9.6 base digest.
# We add security fixes and baked models on top and nothing else, so the app
# behaves as audited plus the fixes.
#
# What this closes:
#   LT-07  Werkzeug 2.3.8 -> 3.0.6 (CVE-2024-49767 multipart exhaustion).
#   LT-02  Models baked in, so first boot needs no network.
#   LT-18  No model bytes are fetched from a mutable remote at runtime; the
#          Argos index is pinned to a commit and the image digest freezes the
#          downloaded model bytes.
#   LT-09  Debian packages upgraded, certifi raised above its advisory, and
#          the unused waitress package removed. The two remaining CRITICALs
#          (libsqlite3, zlib1g) have no upstream fix and are unreachable.
#
# Why the model seed lives outside /data: the package sets XDG_DATA_HOME=/data
# and ${APP_DATA_DIR}/data is a bind mount, so anything baked at that path is
# shadowed at runtime. Models are installed into /opt/lt-seed, and the
# container entrypoint copies them into an *empty* data dir on first start
# only. They are never re-downloaded, and an existing install is never
# overwritten.
#
# Build: .github/workflows/build-libretranslate.yml (multi-arch)

FROM libretranslate/libretranslate:v1.9.6@sha256:1de2d7056bb8ad607a412f4563d9abe324ff632b43b5be9428bcc8e213aebb32

USER root

# LT-09: Debian security updates for the base. Kept in its own layer so it can
# be dropped without touching the Werkzeug pin or the model seed.
RUN apt-get update \
 && apt-get -y --no-install-recommends upgrade \
 && rm -rf /var/lib/apt/lists/*

# LT-07 / LT-09: Werkzeug 3.0.6; certifi above the advisory version; remove
# waitress (gunicorn serves the app, and the waitress import is inside the
# unreachable non-`--wsgi` branch).
RUN /app/venv/bin/pip install --no-cache-dir "Werkzeug==3.0.6" "certifi==2026.10.23" \
 && /app/venv/bin/pip uninstall -y waitress

# LT-02 / LT-18: bake the Argos pairs and MiniSBD models for the six load-only
# languages. install_models.py is upstream's own script, so the result matches
# a first boot. The package index is pinned to an argospm-index commit. Write,
# permissions and the sanity check all happen in this single layer to avoid the
# duplicate ~1.2 GiB layer that made the earlier bake 2.54 GiB.
RUN set -eu; \
    export XDG_DATA_HOME=/opt/lt-seed/share \
           XDG_CONFIG_HOME=/opt/lt-seed/config \
           XDG_CACHE_HOME=/opt/lt-seed/cache \
           ARGOS_PACKAGE_INDEX=https://raw.githubusercontent.com/argosopentech/argospm-index/ff90de60728f7c1338ff6b75974e4c89b2442d22/ \
           LT_LOAD_ONLY=en,es,fr,de,it,pt; \
    /app/venv/bin/python /app/scripts/install_models.py \
        --load_only_lang_codes=en,es,fr,de,it,pt; \
    seed=/opt/lt-seed/share/argos-translate; \
    mkdir -p "$seed/minisbd"; \
    for src in /root/.cache/minisbd /home/libretranslate/.cache/minisbd; do \
        if [ -d "$src" ]; then cp -a "$src/." "$seed/minisbd/"; fi; \
    done; \
    p="$seed/packages"; \
    n=$(find "$p" -mindepth 2 -maxdepth 2 -name metadata.json | wc -l); \
    m=$(find "$seed/minisbd" -name '*.onnx' | wc -l); \
    echo "seeded packages: $n; minisbd models: $m"; \
    test "$n" -ge 12; \
    test "$m" -ge 6; \
    chmod -R a+rX /opt/lt-seed

# First-start seeding: copy the baked seed into an empty data dir, then exec
# the upstream entrypoint. Copied as root so the exec bit can be set here.
COPY --chown=1000:1000 seed-models.sh /app/seed-models.sh
RUN chmod 0755 /app/seed-models.sh

# Drop back to the image's own non-root user before shipping, so the image's
# default user stays what upstream intended (uid 1032); the compose file then
# overrides to 1000:1000 for the Umbrel bind mount.
USER libretranslate

ENTRYPOINT ["/app/seed-models.sh"]
