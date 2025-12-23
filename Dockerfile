FROM alpine:3.20

RUN apk add --no-cache \
    postgresql16-client \
    restic \
    wget \
    tzdata \
    procps \
    jq \
    curl

COPY scripts/ /scripts/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /scripts/*.sh /entrypoint.sh

VOLUME ["/dumps", "/restore", "/root/.cache/restic"]

# Healthcheck: verify crond running AND backup succeeded within 2 hours
HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
    CMD pgrep -x crond && /scripts/healthcheck.sh || exit 1

ENTRYPOINT ["/entrypoint.sh"]
