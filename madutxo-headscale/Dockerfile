FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    wget \
    && rm -rf /var/lib/apt/lists/* \
    && wget -q https://github.com/juanfont/headscale/releases/download/v0.28.0/headscale_0.28.0_linux_amd64 -O /usr/local/bin/headscale \
    && chmod +x /usr/local/bin/headscale \
    && mkdir -p /etc/headscale /var/lib/headscale

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["serve"]