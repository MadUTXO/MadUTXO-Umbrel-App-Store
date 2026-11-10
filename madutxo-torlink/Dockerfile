# syntax=docker/dockerfile:1

FROM node:22-bookworm-slim@sha256:de170b39439eb0e5a3444ad7d60b015614a381e10fecae2e30ec9e735122f38d AS build

# Pinned upstream commit (baairon/torlink v1.11.0). The commit is unsigned;
# accepted because the build fixes it by SHA, the image is digest-pinned, and
# the runtime never re-fetches upstream (TORLINK_NO_UPDATE_CHECK=1).
ARG TORLINK_SHA=394b0b662b0ab2b390846d98aaf56031f6b8dcad
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

FROM node:22-bookworm-slim@sha256:de170b39439eb0e5a3444ad7d60b015614a381e10fecae2e30ec9e735122f38d AS runtime

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates nginx tmux \
    && rm -rf /var/lib/apt/lists/*

# The app runs only `node`; npm/npx/corepack are unused and their bundled
# dependency tree carries fixable HIGH advisories. Drop them from the runtime.
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
