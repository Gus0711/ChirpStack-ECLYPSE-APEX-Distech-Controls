FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    postgresql \
    redis-server \
    mosquitto \
    dos2unix \
    && rm -rf /var/lib/apt/lists/*

COPY --from=chirpstack/chirpstack:4.12.1 /usr/bin/chirpstack /usr/bin/chirpstack
COPY --from=chirpstack/chirpstack-rest-api:4 /usr/bin/chirpstack-rest-api /usr/bin/chirpstack-rest-api

RUN mkdir -p /etc/chirpstack /logs
COPY chirpstack.toml /etc/chirpstack/chirpstack.toml
COPY start.sh /start.sh
RUN dos2unix /start.sh && chmod +x /start.sh

EXPOSE 8080 8090 1700/udp

CMD ["/start.sh"]