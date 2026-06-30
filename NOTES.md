# NOTES: Architecture and Engineering Log

Working notes for self-hosting n8n two ways: Docker Compose (single node) and
Kubernetes (queue mode with horizontally scaled workers). The polished writeup
lives in README.md. This file is the build log and the source-of-truth for the
decisions made along the way.

All facts below were pulled from the current official n8n docs via Context7
(`/n8n-io/n8n-docs`) on 2026-06-29, not from memory.

---

## 1. Goal

Demonstrate practical Docker and Kubernetes skills relevant to an n8n Support
Engineer role by self-hosting n8n the way a real team would:

- Phase 1: Docker Compose. n8n + Postgres + Redis on one host. Persistence and
  service health proven by restarting the stack.
- Phase 2: Kubernetes. The same stack in queue mode, with a dedicated main
  process, a pool of worker pods that pull jobs off Redis, and a Horizontal Pod
  Autoscaler. Proven by running a workflow and reading the worker logs to show a
  worker picked up the execution.
- Phase 3: Ship a public, generic, secret-free repo with a strong README.

Design principle: Phase 1 is the simple introduction to the stack. Phase 2 is the
"now scale it for production" story. Queue mode and workers are intentionally
reserved for the Kubernetes phase so the progression reads clearly.

---

## 2. Key facts from the n8n docs (Context7)

Image: `docker.n8n.io/n8nio/n8n` (pin to a specific version, set at build time).

Database (Postgres recommended, version 13+ required for queue mode; SQLite is
not recommended for queue mode):

- `DB_TYPE=postgresdb`
- `DB_POSTGRESDB_HOST`, `DB_POSTGRESDB_PORT` (5432), `DB_POSTGRESDB_DATABASE`
- `DB_POSTGRESDB_USER`, `DB_POSTGRESDB_PASSWORD`, `DB_POSTGRESDB_SCHEMA` (public)

Encryption:

- `N8N_ENCRYPTION_KEY` must be set before n8n first starts. In queue mode it MUST
  be identical on the main process and every worker, or workers cannot decrypt
  credentials. This is the single most common queue-mode misconfiguration.

Queue mode (Phase 2):

- `EXECUTIONS_MODE=queue` on the main process AND on every worker.
- `QUEUE_BULL_REDIS_HOST`, `QUEUE_BULL_REDIS_PORT` (6379), optional
  `QUEUE_BULL_REDIS_PASSWORD`.
- Worker process is started with the `worker` command: `n8n worker`. In Docker
  that is the image entrypoint plus the `worker` argument. Concurrency is set
  with `n8n worker --concurrency=N` (default 10).
- Worker health checks: `QUEUE_HEALTH_CHECK_ACTIVE=true` exposes `/healthz` on
  the worker (port configurable with `QUEUE_HEALTH_CHECK_PORT`, default 5678).
  This is what Kubernetes liveness and readiness probes hit on the workers.

Task runners:

- `N8N_RUNNERS_ENABLED=true`. Current n8n runs Code node executions in a task
  runner; enabling it avoids a deprecation warning and matches the recommended
  default.

Auth (IMPORTANT, this changed):

- The old `N8N_BASIC_AUTH_ACTIVE` / `N8N_BASIC_AUTH_USER` / `..._PASSWORD` vars
  were REMOVED in n8n 1.x. Security is now handled by built-in user management:
  an owner account is created on first launch in the UI.
- Owner can optionally be pre-provisioned from env with
  `N8N_INSTANCE_OWNER_MANAGED_BY_ENV=true`, `N8N_INSTANCE_OWNER_EMAIL`,
  `N8N_INSTANCE_OWNER_FIRST_NAME`, `N8N_INSTANCE_OWNER_LAST_NAME`,
  `N8N_INSTANCE_OWNER_PASSWORD_HASH` (bcrypt).
