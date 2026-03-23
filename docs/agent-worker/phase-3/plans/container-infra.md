# Container Infrastructure Plan

## You are in PLAN MODE.

### Project
I want to do a **production-deployable Cortex via containers**.

**Goal:** build a **container infrastructure** in which we **can run the entire Cortex stack (Elixir app + SQLite, sidecar, agent-worker) with `docker compose up`, and support `backend: docker` and `backend: k8s` config options for auto-spawning agent containers**.

### Role + Scope (fill in)
- **Role:** Container Engineer
- **Scope:** Dockerfiles (Cortex Elixir release, sidecar+worker combo image), Docker Compose for local dev, `.dockerignore`, build args, health checks. I do NOT own `SpawnBackend.Docker` or `SpawnBackend.K8s` Elixir code, nor the Kubernetes manifests/Helm charts. I build the images and compose file that those backends will consume.
- **File you will write:** `/docs/agent-worker/phase-3/plans/container-infra.md`
- **No-touch zones:** do not edit any other files; do not write code.

---

## Functional Requirements
- **FR1:** Multi-stage Dockerfile for Cortex Elixir release — produces a minimal image exposing ports 4000 (HTTP/Phoenix) and 4001 (gRPC/Gateway).
- **FR2:** Multi-stage Dockerfile for sidecar+worker combo image — single image containing both `cortex-sidecar` and `agent-worker` Go binaries; entrypoint starts sidecar, waits for health, then starts agent-worker.
- **FR3:** Docker Compose file for local dev — services: `cortex` (SQLite via volume mount), with optional `sidecar` + `worker` profiles for testing `provider: external` configs. Shared `cortex-net` bridge network.
- **FR4:** `.dockerignore` files for both build contexts to exclude `_build`, `deps`, `node_modules`, test artifacts, `.git`, and IDE files.
- **FR5:** Health checks on all services — Cortex (`/health/ready`), sidecar (`/health`).
- **FR6:** Volume mounts for dev: SQLite data persistence (`/app/data` volume), optional source code mount for hot-reload scenarios.
- **Tests required:** `docker compose build` succeeds, `docker compose up -d` starts all services, health checks pass, `mix test` runs inside the cortex container or against it.
- **Metrics required:** N/A for container infra — observability infra (Prometheus/Grafana) already exists in `infra/docker-compose.yml` and can be integrated later.

## Non-Functional Requirements
- **Language/runtime:** Elixir 1.17 / Erlang/OTP 27 for the Cortex image; Go 1.22 for the sidecar/worker image
- **Local dev:** `docker compose up` brings up Cortex (SQLite via volume). `docker compose --profile external up` additionally brings up a sidecar+worker pair for testing external agent configs.
- **Observability:** Cortex image exposes `/metrics` (Prometheus), `/health/ready`, `/health/live`. Sidecar image exposes `/health`.
- **Safety:** Cortex container runs as non-root. Sidecar/worker container runs as non-root. No secrets baked into images — all injected via environment variables.
- **Documentation:** CLAUDE.md + EXPLAIN.md contributions proposed at end.
- **Performance:** Target image sizes: Cortex < 100MB, sidecar+worker < 30MB. Build time < 3 minutes with warm Docker cache.

---

## Assumptions / System Model
- **Deployment environment:** Local Docker Compose for dev/testing; later consumed by `SpawnBackend.Docker` (spawns containers programmatically) and `SpawnBackend.K8s` (uses images in Pod specs).
- **Failure modes:** Container crash (restart policy: `unless-stopped`), sidecar can't reach gateway (retries with backoff built into Go client).
- **Delivery guarantees:** N/A — container infra is a deployment concern, not a message delivery concern.
- **Multi-tenancy:** None for MVP. Single Cortex instance, single SQLite database.
- **Database:** SQLite retained for this phase. The container mounts a volume for the `.db` file at `/app/data`. Postgres migration deferred to the dist-control-plane track. The Cortex container entrypoint runs `bin/migrate` before starting the server.

---

