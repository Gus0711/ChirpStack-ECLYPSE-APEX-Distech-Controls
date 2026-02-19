# Déploiement de ChirpStack sur ECLYPSE APEX (Distech Controls)

## 🚀 Installation rapide

Image Docker disponible : `augustind/chirpstack-apex:4.12.1-v1`

Configuration du conteneur :

```json
{
  "Image": "augustind/chirpstack-apex:4.12.1-v1",
  "HostConfig": {
    "Binds": ["chirpstack-logs:/logs"],
    "PortBindings": {
      "8080/tcp": [{"HostPort": "50081"}],
      "8090/tcp": [{"HostPort": "50090"}],
      "1700/udp": [{"HostPort": "50170"}]
    },
    "RestartPolicy": {"Name": "unless-stopped"},
    "NetworkMode": "bridge"
  }
}
```

| Port | Usage |
|------|-------|
| **50081** | Interface web ChirpStack |
| **50090** | API REST + Swagger |
| **50170/udp** | Réception paquets gateway LoRaWAN (Semtech UDP) |

Login par défaut : `admin` / `admin`

Configuration gateway (packet forwarder Semtech) :
- **Server Address** : IP de l'APEX
- **Port Up** : 50170
- **Port Down** : 50170

---

## Prérequis

- Accès à l'interface web ECLYPSE Facilities (port 443)
- Compte Docker Hub
- Docker Desktop installé sur ton PC de développement
- Accès réseau local à l'APEX

---

## Contexte

L'ECLYPSE APEX est un automate ARM64 (aarch64) avec :

- 2 GB RAM, 20 GB de stockage utilisable
- Accès Docker uniquement via API REST V2 ou interface Facilities
- Pas d'accès SSH ni shell
- Plugin OPA (Open Policy Agent) qui restreint certaines configurations Docker

---

## Architecture de l'image

```
Gateway LoRaWAN (Semtech UDP)
     │ UDP 50170
     ▼
┌─────────────────────────────────────────────┐
│             Conteneur tout-en-un            │
│                                             │
│  chirpstack-gateway-bridge                  │
│  └── écoute UDP 1700 (interne)              │
│  └── convertit paquets Semtech → MQTT       │
│            │                                │
│            ▼                                │
│  Mosquitto (MQTT broker interne :1883)      │
│            │                                │
│            ▼                                │
│  ChirpStack 4.12.1                          │
│  ├── PostgreSQL 14        (interne)         │
│  ├── Redis                (interne)         │
│  ├── Port 8080 → web      (50081)           │
│  └── Port 8090 → REST API (50090)           │
└─────────────────────────────────────────────┘
```

> ⚠️ Le port UDP natif **1700** est bloqué par le plugin OPA — utiliser **50170**.

---

## Étape 1 — Préparer les fichiers sur ton PC

Crée un dossier `chirpstack-apex/` avec ces 5 fichiers :

### `chirpstack.toml`

```toml
[postgresql]
dsn="postgres://chirpstack:chirpstack@localhost/chirpstack?sslmode=disable"

[redis]
servers=["redis://localhost:6379"]

[network]
net_id="000000"
enabled_regions=["eu868"]

[api]
secret="change-me-with-a-random-secret"
```

> ⚠️ Ne pas mettre `[[regions]]` ici — la config région va dans un fichier séparé.
> ⚠️ Laisser une ligne vide à la fin du fichier — sinon le parser TOML concatène les fichiers et plante.

### `region_eu868.toml`

```toml
[[regions]]
id="eu868"
description="EU868"
common_name="EU868"

[regions.gateway.backend]
enabled="semtech_udp"

[regions.gateway.backend.semtech_udp]
udp_bind="0.0.0.0:1700"
```

### `chirpstack-gateway-bridge.toml`

```toml
[integration.mqtt.auth.generic]
servers=["tcp://localhost:1883"]
username=""
password=""
```

### `start.sh`

```bash
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
```

### `Dockerfile`

```dockerfile
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
```

---

## Étape 2 — Builder et pusher l'image

```bash
docker buildx build --platform linux/arm64 -t TONCOMPTE/chirpstack-apex:4.12.1-v1 --push .
```