- This repo uses the standard first-launch owner setup as the primary path
  (zero friction, works everywhere) and documents the env-managed owner as an
  optional advanced path. The .env.example carries generic placeholder owner
  identity values, never real credentials.

Misc:

- `GENERIC_TIMEZONE` and `TZ` for schedule and Cron correctness.
- `N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true` so n8n locks down its settings
  file. On Kubernetes the mounted volume must be writable by the node user
  (UID 1000); handled with a pod `securityContext` `fsGroup: 1000`.
- `N8N_SECURE_COOKIE=false` is set in the Kubernetes path so the UI works over
  plain HTTP via NodePort. Not needed for localhost Compose access.

---

## 3. Phase 1 architecture: Docker Compose

Single host. One n8n container in the default (regular) execution mode. Postgres
holds all workflow and credential data so it survives container restarts. Redis
is provisioned and health-checked so the topology mirrors the Kubernetes phase,
and a worker plus queue mode can be toggled on for those who want it.

```
                       Host: localhost
   browser  ->  :5678  +-----------------------------------------+
                       |  Docker network: n8n-net                |
                       |                                         |
                       |   +-----------+      +---------------+  |
                       |   |   n8n     |----->|   postgres    |  |
                       |   | (main UI) |      | (volume: db)  |  |
                       |   |  :5678    |      |   :5432       |  |
                       |   +-----------+      +---------------+  |
                       |         |                              |
                       |         v                              |
                       |   +-----------+                        |
                       |   |  redis    |  (healthy, ready for   |
                       |   |  :6379    |   queue mode)          |
                       |   +-----------+                        |
                       |                                         |
                       |  named volumes: n8n_data, pg_data       |
                       +-----------------------------------------+
```

Persistence proof: create a workflow, run `docker compose down` then
`docker compose up -d`, confirm the workflow is still there (it lives in
Postgres, not in the container filesystem).

Service images:

- n8n: `docker.n8n.io/n8nio/n8n:<pinned>`
- Postgres: `postgres:16-alpine`
- Redis: `redis:7-alpine`

---

## 4. Phase 2 architecture: Kubernetes (queue mode)

Namespace `n8n`. The main process owns the UI, the REST API, webhooks, and
schedule triggers. It does NOT run executions; it enqueues them to Redis (Bull
queue). Worker pods pull jobs off Redis and execute them, writing results back to
Postgres. Scaling executions means scaling worker pods, which the HPA does
automatically under CPU load.

```
                         Kubernetes namespace: n8n
   browser
     |  http://localhost:30678  (NodePort)
     v
  +--------------------+        enqueue job        +-------------------+
  |  n8n-main          |  ----------------------->  |   redis           |
  |  Deployment (1)    |                            |   Deployment (1)  |
  |  EXECUTIONS_MODE=  |  <-----------------------   |   Service :6379   |
  |     queue          |        job results via     +-------------------+
  |  Service :5678     |        Postgres                     ^
  |  PVC /home/node    |                                     | pull jobs
  +--------------------+                                     |
     |  read/write                              +------------+------------+
     v                                          |            |           |
  +--------------------+                   +----------+  +----------+  +----------+
  |  postgres          |  <--------------- | worker 1 |  | worker 2 |  | worker N |
  |  StatefulSet (1)   |   write results   +----------+  +----------+  +----------+
  |  PVC /var/lib/pg   |                   n8n-worker Deployment, command: n8n worker
  |  Service :5432     |                   scaled by HPA (CPU target)
  +--------------------+
```

Manifests under `k8s/` (apply in order):

