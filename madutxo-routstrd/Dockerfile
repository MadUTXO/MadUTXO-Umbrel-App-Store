# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Stage 1: build the routstrd-auth gatekeeper from pinned upstream source.
# The gatekeeper is not published to npm, so it is built from the repo.
# ---------------------------------------------------------------------------
FROM oven/bun:1.4.4-slim@sha256:1846adf22496bd711036aae8be147e57bdebbaea2e5264e3e0b5af1db187d9a4 AS authbuild

USER root

ARG ROUTSTRD_REMOTE_SHA=f5228ee3cc8ac7cdadb407a354bb7fc500bd4711

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN git clone https://github.com/Routstr/routstrd-remote.git . \
    && git checkout --detach "${ROUTSTRD_REMOTE_SHA}" \
    && test "$(git rev-parse HEAD)" = "${ROUTSTRD_REMOTE_SHA}" \
    && bun install --frozen-lockfile --production \
    && rm -rf /src/.git

# ---------------------------------------------------------------------------
# Stage 2: runtime.
# ---------------------------------------------------------------------------
FROM oven/bun:1.4.4-slim@sha256:1846adf22496bd711036aae8be147e57bdebbaea2e5264e3e0b5af1db187d9a4 AS runtime

USER root

ARG TARGETARCH
ARG BUN_VERSION=1.4.4
ARG TTYD_VERSION=1.7.7

# Runtime dependencies: nginx (path router), supervisor (process manager),
# tmux (persistent terminal session), curl (healthcheck), ca-certificates.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl unzip nginx supervisor tmux \
    && rm -rf /var/lib/apt/lists/*

# Use the x64-baseline Bun build on amd64 so older CPUs without AVX2 do not
# crash with SIGILL. arm64 keeps the image's standard build.
RUN if [ "${TARGETARCH}" = "amd64" ]; then \
        curl -fsSLo /tmp/bun.zip \
            "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-x64-baseline.zip" \
        && printf '%s  %s\n' \
            "e0446eb55995772eb9894bebae9a6be368d985a8b9271ee124486f9946eedd76" \
            /tmp/bun.zip | sha256sum -c - \
        && unzip -q -o /tmp/bun.zip -d /tmp \
        && mv /tmp/bun-linux-x64-baseline/bun /usr/local/bin/bun \
        && chmod 0755 /usr/local/bin/bun \
        && rm -rf /tmp/bun.zip /tmp/bun-linux-x64-baseline; \
    fi \
    && bun --version

# Install the routstrd daemon/CLI at a pinned version, globally. BUN_INSTALL
# keeps the package out of /root (unreadable by the runtime user); the base
# image's BUN_INSTALL_BIN=/usr/local/bin puts the binary on PATH.
ENV BUN_INSTALL=/usr/local/bun
ENV BUN_INSTALL_BIN=/usr/local/bin
RUN bun install --global routstrd@0.4.18 \
    && command -v routstrd \
    && routstrd --version

# Install ttyd (browser terminal), pinned per-arch by SHA256.
RUN case "${TARGETARCH}" in \
        amd64) ttyd_arch=x86_64; ttyd_sha=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55 ;; \
        arm64) ttyd_arch=aarch64; ttyd_sha=b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165 ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSLo /usr/local/bin/ttyd \
        "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${ttyd_arch}" \
    && printf '%s  %s\n' "${ttyd_sha}" /usr/local/bin/ttyd | sha256sum -c - \
    && chmod 0755 /usr/local/bin/ttyd \
    && ttyd --version

# Gatekeeper source + production deps from the build stage.
COPY --from=authbuild /src /app/auth

# Package configuration.
COPY entrypoint.sh /entrypoint.sh
COPY terminal.sh /terminal.sh
COPY supervisord.conf /etc/supervisor/supervisord.conf
COPY router/nginx.conf /etc/nginx/nginx.conf

RUN chmod 0755 /entrypoint.sh /terminal.sh \
    && mkdir -p /data/home \
    && chown -R 1000:1000 /data

ENV ROUTSTRD_DIR=/data/routstrd \
    HOME=/data/home \
    ROUTSTRD_UPSTREAM=http://127.0.0.1:8009 \
    ROUTSTRD_AUTH_HOST=127.0.0.1 \
    ROUTSTRD_AUTH_PORT=8008 \
    TERM=xterm-256color \
    LANG=C.UTF-8

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
