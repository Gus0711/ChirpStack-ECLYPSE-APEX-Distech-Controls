#!/bin/bash
exec > /logs/chirpstack.log 2>&1

echo "=== START ==="
date

echo "=== Init PostgreSQL ==="
if [ ! -f /var/lib/postgresql/14/main/PG_VERSION ]; then
    su postgres -c "/usr/lib/postgresql/14/bin/initdb -D /var/lib/postgresql/14/main"
fi

echo "=== Start PostgreSQL ==="
service postgresql start
sleep 5

echo "=== Create DB ==="
su postgres -c "psql -c \"CREATE USER chirpstack WITH PASSWORD 'chirpstack';\"" 2>/dev/null
su postgres -c "psql -c \"CREATE DATABASE chirpstack OWNER chirpstack;\"" 2>/dev/null
su postgres -c "psql -d chirpstack -c \"CREATE EXTENSION pg_trgm;\"" 2>/dev/null

echo "=== Start Redis ==="
redis-server --daemonize yes
sleep 2

echo "=== Start Mosquitto ==="
mosquitto -d
sleep 2

echo "=== Start Gateway Bridge ==="
/usr/bin/chirpstack-gateway-bridge --config /etc/chirpstack-gateway-bridge/chirpstack-gateway-bridge.toml &
sleep 2

echo "=== Check config ==="
ls -la /etc/chirpstack/

echo "=== Start ChirpStack ==="
/usr/bin/chirpstack --config /etc/chirpstack &
sleep 5

echo "=== Start REST API ==="
/usr/bin/chirpstack-rest-api --server localhost:8080 --bind 0.0.0.0:8090 --insecure &

echo "=== All started ==="
wait
echo "Exit code: $?"