## Data Model (as relevant to your role)
N/A — not in scope for this role. Container infra does not define data models. SQLite is retained; the container mounts a volume for the `.db` file.

---

## APIs (as relevant to your role)
N/A — not in scope for this role. We expose existing APIs (HTTP 4000, gRPC 4001, sidecar HTTP 9090) through container port mappings. No new API surfaces.

**Port mapping summary for Docker Compose:**

| Service | Container Port | Host Port | Purpose |
|---------|---------------|-----------|---------|
| cortex | 4000 | 4000 | Phoenix HTTP / LiveView |
| cortex | 4001 | 4001 | gRPC Gateway |
| (none) | — | — | SQLite via volume mount, no external DB service |
| sidecar | 9090 | 9091 | Sidecar HTTP API (host 9091 to avoid conflict with Prometheus) |

---

## Architecture / Component Boundaries (as relevant)

### Image 1: `cortex:latest` (Elixir Release)

Multi-stage build with 3 stages:

1. **deps** — `hexpm/elixir:1.17.3-erlang-27.2-debian-bookworm-20241016-slim` base. Install build tools (`build-essential`, `git`). Copy `mix.exs`, `mix.lock`. Run `mix deps.get --only prod` and `mix deps.compile`.
2. **build** — Same base. Copy `lib/`, `config/`, `priv/`. Run `MIX_ENV=prod mix compile` then `MIX_ENV=prod mix release`. This requires a `config/runtime.exs` that reads `SECRET_KEY_BASE`, `PHX_HOST`, `PORT` from env vars at runtime. SQLite database path defaults to `/app/data/cortex.db`.
3. **runtime** — `debian:bookworm-slim`. Install `libstdc++6`, `openssl`, `libncurses5`, `locales`. Copy the release from the build stage. Set `LANG=en_US.UTF-8`. Expose 4000 and 4001. Run as non-root user `cortex`. Entrypoint: `bin/server` (which runs migrate + start).

**Why Debian and not Alpine:** Erlang BEAM has historically had issues with musl libc (Alpine). Debian-slim is the recommended base for Elixir releases and adds ~30MB over Alpine but avoids runtime surprises.

**Release entrypoint (`rel/overlays/bin/server`):**
```bash
#!/bin/sh
bin/migrate   # run Ecto migrations
bin/cortex start  # start the release
```

**Release migration script (`rel/overlays/bin/migrate`):**
```bash
#!/bin/sh
bin/cortex eval "Cortex.Release.migrate()"
```

This requires a `Cortex.Release` module with a `migrate/0` function — standard Phoenix pattern.

### Image 2: `cortex-sidecar-worker:latest` (Go combo)

Multi-stage build with 2 stages:

1. **builder** — `golang:1.22-alpine`. Copy `go.mod`, `go.sum`. Run `go mod download`. Copy source. Build both binaries:
   - `CGO_ENABLED=0 GOOS=linux go build -o /cortex-sidecar ./cmd/cortex-sidecar`
   - `CGO_ENABLED=0 GOOS=linux go build -o /agent-worker ./cmd/agent-worker`
2. **runtime** — `gcr.io/distroless/static-debian12`. Copy both binaries. Copy an entrypoint script that:
   - Starts `cortex-sidecar` in the background
   - Waits for `/health` to return 200
   - Starts `agent-worker` in the foreground
   - Traps SIGTERM to kill both processes

**Note on entrypoint:** Since distroless has no shell, the entrypoint script must be a compiled Go binary (`cmd/entrypoint/main.go`) or we switch to `alpine:3.19` as the runtime base to get a shell. The pragmatic choice for MVP is `alpine:3.19` (~5MB) since writing a Go entrypoint orchestrator adds complexity with minimal benefit.

**Revised runtime base:** `alpine:3.19` (to allow a shell entrypoint script).

### Docker Compose

