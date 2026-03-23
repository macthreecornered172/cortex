# SpawnBackend.Docker — Plan

## You are in PLAN MODE.

### Project
I want to do a **production-deployable Cortex with Docker-based agent spawning**.

**Goal:** build a **SpawnBackend.Docker** module in which we **auto-spawn sidecar + worker containers per agent when YAML config says `backend: docker`, using the Docker Engine API over the Unix socket**.

### Role + Scope (fill in)
- **Role:** SpawnBackend.Docker Engineer
- **Scope:** I own `SpawnBackend.Docker` — the Elixir module that implements the `SpawnBackend` behaviour by talking to Docker Engine API to create, monitor, stream from, and clean up containers. I do NOT own the Dockerfiles (Container Engineer), the database migration (Database Engineer), or the K8s backend (K8s Engineer).
- **File you will write:** `docs/agent-worker/phase-3/plans/spawn-backend-docker.md`
- **No-touch zones:** do not edit any other files; do not write code.

---

## Functional Requirements
- **FR1:** Implement `SpawnBackend.Docker` that satisfies all four `SpawnBackend` behaviour callbacks: `spawn/1`, `stream/1`, `stop/1`, `status/1`.
- **FR2:** `spawn/1` creates two Docker containers (sidecar + worker) on a shared bridge network, passing env vars (`CORTEX_GATEWAY_URL`, `CORTEX_AGENT_NAME`, `CORTEX_AUTH_TOKEN`, `SIDECAR_URL`, `ANTHROPIC_API_KEY`). The sidecar starts first; the worker starts after the sidecar is healthy.
- **FR3:** `stop/1` sends `docker stop` to both containers and removes them. Idempotent.
- **FR4:** `status/1` inspects container state via Docker API and returns `:running`, `:done`, or `:failed`.
- **FR5:** `stream/1` returns a lazy `Enumerable.t()` of binary chunks from the worker container's stdout logs (via Docker `GET /containers/{id}/logs?follow=true&stdout=true`).
- **FR6:** Containers are named deterministically (`cortex-{run_id}-{team_name}-sidecar` / `cortex-{run_id}-{team_name}-worker`) and labeled with `cortex.run-id` and `cortex.team` for cleanup.
- **FR7:** On `stop/1` or process crash, both containers are removed (not just stopped) to prevent accumulation.
- **Tests required:** unit tests with mocked HTTP client + integration tests requiring Docker daemon.
- **Metrics required:** telemetry events for container spawn latency, container lifecycle, and cleanup.

## Non-Functional Requirements
- Language/runtime: Elixir/OTP
- Local dev: docker-compose brings up Cortex + Postgres; `backend: docker` spawns additional containers dynamically
- Observability: `:telemetry` events for spawn/stop/failure, container log forwarding
- Safety: containers always cleaned up on stop, crash, or timeout; orphan container reaper on startup
- Documentation: README + CLAUDE.md + EXPLAIN.md contributions
- Performance: container spawn latency < 5s for pre-pulled images; < 30s for cold pull

---

## Assumptions / System Model
- **Deployment environment:** local Docker daemon accessible via `/var/run/docker.sock` Unix socket. In Docker-in-Docker (e.g., Cortex itself in a container), the socket is volume-mounted.
- **Failure modes:**
  - Docker daemon unavailable → `spawn/1` returns `{:error, :docker_unavailable}`
  - Container crash mid-run → `status/1` returns `:failed`, cleanup triggers
  - Network timeout → HTTP client timeout on Docker API calls, configurable
  - Image not found → `spawn/1` returns `{:error, :image_not_found}`
- **Multi-tenancy:** none for MVP — single Docker daemon, flat namespace
- **Image availability:** the Container Engineer builds `cortex-agent-worker:latest` which bundles both sidecar and worker binaries. SpawnBackend.Docker runs two containers from this image with different entrypoints.

---

## Data Model (as relevant to your role)

### Handle struct

```
%SpawnBackend.Docker.Handle{
  sidecar_container_id: String.t(),       # Docker container ID (64-char hex)
  worker_container_id: String.t(),        # Docker container ID
  team_name: String.t(),                  # Agent name for labeling
  run_id: String.t(),                     # Run ID for labeling/cleanup
  network_id: String.t(),                 # Shared bridge network ID
  docker_client: module()                 # HTTP client module (for test injection)
}
```

