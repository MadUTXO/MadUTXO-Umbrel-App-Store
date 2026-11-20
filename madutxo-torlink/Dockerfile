# syntax=docker/dockerfile:1

FROM node:22-bookworm-slim@sha256:e9f565d32859f0cbfb52125eafe8be39390f24dac302dc3cdf566e8ba3ab21ee AS build

# Pinned upstream commit (baairon/torlink v1.11.1 release commit). The tag
# commit and the feature commit it releases (#216) are unsigned; accepted
# because the build fixes it by SHA, the image is digest-pinned, and the
# runtime never re-fetches upstream (TORLINK_NO_UPDATE_CHECK=1).
ARG TORLINK_SHA=5e89f6fd067c28f2c091c4beb9a82838e1b34cc5
ARG TARGETARCH
ARG TTYD_VERSION=1.7.7

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

COPY torlink-memory.patch /tmp/torlink-memory.patch
COPY torlink-bg-seed.patch /tmp/torlink-bg-seed.patch
COPY torlink-deps.patch /tmp/torlink-deps.patch
COPY torlink-test-isolation.patch /tmp/torlink-test-isolation.patch

RUN git clone https://github.com/baairon/torlink.git . \
    && git checkout --detach "${TORLINK_SHA}" \
    && test "$(git rev-parse HEAD)" = "${TORLINK_SHA}" \
    && git apply /tmp/torlink-memory.patch \
    && git apply /tmp/torlink-bg-seed.patch \
    && git apply /tmp/torlink-deps.patch \
    && git apply /tmp/torlink-test-isolation.patch

RUN node -e 'const [major, minor] = process.versions.node.split(".").map(Number); if (major < 22 || (major === 22 && minor < 15)) { console.error("torlink needs Node 22.15+ for TORLINK_NO_WEBRTC"); process.exit(1); }'

RUN npm ci --ignore-scripts \
    && npm run build \
    && npm prune --omit=dev --ignore-scripts

# Download ttyd in the build stage so the runtime never needs curl/libcurl.
RUN case "${TARGETARCH}" in \
        amd64) ttyd_arch=x86_64; ttyd_sha=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55 ;; \
        arm64) ttyd_arch=aarch64; ttyd_sha=b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165 ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -o /usr/local/bin/ttyd "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${ttyd_arch}" \
    && printf '%s  %s\n' "${ttyd_sha}" /usr/local/bin/ttyd | sha256sum -c - \
    && chmod 0755 /usr/local/bin/ttyd \
    && ttyd --version

FROM node:22-bookworm-slim@sha256:e9f565d32859f0cbfb52125eafe8be39390f24dac302dc3cdf566e8ba3ab21ee AS runtime

# nginx comes from nginx.org, the official upstream build: Debian bookworm
# only ships 1.22.1, with no fix for the 2026-11 HTTP/2 CVEs (Nginx2Root:
# CVE-2026-123007, CVE-2026-123633). Pin the exact package version.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl tmux gnupg \
    && curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/debian bookworm nginx" \
        > /etc/apt/sources.list.d/nginx.list \
    && printf 'Package: *\nPin: origin nginx.org\nPin-Priority: 510\n' \
        > /etc/apt/preferences.d/nginx.pref \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        nginx=1.30.7-1~bookworm \
    && rm -rf /var/lib/apt/lists/*

# The node:slim base ships python3 (for build-time node-gyp) with
# libsqlite3-0, which is affected by CVE-2025-7458 (bookworm has no fix).
# Nothing in the runtime uses python3 or sqlite, so remove them entirely;
# this also shrinks the image. Runtime only runs node + ttyd + nginx + tmux.
RUN apt-get purge -y --auto-remove \
        python3 python3-minimal python3-stdlib-extensions \
        python3.11 python3.11-minimal \
        libpython3.11-stdlib libpython3.11-minimal \
        libsqlite3-0 \
    || apt-get purge -y --auto-remove libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*

# npm/npx/corepack are unused at runtime; their bundled dependency tree
# carries fixable HIGH advisories, so drop them.
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
    && rm -f /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack

WORKDIR /app

COPY --from=build /src/package.json ./package.json
COPY --from=build /src/dist ./dist
COPY --from=build /src/node_modules ./node_modules
COPY --from=build /usr/local/bin/ttyd /usr/local/bin/ttyd
COPY entrypoint.sh /entrypoint.sh
# Source-IP filter in front of ttyd: only Umbrel's host gateway may reach the
# writable terminal; co-resident app containers on 10.21.0.0/16 are refused.
COPY router/nginx.conf /etc/nginx/nginx.conf

RUN chmod 0755 /entrypoint.sh \
    && mkdir -p /state /downloads \
    && chown -R 1000:1000 /state

USER 1000:1000

ENV HOME=/state/home \
    TORLINK_STATE_DIR=/state \
    TORLINK_NO_WEBRTC=1 \
    TORLINK_NO_UTP=1 \
    TORLINK_NO_UPDATE_CHECK=1 \
    TORLINK_STORE_CACHE_SLOTS=0 \
    TMUX_TMPDIR=/state/tmux \
    TERM=xterm-256color \
    LANG=C.UTF-8

EXPOSE 7681

ENTRYPOINT ["/entrypoint.sh"]