Remplace `TONCOMPTE` par ton nom d'utilisateur Docker Hub. Assure-toi d'être connecté (`docker login`).

---

## Étape 3 — Déployer sur l'APEX

### Puller l'image

Dans Facilities → Conteneurisation → Images → Ajouter :

```
TONCOMPTE/chirpstack-apex:4.12.1-v1
```

### Créer le conteneur

Dans Facilities → Conteneurisation → Conteneurs → Nouveau conteneur :

- **Nom** : `chirpstack`
- **Configuration JSON** :

```json
{
  "Image": "TONCOMPTE/chirpstack-apex:4.12.1-v1",
  "HostConfig": {
    "Binds": ["chirpstack-logs:/logs"],
    "PortBindings": {
      "8080/tcp": [{"HostPort": "50081"}],
      "8090/tcp": [{"HostPort": "50090"}],
      "1700/udp": [{"HostPort": "50170"}]
    },
    "RestartPolicy": {"Name": "unless-stopped"},
    "NetworkMode": "bridge"
  }
}
```

> 💡 Le volume `chirpstack-logs` permet d'accéder aux logs via FileBrowser.

---

## Étape 4 — Configurer la gateway

Dans l'interface web de ta gateway, configurer le packet forwarder Semtech :

| Paramètre | Valeur |
|-----------|--------|
| Type | Semtech |
| Server Address | IP de l'APEX |
| Port Up | 50170 |
| Port Down | 50170 |

---

## Étape 5 — Accéder à ChirpStack

| Accès | URL |
|-------|-----|
| Interface web | `http://IP_APEX:50081` |
| API REST + Swagger | `http://IP_APEX:50090` |

Login par défaut : `admin` / `admin`

---

## Étape 6 — Tester l'API REST en Python

```python
import requests

CHIRPSTACK_URL = "http://IP_APEX:50090"
API_TOKEN = "ton_token_api"  # Générer dans ChirpStack → API Keys

headers = {
    "Authorization": f"Bearer {API_TOKEN}",
    "Content-Type": "application/json"
}

r = requests.get(f"{CHIRPSTACK_URL}/api/tenants?limit=10", headers=headers)
print(r.status_code, r.json())
```

---

## Vérification des logs

Accéder aux logs via FileBrowser (`http://IP_APEX:50080`) → volume `chirpstack-logs` → `chirpstack.log`.

Lignes clés indiquant un démarrage réussi :

```
backend/semtechudp: starting gateway udp listener addr="0.0.0.0:1700"
integration/mqtt: connected to mqtt broker
integration/mqtt: subscribing to topic gateway/.../command/#
integration/mqtt: publishing state gateway_id=XXXXXXXXXXXXXXXX
```

---

## Points importants

- **L'image ChirpStack officielle `latest` est x86** — toujours utiliser un tag spécifique comme `4.12.1`
- **ChirpStack v4 attend un répertoire** : utiliser `--config /etc/chirpstack` (pas un fichier direct)
- **Les régions dans un fichier séparé** : `chirpstack.toml` ne doit pas contenir `[[regions]]` — utiliser `region_eu868.toml`
- **Ligne vide obligatoire** en fin de `chirpstack.toml` — sinon le parser TOML concatène les deux fichiers et plante au démarrage
- **L'extension PostgreSQL `pg_trgm` est requise** par ChirpStack pour les migrations
- **`dos2unix` est obligatoire** si le `start.sh` est créé sur Windows
- **`chirpstack-rest-api` nécessite `--insecure`** pour les connexions HTTP locales

---

## Contraintes APEX connues

| Contrainte | Détail |
|-----------|--------|
| Pas de Docker Compose | Tout doit être dans une seule image |
| Plugin OPA | Port UDP 1700 bloqué → utiliser 50170 ; mode `host` bloqué |
| Pas de SSH | Débogage uniquement via logs dans un volume |
| ARM64 uniquement | Builder avec `--platform linux/arm64` |
| Pas de `docker logs` | Rediriger les sorties vers un fichier dans un volume (`exec > /logs/chirpstack.log 2>&1`) |