```yaml
services:
  cortex:
    build:
      context: .
      dockerfile: Dockerfile
    environment:
      SECRET_KEY_BASE: "dev_secret_key_base_that_is_at_least_64_bytes_long_for_development_only_ok"
      PHX_HOST: "localhost"
      PORT: "4000"
      GRPC_PORT: "4001"
      CORTEX_GATEWAY_TOKEN: "dev-token"
    ports:
      - "4000:4000"
      - "4001:4001"
    volumes:
      - cortex-data:/app/data    # SQLite database file
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:4000/health/ready"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    networks:
      - cortex-net

  # Optional: for testing external agent configs
  sidecar-worker:
    build:
      context: ./sidecar
      dockerfile: Dockerfile.combo
    profiles: ["external"]
    depends_on:
      cortex:
        condition: service_healthy
    environment:
      CORTEX_GATEWAY_URL: "cortex:4001"
      CORTEX_AGENT_NAME: "test-agent"
      CORTEX_AUTH_TOKEN: "dev-token"
      CORTEX_SIDECAR_PORT: "9090"
      SIDECAR_URL: "http://localhost:9090"
    ports:
      - "9091:9090"
    networks:
      - cortex-net

networks:
  cortex-net:
    driver: bridge

volumes:
  cortex-data:
```

### Config propagation
- All configuration is via environment variables — no config files baked into images.
- `config/runtime.exs` reads env vars at boot (standard Phoenix release pattern).
- Sidecar reads env vars via `envconfig` (already implemented).
- Docker Compose sets env vars per service. Production deployments override with `.env` files or orchestrator-level config (K8s ConfigMaps/Secrets).

### Concurrency model
- Not directly applicable to container infra. The Cortex BEAM VM handles its own concurrency. The sidecar handles its own goroutines.

### Backpressure strategy
- N/A for container infra layer.

---

## Correctness Invariants (must be explicit)

1. **Cortex image starts and passes health check** — `curl http://localhost:4000/health/ready` returns 200 within 30s of container start.
2. **gRPC port is accessible** — `grpcurl -plaintext localhost:4001 list` returns the gateway service (or at minimum, the port accepts TCP connections).
3. **Sidecar-worker image starts and sidecar passes health check** — `curl http://localhost:9090/health` returns 200 within 10s.
4. **Worker connects to sidecar** — agent-worker logs show "sidecar is healthy" within 30s.
5. **Sidecar registers with Gateway** — when both cortex and sidecar-worker are running, `cortex` Gateway.Registry shows the test-agent as registered.
6. **SQLite volume is writable** — Cortex container can run migrations and query the database via the mounted volume.
7. **Images are reproducible** — same source + same Docker build context = same image layers (use `--no-cache` for CI, layer cache for dev).
8. **No secrets in image layers** — `docker history` shows no secret values baked in.

---

## Tests

### Build tests (automated)
- `docker compose build` — all images build successfully
- `docker compose build --no-cache` — clean build completes < 5 minutes

### Integration tests (docker-compose based)
- `docker compose up -d` — cortex starts, health checks pass
- `docker compose --profile external up -d` — all services including sidecar-worker start
- `docker compose exec cortex bin/cortex eval "Cortex.Release.migrate()"` — migrations run cleanly
- `docker compose exec cortex bin/cortex eval "Cortex.Repo.query!('SELECT 1')"` — DB connectivity confirmed

### Smoke tests
- `curl http://localhost:4000/health/ready` — returns 200 with JSON body
- `curl http://localhost:4000/health/live` — returns 200
- `curl http://localhost:9091/health` — returns 200 (sidecar via host port)
- Visit `http://localhost:4000` — LiveView dashboard loads

### Edge case tests
- Start sidecar-worker before cortex is ready — sidecar retries gateway connection (built-in backoff)
- `CTRL-C` / `docker compose down` — graceful shutdown, no orphan processes

### Exact commands
```bash
# Build all images
docker compose build

# Start core services
docker compose up -d
docker compose ps   # verify all healthy

# Run health checks
curl -f http://localhost:4000/health/ready
curl -f http://localhost:4000/health/live

# Start with external agent profile
docker compose --profile external up -d
curl -f http://localhost:9091/health

# Teardown
docker compose down
docker compose down -v  # including volumes
```