- **Validation:** container IDs are validated as non-empty strings returned by Docker API
- **Versioning:** N/A — handle is ephemeral, lives only for the duration of a run
- **Persistence:** none — handles are in-memory only; orphan containers discovered by label on startup

### Container labels (for cleanup/discovery)

```
"cortex.run-id"   => run_id
"cortex.team"     => team_name
"cortex.role"     => "sidecar" | "worker"
"cortex.managed"  => "true"
```

---

## APIs (as relevant to your role)

### SpawnBackend Behaviour Callbacks

```elixir
@impl SpawnBackend
@spec spawn(keyword()) :: {:ok, Handle.t()} | {:error, term()}
def spawn(opts)
# opts:
#   :team_name    — required, agent name
#   :run_id       — required, run identifier for labeling
#   :image        — optional, defaults to "cortex-agent-worker:latest"
#   :gateway_url  — optional, defaults to "host.docker.internal:4001"
#   :gateway_token — optional, defaults to resolved token
#   :network      — optional, Docker network name (default: "cortex-net")
#   :timeout_ms   — optional, container-level timeout
#   :docker_client — optional, HTTP client module (for test injection)

@impl SpawnBackend
@spec stream(Handle.t()) :: {:ok, Enumerable.t()} | {:error, term()}
def stream(handle)

@impl SpawnBackend
@spec stop(Handle.t()) :: :ok
def stop(handle)

@impl SpawnBackend
@spec status(Handle.t()) :: :running | :done | :failed
def status(handle)
```

### Internal Helper APIs

```elixir
# Docker HTTP client (thin wrapper over unix socket HTTP)
defmodule Cortex.SpawnBackend.Docker.Client do
  @spec create_container(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  @spec start_container(String.t(), keyword()) :: :ok | {:error, term()}
  @spec stop_container(String.t(), keyword()) :: :ok | {:error, term()}
  @spec remove_container(String.t(), keyword()) :: :ok | {:error, term()}
  @spec inspect_container(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @spec container_logs(String.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  @spec create_network(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  @spec remove_network(String.t(), keyword()) :: :ok | {:error, term()}
  @spec ping(keyword()) :: :ok | {:error, term()}
end

# Orphan cleanup
defmodule Cortex.SpawnBackend.Docker.Cleanup do
  @spec reap_orphans(keyword()) :: {:ok, non_neg_integer()}
end
```

---

## Architecture / Component Boundaries (as relevant)

### Components

1. **`Cortex.SpawnBackend.Docker`** — behaviour implementation. Orchestrates the spawn sequence: create network -> create sidecar container -> start sidecar -> wait for health -> create worker container -> start worker. Delegates all Docker API calls to `Docker.Client`.

2. **`Cortex.SpawnBackend.Docker.Client`** — thin HTTP client that speaks to the Docker Engine API over the Unix socket (`/var/run/docker.sock`). Uses `Finch` (already a transitive dep via Phoenix) or raw `:httpc` with Unix socket support. Encapsulates JSON encoding/decoding of Docker API payloads.

3. **`Cortex.SpawnBackend.Docker.Cleanup`** — startup reaper. On application boot, queries Docker for containers labeled `cortex.managed=true` that are stopped or orphaned, and removes them. Prevents container accumulation from crashes.

### How SpawnBackend.Docker fits into the existing spawn pipeline

```
YAML config: backend: docker
      |
      v
Runner.Executor reads backend field
      |
      v
SpawnBackend.Docker.spawn(team_name: "backend", run_id: "abc-123", ...)
      |
      v
Docker.Client.create_network("cortex-abc-123-backend")
      |
      v
Docker.Client.create_container(sidecar_spec) -> start
      |
      v
Poll: wait for sidecar registration in Gateway.Registry (reuse ExternalSpawner pattern)
      |
      v
Docker.Client.create_container(worker_spec) -> start
      |
      v
Return {:ok, handle}
      |
      v
Provider.External dispatches TaskRequest via Gateway -> sidecar -> worker
      |
      v
Run completes
      |
      v
SpawnBackend.Docker.stop(handle) -> stop + remove both containers + network
```

### Container lifecycle management

