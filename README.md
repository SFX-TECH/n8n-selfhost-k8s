# Self-Hosting n8n: Docker Compose and Kubernetes (Queue Mode)

A hands-on reference for running [n8n](https://n8n.io) yourself, two ways:

1. **Docker Compose** for a single host: n8n + Postgres + Redis.
2. **Kubernetes** for production-style scaling: n8n in **queue mode** with a main
   process, a pool of autoscaled worker pods, Redis as the job queue, and
   Postgres for durable state.

The repo is intentionally generic and secret-free. It exists to show the moving
parts of a real n8n self-host and how the same stack grows from one container to
a horizontally scaled Kubernetes deployment.

> Built and verified against **n8n 2.27.5**, Postgres 16, and Redis 7. Docs were
> pulled from the current official n8n documentation rather than from memory.

---

## What this demonstrates

- Multi-service Docker Compose with health checks and ordered startup.
- Durable state: workflows and credentials live in Postgres and survive a full
  container teardown and recreate.
- Secret hygiene: the encryption key and database password are generated locally
  and never committed. Only `.example` files are in git.
- The jump to Kubernetes: ConfigMaps, Secrets, a StatefulSet for Postgres, a
  main/worker split for n8n queue mode, a HorizontalPodAutoscaler, and Services
  plus NodePort/Ingress for access. (See [`k8s/`](k8s/), Phase 2.)

---

## Architecture

### Docker Compose (single host)

```
                       Host: localhost
   browser  ->  :5678  +-----------------------------------------+
                       |  Docker network: n8n-net                |
                       |                                         |
                       |   +-----------+      +---------------+  |
                       |   |   n8n     |----->|   postgres    |  |
                       |   | (main UI) |      | volume:pg_data|  |
                       |   |  :5678    |      |   :5432       |  |
                       |   +-----------+      +---------------+  |
                       |         |                              |
                       |         v                              |
                       |   +-----------+                        |
                       |   |  redis    |  healthy, ready for    |
                       |   |  :6379    |  queue mode            |
                       |   +-----------+                        |
                       |                                         |
                       |  named volumes: n8n_data, pg_data       |
                       +-----------------------------------------+
```

n8n runs in the default (regular) execution mode here. Redis is included and
health checked so the topology matches the Kubernetes phase, and Compose can be
flipped into queue mode with one flag (see [Queue mode in Compose](#optional-queue-mode-in-compose)).

### Kubernetes (queue mode) -> see [`k8s/`](k8s/)

```
                         Kubernetes namespace: n8n
   browser --(NodePort :30678)--> [ n8n-main ] --enqueue--> [ redis ]
                                       |                        ^
                                  read/write                pull jobs
                                       v                        |
                                 [ postgres ]  <--results--  [ n8n-worker x N ]
                                                              scaled by an HPA
```

Full walkthrough is in Phase 2 below (added with the manifests).

---

## Repo layout

```
.
├── docker-compose.yml      # n8n + Postgres + Redis (Phase 1)
├── .env.example            # every variable documented; copy to .env
├── k8s/                    # Kubernetes manifests for queue mode (Phase 2)
├── docs/img/               # screenshots used in this README
├── NOTES.md                # engineering log and design decisions
└── README.md
```

---

## Quickstart: Docker Compose

**Prerequisites:** Docker Desktop (or Docker Engine) with Compose v2.

```bash
# 1. Create your local secrets file from the template
cp .env.example .env

# 2. Generate real secrets and put them in .env
#    N8N_ENCRYPTION_KEY:  openssl rand -hex 32
#    POSTGRES_PASSWORD:   openssl rand -hex 16
#    (edit .env and paste the values)

# 3. Start the stack
docker compose up -d

# 4. Watch it come up healthy
docker compose ps
```

Then open **http://localhost:5678** and create the owner account on first launch
(email, name, password). n8n removed the old `N8N_BASIC_AUTH_*` variables; access
is now controlled by this built-in owner account and user management. You can
optionally pre-provision the owner from the environment instead (see the
commented block at the bottom of `.env.example`).

Useful commands:

```bash
docker compose logs -f n8n        # follow n8n logs
docker compose exec redis redis-cli ping     # -> PONG
docker compose down               # stop and remove containers (KEEPS volumes/data)
docker compose down -v            # stop and ALSO delete volumes (wipes all data)
```

### Proving persistence (Postgres)

The whole point of using Postgres is that your workflows and credentials do not
live inside the n8n container. To prove it, this repo's smoke test creates a
workflow, destroys the containers, recreates them, and confirms the workflow is
still there.

```bash
# A workflow named "Persistence Smoke Test" exists in the database:
docker compose exec -T postgres psql -U n8n -d n8n -c "SELECT id, name FROM workflow_entity;"

# Tear down the CONTAINERS (volumes are kept because we omit -v):
docker compose down

# Bring the stack back:
docker compose up -d

# The workflow is still there, because it lives in the pg_data volume, not the container:
docker compose exec -T postgres psql -U n8n -d n8n -c "SELECT id, name FROM workflow_entity;"
```

The workflow (and the owner account) survive the recreate:

![n8n workflow persisted after a container recreate](docs/img/n8n-compose-persisted.png)

### Optional: queue mode in Compose

Compose can also run queue mode with a dedicated worker, mirroring the Kubernetes
setup. Set `EXECUTIONS_MODE=queue` in `.env`, then start with the `queue` profile:

```bash
docker compose --profile queue up -d
docker compose logs -f n8n-worker
```

The main process now enqueues executions to Redis and the worker container runs
them. Queue mode and why it matters are explained in detail in the Kubernetes
phase, where it is the default.

---

## Kubernetes (queue mode)

Coming in Phase 2. The manifests live in [`k8s/`](k8s/) and cover namespace,
ConfigMap, Secret (generated locally), Postgres StatefulSet, Redis, the n8n main
and worker Deployments, an HPA, Services, and NodePort/Ingress access.

---

## Security and secrets

- `.env` and any rendered Kubernetes Secret are git-ignored. Only `.example`
  files are committed. Run `git status` before committing to confirm.
- The n8n `N8N_ENCRYPTION_KEY` must be set before first start and then kept
  constant. In queue mode it must be identical on the main process and every
  worker, or workers cannot decrypt stored credentials.
- No client data and no real credentials are in this repo. All names and demo
  values are generic.