### Unit tests
N/A — container infra is tested at the integration level (build + run + health check). No unit-testable code.

### Property/fuzz tests
N/A — not applicable to container configuration.

### Failure injection tests
- `docker compose restart cortex` then verify it re-migrates and starts cleanly
- `docker compose stop cortex` then verify sidecar-worker retries gateway connection

---

## Benchmarks + "Success"

| Metric | Target | How to measure |
|--------|--------|----------------|
| Cortex image size | < 100 MB | `docker images cortex --format '{{.Size}}'` |
| Sidecar-worker image size | < 30 MB | `docker images cortex-sidecar-worker --format '{{.Size}}'` |
| Cortex cold build time | < 5 min | `time docker compose build --no-cache cortex` |
| Cortex cached build time | < 30 sec | `time docker compose build cortex` (after deps cached) |
| Sidecar-worker cold build time | < 2 min | `time docker compose build --no-cache sidecar-worker` |
| Cortex startup to healthy | < 30 sec | Time from `docker compose up -d` to health check passing |
| Sidecar startup to healthy | < 10 sec | Time from container start to `/health` returning 200 |

**Success criteria:** All images build, all health checks pass, image sizes meet targets, `docker compose up` brings the full stack to a healthy state within 60 seconds.

---

## Engineering Decisions & Tradeoffs (REQUIRED)

### Decision 1: Debian-slim vs Alpine for Cortex runtime image

