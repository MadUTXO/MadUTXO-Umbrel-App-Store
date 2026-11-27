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
#   LT-06/LT-22  Request body caps in wsgi.py: 2 MB text, 64 MB file.
#   LT-10  CORS headers removed unless LT_CORS_ORIGINS allows an origin.
#   LT-23  Optional key database created 0600 via umask in seed-models.sh.
#
# Why the model seed lives outside /data: the package sets XDG_DATA_HOME=/data
# and ${APP_DATA_DIR}/data is a bind mount, so anything baked at that path is
# shadowed at runtime. Models are installed into /opt/lt-seed, and the
# container entrypoint copies them into an *empty* data dir on first start
# only. They are never re-downloaded, and an existing install is never
# overwritten.
#
# The bake is split into small per-pair layers because GHCR truncated the
# single ~1.2 GiB layer on pull (unexpected EOF). Six pair layers and one
# MiniSBD layer keep each blob small; the builder stage itself is not shipped,
# so there is no duplicate model layer.
#
# Build: .github/workflows/build-libretranslate.yml (multi-arch)

FROM libretranslate/libretranslate:v1.9.6@sha256:1de2d7056bb8ad607a412f4563d9abe324ff632b43b5be9428bcc8e213aebb32 AS models

USER root

ENV ARGOS_PACKAGE_INDEX=https://raw.githubusercontent.com/argosopentech/argospm-index/ff90de60728f7c1338ff6b75974e4c89b2442d22/ \
    XDG_CACHE_HOME=/seed/cache \
    XDG_CONFIG_HOME=/seed/config

# One unordered pair per run: install_models installs both directions. The
# pinned index has exactly these six unordered pairs among the six load-only
# languages, so the result is the same 12 packages as one 6-language run.
RUN set -eu; \
    for pair in de-en en-es en-fr en-it en-pt es-pt; do \
        echo "baking $pair"; \
        XDG_DATA_HOME="/seed/pairs/$pair" \
        /app/venv/bin/python /app/scripts/install_models.py \
            --load_only_lang_codes="${pair%-*},${pair#*-}"; \
    done

# MiniSBD models are shared by language, not by pair, so they get one small layer.
# Normalise the location in case the library ignores XDG_CACHE_HOME.
RUN set -eu; XDG_DATA_HOME=/seed/pairs/de-en \
    /app/venv/bin/python -c \
    'from minisbd import download_models; download_models(["en","es","fr","de","it","pt"], print)'; \
    out=/seed/minisbd-out; \
    mkdir -p "$out"; \
    for src in /seed/cache/minisbd /root/.cache/minisbd /home/libretranslate/.cache/minisbd; do \
        [ -d "$src" ] && cp -a "$src/." "$out/"; \
    done; \
    test "$(find "$out" -name '*.onnx' | wc -l)" -ge 6

RUN chmod -R a+rX /seed

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

# Small model layers from the builder stage.
COPY --from=models /seed/pairs/de-en/argos-translate/packages/ /opt/lt-seed/share/argos-translate/packages/
COPY --from=models /seed/pairs/en-es/argos-translate/packages/ /opt/lt-seed/share/argos-translate/packages/
COPY --from=models /seed/pairs/en-fr/argos-translate/packages/ /opt/lt-seed/share/argos-translate/packages/
COPY --from=models /seed/pairs/en-it/argos-translate/packages/ /opt/lt-seed/share/argos-translate/packages/
COPY --from=models /seed/pairs/en-pt/argos-translate/packages/ /opt/lt-seed/share/argos-translate/packages/
COPY --from=models /seed/pairs/es-pt/argos-translate/packages/ /opt/lt-seed/share/argos-translate/packages/
COPY --from=models /seed/minisbd-out/ /opt/lt-seed/share/argos-translate/minisbd/

# Metadata-only layer: permissions and the same sanity check as before.
RUN set -eu; \
    seed=/opt/lt-seed/share/argos-translate; \
    p="$seed/packages"; \
    n=$(find "$p" -mindepth 2 -maxdepth 2 -name metadata.json | wc -l); \
    m=$(find "$seed/minisbd" -name '*.onnx' | wc -l); \
    echo "seeded packages: $n; minisbd models: $m"; \
    test "$n" -ge 12; \
    test "$m" -ge 6; \
    chmod -R a+rX /opt/lt-seed

# Drop-in replacement for upstream wsgi.py: same app factory plus the request
# size and CORS guards. gunicorn's `wsgi:app()` target is unchanged.
COPY --chown=1000:1000 wsgi.py /app/wsgi.py

# First-start seeding: copy the baked seed into an empty data dir, then exec
# the upstream entrypoint. Copied as root so the exec bit can be set here.
COPY --chown=1000:1000 seed-models.sh /app/seed-models.sh
RUN chmod 0755 /app/seed-models.sh

# Drop back to the image's own non-root user before shipping, so the image's
# default user stays what upstream intended (uid 1032); the compose file then
# overrides to 1000:1000 for the Umbrel bind mount.
USER libretranslate

ENTRYPOINT ["/app/seed-models.sh"]
