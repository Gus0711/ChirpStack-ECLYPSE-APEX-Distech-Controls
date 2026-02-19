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
COPY --from=chirpstack/chirpstack-gateway-bridge:4 /usr/bin/chirpstack-gateway-bridge /usr/bin/chirpstack-gateway-bridge

RUN mkdir -p /etc/chirpstack /etc/chirpstack-gateway-bridge /logs
COPY chirpstack.toml /etc/chirpstack/chirpstack.toml
COPY region_eu868.toml /etc/chirpstack/region_eu868.toml
COPY chirpstack-gateway-bridge.toml /etc/chirpstack-gateway-bridge/chirpstack-gateway-bridge.toml
COPY start.sh /start.sh
RUN dos2unix /start.sh && chmod +x /start.sh

EXPOSE 8080 8090 1700/udp

CMD ["/start.sh"]