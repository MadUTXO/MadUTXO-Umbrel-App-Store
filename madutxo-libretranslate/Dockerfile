# Fork of the upstream LibreTranslate image, pinned to the same v1.9.6 digest
# the package used before this fork. We do not re-base; we add two things on
# top and nothing else, so the app behaves exactly as audited plus the fixes.
#
# What this closes:
#   LT-07  Werkzeug 2.3.8 -> 3.0.6 (CVE-2024-49767 multipart exhaustion).
#          Flask 2.2.5 requires only Werkzeug>=2.2.2 and imports nothing that
#          3.0 removed; verified locally (multipart upload, sessions, routing).
#   LT-09  Debian packages upgraded in their own layer (see below).
#
# Models are deliberately NOT baked. An earlier build baked the six-language
# set and shipped ~2.54 GiB (two ~1.19 GiB layers: the models, plus a second
# copy materialised by `chown -R` over the whole tree), versus 0.19 GiB
# upstream. That made installs extremely slow. Baking also pins the language
# set at build time; the operator may want different languages later, and the
# package already persists whatever is downloaded into /data. So the app keeps
# upstream's first-boot download, and LT-02/LT-18 remain open by choice.
#
# Build: .github/workflows/build-libretranslate.yml (multi-arch)

FROM libretranslate/libretranslate:v1.9.6@sha256:1de2d7056bb8ad607a412f4563d9abe324ff632b43b5be9428bcc8e213aebb32

USER root

# LT-09: Debian security updates for the base. Kept in its own layer so it can
# be dropped without touching the Werkzeug pin if it ever breaks
# CTranslate2/onnxruntime. --no-install-recommends keeps the delta small.
RUN apt-get update \
 && apt-get -y --no-install-recommends upgrade \
 && rm -rf /var/lib/apt/lists/*

# LT-07: the one dependency on a reachable path. Flask 2.2.5 pins only
# Werkzeug>=2.2.2, and LibreTranslate imports run_simple, DispatcherMiddleware,
# HTTPException, http_date and secure_filename -- all present in 3.0.6.
#
# This deviates from upstream's exact pin (libretranslate 1.9.6 declares
# werkzeug==2.3.8), so pip reports a resolver conflict at build time. Accepted
# because the app only uses Werkzeug APIs that still exist in 3.0.6; re-check
# on every upstream bump. Recorded in the audit as LT-07.
RUN /app/venv/bin/pip install --no-cache-dir "Werkzeug==3.0.6"

# Drop back to the image's own non-root user before shipping, so the image's
# default user stays what upstream intended (uid 1032); the compose file then
# overrides to 1000:1000 for the Umbrel bind mount. The base image's ENTRYPOINT
# (./scripts/entrypoint.sh) is inherited unchanged -- we do not override it.
USER libretranslate