- **Decision:** Use `debian:bookworm-slim` as the Cortex runtime base.
- **Alternatives considered:** `alpine:3.19` (~5MB base vs ~80MB for Debian-slim).
- **Why:** Erlang/BEAM historically has issues with musl libc (Alpine's C library) — DNS resolution bugs, NIF compatibility problems, and subtle runtime differences. The official Elixir Docker images recommend Debian. The `hexpm/elixir` build images are Debian-based, so matching the runtime base avoids glibc version mismatches.
- **Tradeoff acknowledged:** ~50-70MB larger image. Acceptable because network transfer is fast in modern environments and reliability matters more than image size for the control plane.

### Decision 2: Combo sidecar+worker image vs separate images

- **Decision:** Ship a single `cortex-sidecar-worker` image containing both Go binaries with a shell entrypoint that starts sidecar first, then worker.
- **Alternatives considered:** (a) Two separate images (`cortex-sidecar`, `cortex-agent-worker`) run as separate containers in a pod or via compose links. (b) A Go-based entrypoint binary that manages both processes.
- **Why:** The sidecar and worker are always co-deployed — there's no use case where you run one without the other. A single image simplifies the build, reduces registry storage, and means `SpawnBackend.Docker` only needs to manage one container per agent (or K8s can still split them into init/sidecar containers from the same image with different entrypoint overrides). The shell entrypoint is simple and debuggable.
- **Tradeoff acknowledged:** Slightly less flexible than separate images — you can't independently version or scale sidecar vs worker. Acceptable because they share a Go module and are tightly coupled by design. K8s backends can override the entrypoint to run each binary separately in a multi-container Pod.

### Decision 3: Docker Compose profiles for optional services

- **Decision:** Use Docker Compose `profiles` for the sidecar-worker service instead of a separate compose file.
- **Alternatives considered:** `docker-compose.override.yml` or `docker-compose.external.yml` as a separate file composed with `-f`.
- **Why:** Profiles keep everything in one file, are easier to discover, and `--profile external` is a clear, self-documenting flag. The core `docker compose up` gives you just Cortex + Postgres (the common case), and `--profile external` adds the test sidecar.
- **Tradeoff acknowledged:** All service definitions are in one file, which could get large. For now with 3-4 services this is fine.

### Decision 4: SQLite with volume mount for containers

- **Decision:** Retain SQLite for this phase. The container mounts a Docker volume at `/app/data` for the `.db` file. Postgres migration deferred to the dist-control-plane track.
- **Alternatives considered:** Switch to Postgres now with a `postgres` Compose service.
- **Why:** SQLite works fine for a single Cortex instance. Adding Postgres adds a hard dependency that's not needed until multi-replica deployment. Keeping SQLite means zero extra services in Compose and simpler config.
- **Tradeoff acknowledged:** SQLite's file-level locking means only one writer at a time. Acceptable for single-instance deployment. Will need Postgres when the dist-control-plane track adds clustering.

---

## Risks & Mitigations (REQUIRED)

### Risk 1: No `mix release` config exists yet
- **Risk:** The project has no `config/runtime.exs`, no `rel/` directory, no `Cortex.Release` module. The Dockerfile depends on `MIX_ENV=prod mix release` working.
- **Impact:** Dockerfile builds but produces a non-functional release (no runtime config, no migration support).
- **Mitigation:** Task 1 in the step-by-step plan creates `config/runtime.exs`, `lib/cortex/release.ex`, and `rel/overlays/bin/server` + `rel/overlays/bin/migrate`. These are small, well-understood Phoenix patterns. Validate with `MIX_ENV=prod mix release` locally before building the Docker image.
- **Validation time:** ~10 minutes.

### Risk 2: SQLite volume permissions in container
- **Risk:** The non-root `cortex` user in the container may not have write permission to the mounted volume at `/app/data`.
- **Impact:** Migrations fail, Cortex can't start.
- **Mitigation:** Ensure the Dockerfile creates `/app/data` owned by the `cortex` user before switching to non-root. Docker volumes default to root — use `chown` in the build stage or set `user:` mapping in Compose.
- **Validation time:** ~5 minutes (build image, run, verify migration runs).

### Risk 3: gRPC port binding in container
- **Risk:** The gRPC server (`Cortex.Gateway.GrpcEndpoint`) is configured in `config.exs` with `port: 4001`. In a release, this needs to be configurable via environment variable, and the server needs to bind to `0.0.0.0` (not `127.0.0.1`) inside the container.
- **Impact:** gRPC port not accessible from outside the container; sidecar can't connect to gateway.
- **Mitigation:** `config/runtime.exs` reads `GRPC_PORT` env var. Verify with `docker compose exec cortex netstat -tlnp` that port 4001 is bound to `0.0.0.0`.
- **Validation time:** ~5 minutes.

### Risk 4: `curl` not available in Cortex runtime image for health checks
- **Risk:** `debian:bookworm-slim` doesn't include `curl`. Docker health check command `curl -f http://localhost:4000/health/ready` would fail.
- **Impact:** Health checks never pass, dependent services never start.
- **Mitigation:** Either (a) install `curl` in the runtime stage (`apt-get install -y curl`), or (b) use a compiled health check binary, or (c) use `wget` which is sometimes available, or (d) write the health check as an Elixir release eval command. Option (a) is simplest — `curl` adds ~3MB. Alternatively, use the release's built-in RPC: `bin/cortex rpc "Cortex.Release.health_check()"`.
- **Validation time:** ~5 minutes.

### Risk 5: Docker build context too large
- **Risk:** Without `.dockerignore`, the Docker build context includes `_build/`, `deps/`, `.git/`, `node_modules/`, SQLite databases, sidecar binaries — potentially hundreds of MB.
- **Impact:** Slow builds, bloated images, possible secrets leaking into layers.
- **Mitigation:** `.dockerignore` created in Task 1 excludes all non-essential files. Validate with `docker build` output showing context size < 10MB.
- **Validation time:** ~2 minutes.

---

## Recommended API Surface

No new APIs. Container infra exposes existing APIs via port mappings:
- `GET /health/ready` — Cortex readiness (existing)
- `GET /health/live` — Cortex liveness (existing)
- `GET /metrics` — Prometheus metrics (existing)
- gRPC Gateway service on 4001 (existing)
- Sidecar `GET /health` (existing)
- Sidecar `GET /task`, `POST /task/result` (existing)

---

## Folder Structure

```
cortex/
  Dockerfile                        # Cortex Elixir release image (NEW)
  .dockerignore                     # Root context exclusions (NEW)
  docker-compose.yml                # Full-stack local dev (NEW — root level)
  config/
    runtime.exs                     # Runtime config for releases (NEW)
  lib/cortex/
    release.ex                      # Migration + health check helpers (NEW)
  rel/
    overlays/
      bin/
        server                      # Entrypoint: migrate + start (NEW)
        migrate                     # Run migrations (NEW)
  sidecar/
    Dockerfile                      # Existing sidecar-only image (UNCHANGED)
    Dockerfile.combo                # Sidecar + worker combo image (NEW)
    .dockerignore                   # Sidecar context exclusions (NEW)
    scripts/
      entrypoint.sh                 # Combo entrypoint: sidecar → health → worker (NEW)
```

**Ownership:**
- Container Engineer (me): All files marked NEW above
- Database: SQLite retained — no separate database engineer work needed for this phase
- SpawnBackend.Docker Engineer: Elixir code in `lib/cortex/spawn_backend/docker.ex` that calls `docker run` with the images I build
- SpawnBackend.K8s Engineer: K8s manifests/code that reference the images I build

---

## Step-by-Step Task Plan (Small Commits)

### Task 1: Release infrastructure — `config/runtime.exs`, `Cortex.Release`, rel overlays

**Files touched:**
- `config/runtime.exs` (create)
- `lib/cortex/release.ex` (create)
- `rel/overlays/bin/server` (create)
- `rel/overlays/bin/migrate` (create)

**How to verify:**
```bash
MIX_ENV=prod mix release
_build/prod/rel/cortex/bin/cortex version
```

**Commit message:** `feat: add mix release config, runtime.exs, and release helpers`

### Task 2: Cortex Dockerfile + .dockerignore

**Files touched:**
- `Dockerfile` (create)
- `.dockerignore` (create)

**How to verify:**
```bash
docker build -t cortex:dev .
docker images cortex:dev --format '{{.Size}}'
# Should be < 100MB
docker run --rm cortex:dev bin/cortex version
```

**Commit message:** `feat: add multi-stage Dockerfile for Cortex Elixir release`

### Task 3: Sidecar+worker combo image

**Files touched:**
- `sidecar/Dockerfile.combo` (create)
- `sidecar/.dockerignore` (create)
- `sidecar/scripts/entrypoint.sh` (create)

**How to verify:**
```bash
docker build -t cortex-sidecar-worker:dev -f sidecar/Dockerfile.combo sidecar/
docker images cortex-sidecar-worker:dev --format '{{.Size}}'
# Should be < 30MB
docker run --rm cortex-sidecar-worker:dev /cortex-sidecar version
```

**Commit message:** `feat: add sidecar+worker combo Docker image with entrypoint`

### Task 4: Docker Compose for full local stack

**Files touched:**
- `docker-compose.yml` (create at project root)

**How to verify:**
```bash
docker compose build
docker compose up -d
docker compose ps  # all services healthy
curl -f http://localhost:4000/health/ready
docker compose down
```

**Commit message:** `feat: add docker-compose.yml for Cortex local dev`

### Task 5: External profile + sidecar integration test

**Files touched:**
- `docker-compose.yml` (add sidecar-worker service with `profiles: ["external"]`)

**Note:** This is folded into Task 4 since the sidecar-worker service is defined in the same file. Splitting it out as a separate verification step.

**How to verify:**
```bash
docker compose --profile external up -d
docker compose ps  # cortex, sidecar-worker all healthy
curl -f http://localhost:9091/health
docker compose --profile external down
```

**Commit message:** `feat: add external agent profile to docker-compose`

### Task 6: Build + smoke test CI script

**Files touched:**
- `scripts/docker-smoke-test.sh` (create)

**How to verify:**
```bash
chmod +x scripts/docker-smoke-test.sh
./scripts/docker-smoke-test.sh
# Should output: all checks passed
```

**Commit message:** `feat: add docker smoke test script for CI`

---

## CLAUDE.md contributions (do NOT write the file; propose content)

### From Container Engineer

**Coding style rules:**
- Dockerfiles use multi-stage builds. Name stages (`AS deps`, `AS build`, `AS runtime`).
- Pin base image versions (e.g., `elixir:1.17.3-erlang-27.2`, not `elixir:latest`).
- Run containers as non-root users. Create a dedicated user in the Dockerfile.
- Never bake secrets into images. Use environment variables or mounted secrets.
- Use `.dockerignore` to keep build contexts small (< 10MB).

**Dev commands:**
```bash
# Build all images
docker compose build

# Start Cortex
docker compose up -d

# Start with external agent testing
docker compose --profile external up -d

# View logs
docker compose logs -f cortex
docker compose logs -f sidecar-worker

# Stop everything
docker compose down

# Stop and remove volumes (fresh start)
docker compose down -v

# Rebuild a single image
docker compose build cortex
docker compose build sidecar-worker

# Run smoke tests
./scripts/docker-smoke-test.sh
```

**Before you commit checklist:**
1. `docker compose build` succeeds
2. `docker compose up -d` — all health checks pass within 60s
3. No secrets in Dockerfiles or docker-compose.yml (use env vars)
4. `.dockerignore` excludes `_build/`, `deps/`, `.git/`, `*.db`
5. Images run as non-root

**Guardrails:**
- Do NOT use `docker compose up` without `-d` in CI — it blocks forever.
- Do NOT mount `/var/run/docker.sock` into the Cortex container for SpawnBackend.Docker — that's a security risk. Use Docker Engine API over TCP instead, configured via `DOCKER_HOST` env var.
- Do NOT use `latest` tags for base images in Dockerfiles — pin versions.
- The existing `infra/docker-compose.yml` (Prometheus + Grafana) is separate from the root `docker-compose.yml`. They can be composed together with `docker compose -f docker-compose.yml -f infra/docker-compose.yml up` when needed.

---

## EXPLAIN.md contributions (do NOT write the file; propose outline bullets)

### Flow / Architecture

- Cortex runs as an Elixir release inside a Debian-slim container, exposing HTTP (4000) and gRPC (4001).
- SQLite database persisted via Docker volume at `/app/data`.
- Sidecar+worker is a combo image: entrypoint starts sidecar, waits for health, then starts worker. Both binaries share localhost inside the container.
- Docker Compose networking: all services on `cortex-net` bridge. Services reference each other by name (e.g., sidecar connects to `cortex:4001`).
- Compose profiles: `docker compose up` = Cortex only. `--profile external` adds a test sidecar-worker.

### Key Engineering Decisions + Tradeoffs

- Debian-slim over Alpine for Cortex runtime (BEAM + musl compatibility concerns, +50MB acceptable).
- Single combo image for sidecar+worker (always co-deployed, simplifies SpawnBackend implementations).
- SQLite retained with volume mount (Postgres deferred to dist-control-plane track).
- Config via environment variables only (12-factor, no baked secrets).
- Release overlays for migration + server scripts (standard Phoenix pattern).

### Limits of MVP + Next Steps

- MVP does not include TLS for gRPC or HTTP inside the compose network (add via reverse proxy or cert mounting later).
- No container resource limits (CPU/memory) in compose — add for production.
- No log aggregation — containers log to stdout, use `docker compose logs` for now.
- No automated image tagging/versioning — images are `:dev` or `:latest` for now. CI should tag with git SHA.
- Observability stack (Prometheus/Grafana from `infra/`) not yet integrated into the root compose file.
- `SpawnBackend.Docker` will need Docker socket or TCP API access to spawn containers dynamically — security model TBD.

### How to Run Locally + How to Validate

```bash
# Prerequisites: Docker Desktop or Docker Engine + Compose plugin

# Build and start
docker compose build
docker compose up -d

# Verify
docker compose ps                          # all services "healthy"
curl http://localhost:4000/health/ready     # {"status":"ok"}
curl http://localhost:4000                  # LiveView dashboard

# Test with external agent
docker compose --profile external up -d
curl http://localhost:9091/health           # sidecar healthy

# Tear down
docker compose down -v
```

---

## READY FOR APPROVAL