1. `00-namespace.yaml`      namespace n8n
2. `01-configmap.yaml`      non-secret config (DB host, queue host, modes, tz)
3. `02-secret.yaml`         GENERATED LOCALLY, NOT COMMITTED (encryption key, db creds)
4. `03-postgres.yaml`       StatefulSet + headless Service + PVC
5. `04-redis.yaml`          Deployment + Service (ephemeral; queue is transient)
6. `05-n8n-main.yaml`       Deployment (queue mode) + Service + small PVC
7. `06-n8n-worker.yaml`     Deployment (command: worker) + health probes
8. `07-n8n-worker-hpa.yaml` HorizontalPodAutoscaler on the worker Deployment
9. `08-n8n-nodeport.yaml`   NodePort Service to reach the UI at localhost:30678
10. `09-ingress.yaml`       OPTIONAL Ingress (needs ingress-nginx installed)

UI access decision: Docker Desktop does not ship an ingress controller by
default, so NodePort is the primary, reliable access path (localhost:30678).
`kubectl port-forward` is the zero-config fallback. An Ingress manifest is
included as a bonus to show the pattern, with install notes for ingress-nginx.

Secret handling: `02-secret.yaml` is git-ignored. A committed
`02-secret.example.yaml` documents the shape. A small script generates the real
secret locally from the same values as the Compose `.env` so the encryption key
is consistent if someone runs both stacks against the same data (they should not
mix, but the key handling pattern is the teaching point).

Worker scaling demo: `kubectl scale deployment n8n-worker --replicas=3`, then run
a workflow and `kubectl logs -l app=n8n-worker --prefix` to show which worker pod
picked up the job. HPA proven with `kubectl get hpa -w`.

---

## 5. Security and hygiene (public repo)

- `.gitignore` excludes `.env`, `k8s/02-secret.yaml`, and any local PVC or data
  dirs. Only `.example` files are committed.
- No real secrets, no client data, fully generic names (n8n / n8n / demo).
- Encryption key and DB password are generated locally with `openssl rand`.
- No em dashes or en dashes anywhere in docs (house style).
- Leftover `.clinerules-*` files from a previous tool were removed; they are not
  part of this project.

---

## 6. Open items / running log

- [x] Phase 0: git init, pull current docs, sketch architecture (this file).
- [x] Phase 1: compose up (all healthy), owner setup + test workflow created,
      proven to survive a full `docker compose down` + `up -d` recreate via
      Postgres query, Redis PING -> PONG. n8n pinned to 2.27.5.
- [x] Phase 2: Docker Desktop Kubernetes was already enabled (context docker-desktop,
      node Ready). Applied all manifests with `kubectl apply -k k8s/`. Hit and fixed
      a migration race (main vs workers on empty DB) with a worker initContainer that
      waits for the main /healthz; added a wait-for-postgres initContainer to main to
      avoid a first-boot DNS restart. All 5 pods Running with 0 restarts. Ran a test
      workflow, proved a worker pod executed it (Worker started/finished execution 1).
      Scaled workers 2->4->2. Installed + patched metrics-server (--kubelet-insecure-tls);
      HPA reads live CPU (cpu: 1%/50%, ScalingActive=True). n8n pinned to 2.27.5.
- [x] Phase 3: strong README (both quickstarts, queue mode explained, troubleshooting),
      em/en dash audit (clean), .gitignore audit (.env and k8s/02-secret.yaml ignored),
      published public to https://github.com/SFX-TECH/n8n-selfhost-k8s with topics.

## 7. Decisions / gotchas worth keeping

- n8n is on 2.x (2.27.5). N8N_BASIC_AUTH_* is gone (user management instead).
  N8N_RUNNERS_ENABLED is deprecated in 2.x (runners always on); removed it.
- Queue-mode migration race is the big one: workers must not run initial
  migrations concurrently with main. Gate workers on main /healthz.
- OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true makes manual UI runs land on a worker,
  which is what makes the worker-pickup proof deterministic.
- Docker Desktop has no ingress controller and no metrics-server by default.
  NodePort 30678 is the default UI path; metrics-server needs --kubelet-insecure-tls.

Note: the agentic-harness plugin (/block-0-auditor, /phase-gate-check) is not
available in this environment, so each phase is verified manually instead.