- Sidecar container starts first with `CORTEX_GATEWAY_URL` pointing to the host Cortex instance (`host.docker.internal:4001` on Docker Desktop, or the Cortex container's IP on a shared network in compose).
- Worker container starts after sidecar registration confirmed, with `SIDECAR_URL=http://cortex-{run_id}-{team_name}-sidecar:9091` (container DNS on shared network).
- Both containers share a per-run bridge network for DNS resolution.
- `stop/1`: stop worker first (graceful), then stop sidecar, then remove both, then remove network.

### Cleanup strategy

- **Normal path:** `stop/1` called by executor after run completes.
- **Crash path:** `Cleanup.reap_orphans/1` on Cortex startup queries `docker ps -a --filter label=cortex.managed=true` and removes any stopped/exited containers.
- **Timeout path:** if `:timeout_ms` is set, a `Process.send_after` fires and triggers `stop/1`.

---

## Correctness Invariants (must be explicit)

1. **No orphan containers:** every container created by `spawn/1` is removed by `stop/1` or `Cleanup.reap_orphans/1`. Test: spawn + crash without stop -> reaper cleans up.
2. **Sidecar before worker:** worker container never starts before sidecar is registered in Gateway.Registry. Test: mock slow sidecar registration, verify worker waits.
3. **Idempotent stop:** calling `stop/1` multiple times on the same handle returns `:ok` without errors. Test: double-stop.
4. **Status accuracy:** `status/1` returns `:running` only when the worker container's Docker state is "running". `:done` when exited with code 0. `:failed` otherwise. Test: inspect mock responses.
5. **Network isolation:** each run creates its own bridge network; containers from different runs cannot communicate via container DNS. Test: verify network name includes run_id.
6. **Docker unavailable:** `spawn/1` returns `{:error, :docker_unavailable}` when the daemon is not reachable. Test: mock ping failure.

---

## Tests

### Unit tests (mocked Docker.Client)

**File:** `test/cortex/spawn_backend/docker_test.exs`

- `spawn/1` creates network, sidecar container, worker container in correct order
- `spawn/1` passes correct env vars to sidecar (CORTEX_GATEWAY_URL, CORTEX_AGENT_NAME, CORTEX_AUTH_TOKEN)
- `spawn/1` passes correct env vars to worker (SIDECAR_URL, ANTHROPIC_API_KEY)
- `spawn/1` returns error when Docker ping fails
- `spawn/1` returns error when container creation fails
- `spawn/1` waits for sidecar registration before starting worker
- `spawn/1` returns error on registration timeout
- `stop/1` stops and removes both containers and the network
- `stop/1` is idempotent
- `status/1` maps Docker container states correctly
- Container naming follows `cortex-{run_id}-{team_name}-{role}` pattern
- Containers have correct labels

### Unit tests for Docker.Client

**File:** `test/cortex/spawn_backend/docker/client_test.exs`

- JSON payload construction for create_container
- Response parsing for inspect, logs
- Error handling for non-200 responses
- Unix socket path configuration

### Integration tests (requires Docker daemon)

**File:** `test/cortex/spawn_backend/docker_integration_test.exs`

- Tag: `@moduletag :docker` (skip in CI without Docker)
- Full spawn/status/stop lifecycle with a lightweight test image (e.g., `alpine:latest` running `sleep`)
- Container cleanup verified after stop
- Network cleanup verified after stop
- Orphan reaper cleans up leftover containers

### Failure injection tests

**File:** `test/cortex/spawn_backend/docker/cleanup_test.exs`

- Reaper finds and removes containers with `cortex.managed=true` label
- Reaper is idempotent (no error on empty list)

**Commands:**
```bash
mix test test/cortex/spawn_backend/docker_test.exs
mix test test/cortex/spawn_backend/docker/client_test.exs
mix test test/cortex/spawn_backend/docker/cleanup_test.exs
mix test test/cortex/spawn_backend/docker_integration_test.exs  # requires Docker
```

---

## Benchmarks + "Success"

### What to measure
- **Container spawn latency:** time from `spawn/1` call to `{:ok, handle}` return (includes network creation, sidecar start, registration wait, worker start)
- **Container stop/cleanup time:** time from `stop/1` call to completion (stop + remove + network remove)
- **Sidecar registration latency:** time from sidecar container start to appearance in Gateway.Registry

### Target success criteria
- **Spawn latency (warm image):** < 5 seconds (sidecar start + registration + worker start)
- **Spawn latency (cold pull):** < 30 seconds (acceptable for first run)
- **Stop/cleanup time:** < 3 seconds
- **Registration latency:** < 3 seconds

### Benchmark commands
```bash
mix run bench/docker_spawn_bench.exs   # requires Docker daemon running
```

Benchmark script will:
1. Run 5 iterations of spawn + stop with pre-pulled image
2. Report p50/p95/p99 for spawn and stop latency
3. Verify no orphan containers remain after benchmark

---

## Engineering Decisions & Tradeoffs (REQUIRED)

### Decision 1: Raw HTTP to Docker Unix socket vs. Elixir Docker client library

- **Decision:** Use raw HTTP calls to the Docker Engine API via `/var/run/docker.sock`, wrapped in a thin `Docker.Client` module.
- **Alternatives considered:**
  - `dockerex` / `docker_api` Hex packages — these are unmaintained (last publish 2019/2020) and don't support modern Docker API versions.
  - Shelling out to `docker` CLI via `System.cmd/3` — simpler but slower (process fork per call), harder to stream logs, and less reliable error handling.
- **Why:** The Docker Engine API is stable and well-documented. A thin HTTP wrapper gives full control over the API version, error handling, and streaming. Elixir's `:httpc` or `Finch` can speak to Unix sockets. No unmaintained dependency risk.
- **Tradeoff acknowledged:** More code to write and maintain vs. a library. But the Docker API surface we need is small (create, start, stop, remove, inspect, logs, network CRUD, ping) — roughly 8 endpoints. The wrapper will be ~150 lines.

### Decision 2: Per-run bridge network vs. shared network

- **Decision:** Create a dedicated bridge network per run (`cortex-{run_id}-{team_name}`), attach sidecar and worker to it, remove it on cleanup.
- **Alternatives considered:**
  - Shared `cortex-net` network for all runs — simpler, but containers from different runs can see each other via DNS, and network cleanup is harder.
  - Host networking — simplest, but no DNS-based service discovery between sidecar and worker, and port conflicts between concurrent runs.
- **Why:** Per-run networks provide isolation between concurrent runs, enable container DNS (worker can reach sidecar by container name), and clean up naturally with the run.
- **Tradeoff acknowledged:** Slightly more Docker API calls (create/remove network per run) and a small latency increase (~100ms). Acceptable given the isolation benefit.

### Decision 3: Reuse ExternalSpawner's registration-wait pattern vs. Docker health checks

- **Decision:** Reuse the `poll Gateway.Registry` pattern from `ExternalSpawner.wait_for_registration/3` to confirm the sidecar is ready before starting the worker.
- **Alternatives considered:**
  - Docker `HEALTHCHECK` on sidecar container + polling `docker inspect` for healthy status — tighter Docker integration but requires the sidecar image to define a HEALTHCHECK, adding a dependency on the Container Engineer's Dockerfile.
- **Why:** The existing pattern is proven and decoupled from the container image. Gateway registration is the actual signal that matters (sidecar is connected and ready to receive work), not just that the sidecar process is running.
- **Tradeoff acknowledged:** Slightly slower feedback loop vs. Docker native health checks, but more semantically correct.

---

## Risks & Mitigations (REQUIRED)

### Risk 1: Docker socket unavailable or permission denied
- **Risk:** `/var/run/docker.sock` doesn't exist or the Cortex process lacks permission.
- **Impact:** `spawn/1` fails for all `backend: docker` configs. Silent failure if not checked at startup.
- **Mitigation:** Add a `Docker.Client.ping/1` health check. Call it in `spawn/1` before creating containers. Log a clear warning at Cortex startup if Docker is configured but unreachable. Return `{:error, :docker_unavailable}` with actionable message.
- **Validation time:** < 5 minutes — write ping function, test with socket present and absent.

### Risk 2: `host.docker.internal` not available on Linux
- **Risk:** Docker Desktop (macOS/Windows) provides `host.docker.internal` to reach the host. Native Linux Docker does not by default.
- **Impact:** Sidecar container cannot reach Cortex Gateway on the host, causing registration timeout.
- **Mitigation:** When Cortex itself runs on the host (not in a container), detect the platform and use `host.docker.internal` on macOS or the `docker0` bridge gateway IP on Linux (queryable via `docker network inspect bridge`). When Cortex runs in a container (compose), both are on the same Docker network and use container DNS. Make `gateway_url` configurable as an option to `spawn/1`.
- **Validation time:** < 10 minutes — test on macOS with Docker Desktop, verify gateway_url override works.

### Risk 3: Container accumulation from unclean shutdowns
- **Risk:** If Cortex crashes or is killed without calling `stop/1`, orphan containers remain.
- **Impact:** Docker daemon accumulates stopped containers consuming disk; if containers are still running, they consume CPU/memory.
- **Mitigation:** Label all containers with `cortex.managed=true`. Run `Cleanup.reap_orphans/1` on Cortex startup. This queries Docker for containers with that label and removes any that are exited or have been running longer than a configurable max age.
- **Validation time:** < 10 minutes — manually create labeled containers, restart Cortex, verify they're cleaned up.

### Risk 4: Finch/httpc Unix socket support
- **Risk:** Elixir HTTP clients may not natively support Unix domain sockets for the Docker API.
- **Impact:** Need to find or build Unix socket HTTP transport.
- **Mitigation:** `Finch` supports Unix sockets via `{:local, "/var/run/docker.sock"}` in the URL scheme. Alternatively, use Erlang's `:gen_tcp` to connect to the Unix socket and send raw HTTP. Spike this in task 1 before committing to the approach.
- **Validation time:** < 10 minutes — write a 10-line script that pings Docker via Finch over Unix socket.

### Risk 5: Image pull latency on first run
- **Risk:** If the `cortex-agent-worker` image isn't pre-pulled, `docker create` triggers a pull that can take 30+ seconds.
- **Impact:** First `spawn/1` call appears to hang; timeout fires before container starts.
- **Mitigation:** Document that `docker compose build` or `docker pull` should be run before first use. Consider adding an explicit `Docker.Client.pull_image/2` step in `spawn/1` with a longer timeout, so progress is visible. For MVP, rely on pre-pulled images and document the requirement.
- **Validation time:** < 5 minutes — test spawn with and without pre-pulled image.

---

# Please produce (no code yet):

## 1) Recommended API surface

### SpawnBackend callbacks

```elixir
# lib/cortex/spawn_backend/docker.ex
defmodule Cortex.SpawnBackend.Docker do
  @behaviour Cortex.SpawnBackend

  @impl true
  def spawn(opts)     # keyword: :team_name, :run_id, :image, :gateway_url, :gateway_token, :network, :timeout_ms, :docker_client
  @impl true
  def stream(handle)  # returns {:ok, Enumerable.t()} of binary chunks from worker logs
  @impl true
  def stop(handle)    # stop + remove containers + network; idempotent
  @impl true
  def status(handle)  # :running | :done | :failed based on worker container state
end
```

### Helper functions (internal)

```elixir
# lib/cortex/spawn_backend/docker/client.ex
defmodule Cortex.SpawnBackend.Docker.Client do
  def ping(opts \\ [])
  def create_container(spec, opts \\ [])
  def start_container(id, opts \\ [])
  def stop_container(id, opts \\ [])
  def remove_container(id, opts \\ [])
  def inspect_container(id, opts \\ [])
  def container_logs(id, opts \\ [])       # follow=true, returns stream
  def create_network(name, opts \\ [])
  def remove_network(id, opts \\ [])
  def list_containers(filters, opts \\ []) # for cleanup
end

# lib/cortex/spawn_backend/docker/cleanup.ex
defmodule Cortex.SpawnBackend.Docker.Cleanup do
  def reap_orphans(opts \\ [])
end
```

## 2) Folder structure

```
lib/cortex/spawn_backend/
  docker.ex                    # SpawnBackend behaviour implementation
  docker/
    client.ex                  # Docker Engine API HTTP client
    cleanup.ex                 # Orphan container reaper
    handle.ex                  # Handle struct definition

test/cortex/spawn_backend/
  docker_test.exs              # Unit tests (mocked client)
  docker_integration_test.exs  # Integration tests (real Docker)
  docker/
    client_test.exs            # Client unit tests
    cleanup_test.exs           # Cleanup unit tests

bench/
  docker_spawn_bench.exs       # Spawn/stop latency benchmark
```

## 3) Step-by-step task plan

See "Tighten the plan into 4-7 small tasks" below.

## 4) Benchmark plan

**Benchmark:** `bench/docker_spawn_bench.exs`

Uses `Benchee` to measure:
1. **spawn latency** — `SpawnBackend.Docker.spawn/1` with pre-pulled `alpine:latest` image (sidecar mocked as sleep process since we need Gateway for real sidecar)
2. **stop/cleanup latency** — `SpawnBackend.Docker.stop/1` on running containers
3. **full lifecycle** — spawn -> status check -> stop

**Success criteria:**
- spawn p95 < 5s (warm image)
- stop p95 < 3s
- zero orphan containers after benchmark completes

---

# Tighten the plan into 4-7 small tasks (STRICT)

### Task 1: Docker.Client — HTTP client over Unix socket
- **Outcome:** A working `Docker.Client` module that can ping Docker, create/start/stop/remove/inspect containers, manage networks, and stream logs via the Docker Engine API over `/var/run/docker.sock`.
- **Files to create/modify:**
  - `lib/cortex/spawn_backend/docker/client.ex` (new)
  - `test/cortex/spawn_backend/docker/client_test.exs` (new)
- **Exact verification command(s):**
  - `mix test test/cortex/spawn_backend/docker/client_test.exs`
  - `mix compile --warnings-as-errors`
- **Suggested commit message:** `feat: Docker.Client — HTTP client for Docker Engine API over Unix socket`

### Task 2: Handle struct + SpawnBackend.Docker scaffold
- **Outcome:** `Handle` struct defined. `SpawnBackend.Docker` module implements all four callbacks, delegating to `Docker.Client`. Spawn sequence: create network -> create sidecar -> start sidecar -> wait for Gateway registration -> create worker -> start worker. Stop sequence: stop worker -> stop sidecar -> remove both -> remove network.
- **Files to create/modify:**
  - `lib/cortex/spawn_backend/docker/handle.ex` (new)
  - `lib/cortex/spawn_backend/docker.ex` (new)
  - `test/cortex/spawn_backend/docker_test.exs` (new)
- **Exact verification command(s):**
  - `mix test test/cortex/spawn_backend/docker_test.exs`
  - `mix compile --warnings-as-errors`
- **Suggested commit message:** `feat: SpawnBackend.Docker — behaviour impl with container lifecycle management`

### Task 3: Orphan container cleanup
- **Outcome:** `Docker.Cleanup.reap_orphans/1` queries Docker for containers labeled `cortex.managed=true` and removes exited/stale ones. Called on Cortex application startup.
- **Files to create/modify:**
  - `lib/cortex/spawn_backend/docker/cleanup.ex` (new)
  - `test/cortex/spawn_backend/docker/cleanup_test.exs` (new)
  - `lib/cortex/application.ex` (add cleanup call to startup)
- **Exact verification command(s):**
  - `mix test test/cortex/spawn_backend/docker/cleanup_test.exs`
  - `mix compile --warnings-as-errors`
- **Suggested commit message:** `feat: Docker orphan container reaper on startup`

### Task 4: Telemetry events for Docker backend
- **Outcome:** Telemetry events emitted for container spawn start/complete/fail, container stop, and cleanup. Consistent with existing `Cortex.Telemetry` patterns.
- **Files to create/modify:**
  - `lib/cortex/telemetry.ex` (add Docker-specific event emitters)
  - `lib/cortex/spawn_backend/docker.ex` (emit events in spawn/stop)
  - `test/cortex/spawn_backend/docker_test.exs` (verify events emitted)
- **Exact verification command(s):**
  - `mix test test/cortex/spawn_backend/docker_test.exs`
  - `mix compile --warnings-as-errors`
- **Suggested commit message:** `feat: telemetry events for Docker container lifecycle`

### Task 5: Integration tests with real Docker
- **Outcome:** Integration tests that create real containers using `alpine:latest`, verify the full spawn/status/stop lifecycle, and confirm cleanup.
- **Files to create/modify:**
  - `test/cortex/spawn_backend/docker_integration_test.exs` (new)
- **Exact verification command(s):**
  - `mix test test/cortex/spawn_backend/docker_integration_test.exs` (requires Docker daemon)
- **Suggested commit message:** `test: Docker SpawnBackend integration tests with real containers`

### Task 6: Benchmark + docs
- **Outcome:** Benchmark script measuring spawn/stop latency. CLAUDE.md and EXPLAIN.md contributions proposed.
- **Files to create/modify:**
  - `bench/docker_spawn_bench.exs` (new)
- **Exact verification command(s):**
  - `mix run bench/docker_spawn_bench.exs` (requires Docker daemon)
- **Suggested commit message:** `perf: Docker spawn/stop latency benchmarks`

---

# CLAUDE.md contributions (do NOT write the file; propose content)

## From SpawnBackend.Docker Engineer

### Coding Style
- `Docker.Client` functions accept keyword opts with `:socket_path` defaulting to `"/var/run/docker.sock"` — always injectable for tests
- All Docker API calls go through `Docker.Client` — never shell out to `docker` CLI
- Container specs built as maps matching Docker Engine API JSON schema, not custom DSLs
- Test injection via `:docker_client` option on `SpawnBackend.Docker.spawn/1`

### Dev Commands
```bash
mix test test/cortex/spawn_backend/docker_test.exs          # unit tests (no Docker needed)
mix test test/cortex/spawn_backend/docker_integration_test.exs  # requires Docker
mix run bench/docker_spawn_bench.exs                         # spawn latency benchmark
```

### Before You Commit
1. `mix format`
2. `mix compile --warnings-as-errors`
3. `mix credo --strict`
4. `mix test test/cortex/spawn_backend/docker_test.exs` (unit tests pass without Docker)
5. If Docker available: `mix test test/cortex/spawn_backend/docker_integration_test.exs`
6. No hardcoded socket paths — always use the `:socket_path` option

### Guardrails
- Never call `Docker.Client` functions without error handling — Docker daemon may be unavailable
- Always label containers with `cortex.managed=true` so the reaper can find them
- Always remove containers after stopping — `stop` alone leaves exited containers on disk
- Integration tests must be tagged `@moduletag :docker` and excluded from default test runs in CI without Docker

---

# EXPLAIN.md contributions (do NOT write the file; propose outline bullets)

## SpawnBackend.Docker

### Flow / Architecture
- When YAML config specifies `backend: docker`, the orchestration executor calls `SpawnBackend.Docker.spawn/1` instead of `SpawnBackend.Local.spawn/1`
- `spawn/1` creates a per-run Docker bridge network, starts a sidecar container, waits for Gateway registration, then starts a worker container
- The sidecar container connects to Cortex Gateway via `host.docker.internal` (macOS) or bridge gateway IP (Linux)
- The worker container reaches the sidecar via Docker DNS on the shared network
- After the run completes, `stop/1` removes both containers and the network

### Key Engineering Decisions + Tradeoffs
- **Raw HTTP over Unix socket** instead of a Docker client library — no unmaintained dependencies, full control over API version and streaming. Tradeoff: ~150 lines of HTTP wrapper code to maintain.
- **Per-run bridge networks** instead of a shared network — provides isolation between concurrent runs at the cost of ~100ms extra latency for network creation.
- **Gateway registration polling** instead of Docker HEALTHCHECK — semantically correct (sidecar is truly ready when registered) and decoupled from Dockerfile contents.

### Limits of MVP + Next Steps
- No image pull management — images must be pre-pulled. Future: add `Docker.Client.pull_image/2` with progress reporting.
- No resource limits on containers (CPU, memory). Future: configurable via YAML.
- No log aggregation beyond `stream/1`. Future: forward container logs to Cortex's telemetry/store.
- No GPU/device passthrough. Future: `--gpus` flag support for ML workloads.
- Linux `host.docker.internal` support requires `--add-host` flag or Docker 20.10+. Documented but not auto-detected in MVP.

### How to Run Locally + How to Validate
1. Ensure Docker daemon is running: `docker info`
2. Build the agent-worker image: `docker compose build` (from infra/)
3. Start Cortex: `mix phx.server`
4. Submit a YAML config with `backend: docker` via the UI
5. Verify containers spawned: `docker ps --filter label=cortex.managed=true`
6. After run completes, verify cleanup: `docker ps -a --filter label=cortex.managed=true` (should be empty)
7. Run integration tests: `mix test test/cortex/spawn_backend/docker_integration_test.exs`

---

## READY FOR APPROVAL
