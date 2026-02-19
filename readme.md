# Déploiement de ChirpStack sur ECLYPSE APEX (Distech Controls)

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

## Étape 1 — Préparer l'image custom sur ton PC

Comme l'APEX n'autorise pas Docker Compose et que la résolution DNS entre conteneurs peut poser problème, la solution est de **tout embarquer dans une seule image**.

### Structure des fichiers

Crée un dossier `chirpstack-apex/` avec 3 fichiers :

**`chirpstack.toml`**

```toml
[postgresql]
dsn="postgres://chirpstack:chirpstack@localhost/chirpstack?sslmode=disable"

[redis]
servers=["redis://localhost:6379"]

[network]
net_id="000000"

[api]
secret="change-me-with-a-random-secret"

[[regions]]
name="eu868"
common_name="EU868"

[[regions.gateways]]
server="0.0.0.0:1700"
```

> ⚠️ Note : `localhost` car PostgreSQL, Redis et ChirpStack tournent dans le même conteneur.
> Sans `bind` dans `[api]`, ChirpStack écoute sur le port **8080** par défaut (interface web + API gRPC).

**`start.sh`**

```bash
#!/bin/bash

exec 2>&1
exec > /logs/chirpstack.log

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

**`Dockerfile`**

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

RUN mkdir -p /etc/chirpstack /logs
COPY chirpstack.toml /etc/chirpstack/chirpstack.toml
COPY start.sh /start.sh
RUN dos2unix /start.sh && chmod +x /start.sh

EXPOSE 8080 8090 1700/udp

CMD ["/start.sh"]
```

> ⚠️ `dos2unix` est indispensable si tu travailles sur Windows — sans ça le script shell ne s'exécutera pas sur Linux.

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
      "8090/tcp": [{"HostPort": "50090"}]
    },
    "RestartPolicy": {"Name": "unless-stopped"},
    "NetworkMode": "bridge"
  }
}
```

> 💡 Le volume `chirpstack-logs` permet d'accéder aux logs via FileBrowser si nécessaire.

---

## Étape 4 — Accéder à ChirpStack

| Accès | URL |
|-------|-----|
| Interface web | `http://IP_APEX:50081` |
| API REST + Swagger | `http://IP_APEX:50090` |

Login par défaut : `admin` / `admin`

---

## Étape 5 — Tester l'API REST en Python

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

## Points importants

- **L'image ChirpStack officielle `latest` est x86** — toujours utiliser un tag spécifique comme `4.12.1`
- **ChirpStack v4 attend un répertoire** : utiliser `--config /etc/chirpstack` (pas `--config /etc/chirpstack/chirpstack.toml`)
- **L'extension PostgreSQL `pg_trgm` est requise** par ChirpStack pour les migrations
- **`dos2unix` est obligatoire** si le `start.sh` est créé sur Windows
- **Port 8080** → Interface web ChirpStack (gRPC interne)
- **Port 8090** → API REST via `chirpstack-rest-api` (Swagger accessible sur `/`)
- **`chirpstack-rest-api` nécessite `--insecure`** pour les connexions HTTP locales

---

## Architecture de l'image

```
Conteneur tout-en-un
├── PostgreSQL 14      (interne)
├── Redis 7            (interne)
├── Mosquitto          (port 1700/udp → gateway LoRaWAN)
├── ChirpStack 4.12.1  (port 8080 → interface web)
└── chirpstack-rest-api (port 8090 → API REST + Swagger)
```

---

## Vérification des logs

Si le conteneur ne démarre pas, accéder aux logs via FileBrowser (`http://IP_APEX:50080`) en montant le volume `chirpstack-logs`.

Le fichier `chirpstack.log` contient toutes les sorties du script de démarrage.

---

## Contraintes APEX connues

| Contrainte | Détail |
|-----------|--------|
| Pas de Docker Compose | Tout doit être dans une seule image ou via API REST V2 |
| Plugin OPA | Restreint certains PortBindings — utiliser les ports `500xx` |
| Pas de SSH | Débogage uniquement via logs dans un volume |
| ARM64 uniquement | Builder avec `--platform linux/arm64` |
| Pas de `docker logs` | Rediriger les sorties vers un fichier de log dans un volume |