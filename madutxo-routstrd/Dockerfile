# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Stage 1: build the gatekeeper and the global routstrd install.
# Build tools are required because a transitive dependency (better-sqlite3)
# compiles a native module during install.
# ---------------------------------------------------------------------------
FROM oven/bun:1.4.4-slim@sha256:1846adf22496bd711036aae8be147e57bdebbaea2e5264e3e0b5af1db187d9a4 AS build

USER root

ARG ROUTSTRD_REMOTE_SHA=bd581f0de960ee9f736221a2cbfab1a32a7746bb
# routstrd daemon/CLI tarball + SHA-512 (npm dist.integrity) for integrity pin.
ARG ROUTSTRD_VERSION=0.5.1
ARG ROUTSTRD_SHA512=qlEbnkXvXE2XatC75s8qndILLAJqLltX3zG6gbyOlSxZZeWRguQb1scaY+A0qtC385teiyqd6k4gnDOuhDIZUg==

ENV BUN_INSTALL=/usr/local/bun
ENV BUN_INSTALL_BIN=/usr/local/bin

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates git make g++ python3 \
    && rm -rf /var/lib/apt/lists/*

# Gatekeeper (routstrd-auth) source + production deps.
WORKDIR /src
RUN git clone https://github.com/Routstr/routstrd-remote.git . \
    && git checkout --detach "${ROUTSTRD_REMOTE_SHA}" \
    && test "$(git rev-parse HEAD)" = "${ROUTSTRD_REMOTE_SHA}" \
    && bun install --frozen-lockfile --production \
    && rm -rf /src/.git

# routstrd daemon/CLI, globally. BUN_INSTALL keeps the package out of /root
# (unreadable by the runtime user). Fetched from the pinned npm tarball and
# verified against the registry SHA-512 before install, so a tampered or drifted
# tarball fails the build instead of being executed.
RUN set -eux; \
    bun -e 'const url=process.argv[1],want=process.argv[2];const r=await fetch(url);if(!r.ok)throw new Error("download failed: "+r.status);const buf=new Uint8Array(await r.arrayBuffer());const got=new Bun.CryptoHasher("sha512").update(buf).digest("base64");if(got!==want)throw new Error("integrity mismatch: "+got);await Bun.write("/tmp/routstrd.tgz",buf);console.log("verified sha512-"+got);' "https://registry.npmjs.org/routstrd/-/routstrd-${ROUTSTRD_VERSION}.tgz" "${ROUTSTRD_SHA512}"; \
    bun install --global /tmp/routstrd.tgz; \
    rm -f /tmp/routstrd.tgz; \
    command -v routstrd; \
    routstrd --version

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
# Upgrade the base packages at build time so the image does not ship the base
# layer's stale Debian CVE inventory (routstrd-findings F-R-01).
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
        -o Dpkg::Options::=--force-confold \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        -o Dpkg::Options::=--force-confold \
        ca-certificates curl nginx supervisor tmux \
    && rm -rf /var/lib/apt/lists/*

# Use the x64-baseline Bun build on amd64 so older CPUs without AVX2 do not
# crash with SIGILL. arm64 keeps the image's standard build.
# unzip is needed only to expand the Bun archive, so install and purge it in
# the same layer; it never ships in the runtime image (F-R-16).
RUN if [ "${TARGETARCH}" = "amd64" ]; then \
        apt-get update \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            -o Dpkg::Options::=--force-confold unzip \
        && curl -fsSLo /tmp/bun.zip \
            "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-x64-baseline.zip" \
        && printf '%s  %s\n' \
            "e0446eb55995772eb9894bebae9a6be368d985a8b9271ee124486f9946eedd76" \
            /tmp/bun.zip | sha256sum -c - \
        && unzip -q -o /tmp/bun.zip -d /tmp \
        && mv /tmp/bun-linux-x64-baseline/bun /usr/local/bin/bun \
        && chmod 0755 /usr/local/bin/bun \
        && rm -rf /tmp/bun.zip /tmp/bun-linux-x64-baseline \
        && apt-get purge -y unzip \
        && rm -rf /var/lib/apt/lists/*; \
    fi \
    && bun --version

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

# Global routstrd install from the build stage (native module already built).
ENV BUN_INSTALL=/usr/local/bun
ENV BUN_INSTALL_BIN=/usr/local/bin
COPY --from=build /usr/local/bun /usr/local/bun
RUN ln -sf /usr/local/bun/install/global/node_modules/routstrd/dist/index.js /usr/local/bin/routstrd \
    && routstrd --version

# Gatekeeper source + production deps from the build stage.
COPY --from=build /src /app/auth

# Package configuration.
COPY entrypoint.sh /entrypoint.sh
COPY terminal.sh /terminal.sh
COPY tmux.conf /etc/tmux.conf
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

EXPOSE 3066

USER 1000:1000

ENTRYPOINT ["/entrypoint.sh"]
