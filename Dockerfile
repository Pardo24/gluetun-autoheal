# Stage 1: extract docker CLI and compose plugin
FROM docker:cli AS docker-source

# Stage 2: minimal Alpine with only what we need
FROM alpine:latest

RUN apk upgrade --no-cache

# Copy only the two binaries we use
COPY --from=docker-source /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker-source /usr/local/libexec/docker/cli-plugins/docker-compose \
                           /usr/local/libexec/docker/cli-plugins/docker-compose

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV GLUETUN_CONTAINER=gluetun \
    GLUETUN_DEPS=qbittorrent \
    COMPOSE_FILE=/workspace/docker-compose.yml \
    ENV_FILE=/workspace/.env \
    AUTOHEAL_INTERVAL=30 \
    AUTOHEAL_LABEL=autoheal=true

ENTRYPOINT ["/entrypoint.sh"]