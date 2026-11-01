# syntax=docker/dockerfile:1

FROM node:22-bookworm-slim@sha256:de170b39439eb0e5a3444ad7d60b015614a381e10fecae2e30ec9e735122f38d AS build

ARG TORLINK_SHA=df059311d0898b7245dd842153c1ff7c892275ee

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

COPY torlink-memory.patch /tmp/torlink-memory.patch

RUN git clone https://github.com/MadUTXO/torlink.git . \
    && git checkout --detach "${TORLINK_SHA}" \
    && test "$(git rev-parse HEAD)" = "${TORLINK_SHA}" \
    && git apply /tmp/torlink-memory.patch \
    && sed -i \
        -e 's/SourceGroup = "Games" | "Movies" | "TV" | "Anime";/SourceGroup = "Movies" | "TV" | "Anime";/' \
        -e 's/groups: \["Games"\],/groups: [],/' \
        -e 's/\["Games", "Movies", "TV", "Anime"\]/["Movies", "TV", "Anime"]/' \
        -e 's/export type Category = "all" | "games" | "movies" | "tv" | "anime";/export type Category = "all" | "movies" | "tv" | "anime";/' \
        -e 's/export type SearchCategory = "games" | "movies" | "tv" | "anime";/export type SearchCategory = "movies" | "tv" | "anime";/' \
        -e 's/\[--category games|movies|tv|anime\]/[--category movies|tv|anime]/' \
        -e '/{ key: "games", label: "Games", group: "Games" },/d' \
        -e '/category === "games" ||/d' \
        -e '/  games: "Games",/d' \
        src/sources/types.ts \
        src/sources/fitgirl.ts \
        src/sources/registry.ts \
        src/ui/store.ts \
        src/cli/args.ts \
        src/cli/search.ts

RUN node -e 'const [major, minor] = process.versions.node.split(".").map(Number); if (major < 22 || (major === 22 && minor < 15)) { console.error("torlink needs Node 22.15+ for TORLINK_NO_WEBRTC"); process.exit(1); }'

RUN npm ci --ignore-scripts \
    && npm run build \
    && npm prune --omit=dev --ignore-scripts

FROM node:22-bookworm-slim@sha256:de170b39439eb0e5a3444ad7d60b015614a381e10fecae2e30ec9e735122f38d AS runtime

ARG TARGETARCH
ARG TTYD_VERSION=1.7.7

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl tmux \
    && rm -rf /var/lib/apt/lists/*

RUN case "${TARGETARCH}" in \
        amd64) ttyd_arch=x86_64; ttyd_sha=8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55 ;; \
        arm64) ttyd_arch=aarch64; ttyd_sha=b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165 ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSLo /usr/local/bin/ttyd "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${ttyd_arch}" \
    && printf '%s  %s\n' "${ttyd_sha}" /usr/local/bin/ttyd | sha256sum -c - \
    && chmod 0755 /usr/local/bin/ttyd \
    && ttyd --version

WORKDIR /app

COPY --from=build /src/package.json ./package.json
COPY --from=build /src/dist ./dist
COPY --from=build /src/node_modules ./node_modules
COPY entrypoint.sh /entrypoint.sh

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
    TERM=xterm-256color \
    LANG=C.UTF-8

EXPOSE 7681

ENTRYPOINT ["/entrypoint.sh"]
