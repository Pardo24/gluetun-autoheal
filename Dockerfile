FROM docker:cli

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV GLUETUN_CONTAINER=gluetun \
    GLUETUN_DEPS=qbittorrent \
    COMPOSE_FILE=/workspace/docker-compose.yml \
    ENV_FILE=/workspace/.env \
    AUTOHEAL_INTERVAL=30 \
    AUTOHEAL_LABEL=autoheal=true

ENTRYPOINT ["/entrypoint.sh"]