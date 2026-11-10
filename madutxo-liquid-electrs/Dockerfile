# Stage 1: Build electrs with liquid feature (new-index, includes --daemon-rpc-conn-max-age)
FROM rust:1.82-bookworm@sha256:d9c3c6f1264a547d84560e06ffd79ed7a799ce0bff0980b26cf10d29af888377 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    clang=1:14.0* \
    cmake=3.25* \
    libsnappy-dev=1.1.9* \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Pinned Blockstream electrs new-index (deterministic, not branch)
ARG ELECTRS_SHA=785f32d9a5f6b8cab507565171ba2b9d8f6e07c0
RUN git clone --depth 1 https://github.com/Blockstream/electrs.git . \
    && git fetch --depth 1 origin ${ELECTRS_SHA} \
    && git checkout ${ELECTRS_SHA}

# compact-headers.patch already merged in new-index 4615126, no patch needed
# COPY compact-headers.patch /build/
# RUN patch -p1 --fuzz=0 < compact-headers.patch

RUN cargo build --locked --features liquid --release --bin electrs

# Stage 2: Minimal runtime image
FROM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc

LABEL org.opencontainers.image.title="electrs-liquid" \
      org.opencontainers.image.description="Electrum server for Liquid Network — Umbrel community app" \
      org.opencontainers.image.source="https://github.com/Blockstream/electrs" \
      org.opencontainers.image.revision="785f32d9a5f6b8cab507565171ba2b9d8f6e07c0" \
      org.opencontainers.image.version="0.6.10"

RUN apt-get update && apt-get install -y --no-install-recommends \
    libsnappy1v5=1.1.9* \
    gosu=1.14* \
    ca-certificates=2025* \
    curl=7.88* \
    && rm -rf /var/lib/apt/lists/* \
    && adduser --disabled-password --uid 1000 --home /data electrs

COPY --from=builder /build/target/release/electrs /usr/local/bin/electrs
COPY entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 60601 3000
STOPSIGNAL SIGINT
# Default to the unprivileged electrs user. The entrypoint drops privileges with
# gosu only on the legacy root path; under the normal non-root start it execs
# electrs directly.
USER electrs
ENTRYPOINT ["entrypoint.sh"]
