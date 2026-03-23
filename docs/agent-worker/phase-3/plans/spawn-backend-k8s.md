# SpawnBackend.K8s Plan

## You are in PLAN MODE.

### Project
I want to implement **SpawnBackend.K8s** for the Cortex multi-agent orchestrator.

**Goal:** build a **Kubernetes spawn backend** in which Cortex **creates Pods with sidecar + worker containers to run external agents on a K8s cluster**, following the same SpawnBackend behaviour that Local already implements.

### Role + Scope
- **Role:** SpawnBackend.K8s Engineer
- **Scope:** I own the K8s backend module (`SpawnBackend.K8s`), its Pod spec generation, K8s API communication, pod lifecycle management, and cleanup. I do NOT own the Container Engineer's Dockerfile/image work, the Docker backend, the database layer, or the Provider.External dispatch logic.
- **File I will write:** `docs/agent-worker/phase-3/plans/spawn-backend-k8s.md`
- **No-touch zones:** do not edit any other files; do not write code.

---

## Functional Requirements
- **FR1:** Implement `Cortex.SpawnBackend.K8s` module that satisfies the `Cortex.SpawnBackend` behaviour (`spawn/1`, `stream/1`, `stop/1`, `status/1`).
- **FR2:** `spawn/1` creates a Kubernetes Pod with two containers — `sidecar` and `worker` — sharing localhost networking, with env vars for gateway URL, agent name, auth token, and sidecar URL.
- **FR3:** `stop/1` deletes the Pod from the K8s cluster. Idempotent — calling on an already-deleted Pod returns `:ok`.
- **FR4:** `status/1` polls the K8s API for Pod phase and maps it to `:running`, `:done`, or `:failed`.
- **FR5:** `stream/1` returns a lazy enumerable that polls the sidecar's registration status in Gateway.Registry, then proxies to Provider.External for actual work dispatch (stream returns a status stream, not stdout — K8s pods don't have a direct stdout pipe like local ports).
- **FR6:** Pod cleanup on run completion or crash — a `terminate` callback or explicit `stop/1` call deletes the Pod regardless of success/failure.
- **FR7:** Configurable container images, resource limits, namespace, and service account via spawn config options.
- **Tests required:** unit tests (mocked K8s API), integration tests (real cluster via kind/minikube)
- **Metrics required:** telemetry events for pod_created, pod_ready, pod_deleted, pod_failed with timing

## Non-Functional Requirements
- Language/runtime: Elixir/OTP
- Local dev: `kind` cluster for K8s integration tests; unit tests mock the K8s API client
- Observability: telemetry events emitted at each lifecycle transition (spawn, ready, stop, fail)
- Safety: Pod always cleaned up — even on Cortex crash, pods have `activeDeadlineSeconds` as a safety net; labels allow batch cleanup
- Documentation: CLAUDE.md + EXPLAIN.md contributions proposed below
- Performance: pod spawn-to-ready latency benchmarked (target: < 30s with pre-pulled images)

---

## Assumptions / System Model
- **Deployment environment:** Kubernetes cluster. Local dev uses `kind` or `minikube`. Production uses a real cluster where Cortex runs as a Deployment or is external with kubeconfig access.
- **K8s API access:** In-cluster via service account (when Cortex runs in K8s) or via `~/.kube/config` (local dev). The `k8s` Elixir library handles both transparently.
- **Image availability:** Container images (`cortex-sidecar`, `cortex-agent-worker`) are pre-built and available in the cluster's image registry. The Container Engineer owns image builds; we consume image references.
- **Gateway reachability:** The Gateway gRPC endpoint (default port 4001) is reachable from within the K8s cluster. When Cortex runs outside the cluster, a NodePort or port-forward is needed.
- **Failure modes:**
  - K8s API unavailable: `spawn/1` returns `{:error, :k8s_api_unavailable}`
  - Pod eviction / OOM: `status/1` returns `:failed`, cleanup triggered
  - Node failure: Pod rescheduled by K8s (with restart policy Never, it stays Failed)
  - Image pull failure: Pod stuck in `ImagePullBackOff`, `status/1` returns `:failed` after timeout
- **Multi-tenancy:** Single namespace per Cortex instance for MVP. Namespace isolation is possible but not required.
- **RBAC:** Cortex needs a ServiceAccount with permissions to create/get/delete/list Pods in the target namespace.

---

## Data Model

### Handle

```elixir
defmodule Handle do
  @enforce_keys [:pod_name, :namespace, :team_name]
  defstruct [
    :pod_name,
    :namespace,
    :team_name,
    :run_id,
    :conn,           # k8s connection reference
    :created_at      # monotonic time for latency tracking
  ]
end
```

### Pod Spec Structure

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: "cortex-<run_id>-<team_name>"      # deterministic, unique
  namespace: "<namespace>"                   # default: "cortex"
  labels:
    app.kubernetes.io/managed-by: cortex
    cortex.dev/run-id: "<run_id>"
    cortex.dev/team: "<team_name>"
    cortex.dev/component: agent-pod
  annotations:
    cortex.dev/created-at: "<ISO8601>"
spec:
  restartPolicy: Never                       # don't restart on exit
  activeDeadlineSeconds: 3600                # safety: kill after 1h max
  serviceAccountName: "<sa>"                 # optional, for RBAC
  containers:
    - name: sidecar
      image: "<sidecar_image>"               # e.g. cortex-sidecar:latest
      env:
        - name: CORTEX_GATEWAY_URL
          value: "<gateway_url>"             # e.g. cortex-gateway:4001
        - name: CORTEX_AGENT_NAME
          value: "<team_name>"
        - name: CORTEX_AUTH_TOKEN
          valueFrom:
            secretKeyRef:
              name: cortex-gateway-token
              key: token
        - name: CORTEX_SIDECAR_PORT
          value: "9091"
      ports:
        - containerPort: 9091
      resources:
        requests:
          cpu: "100m"
          memory: "64Mi"
        limits:
          cpu: "500m"
          memory: "256Mi"
      readinessProbe:
        httpGet:
          path: /healthz
          port: 9091
        initialDelaySeconds: 2
        periodSeconds: 3
      livenessProbe:
        httpGet:
          path: /healthz
          port: 9091
        initialDelaySeconds: 10
        periodSeconds: 10

    - name: worker
      image: "<worker_image>"                # e.g. cortex-agent-worker:latest
      env:
        - name: SIDECAR_URL
          value: "http://localhost:9091"
        - name: ANTHROPIC_API_KEY
          valueFrom:
            secretKeyRef:
              name: anthropic-api-key
              key: key
      resources:
        requests:
          cpu: "200m"
          memory: "128Mi"
        limits:
          cpu: "1000m"
          memory: "512Mi"
```

### Environment Variable Mapping

| Env Var | Container | Source | Purpose |
|---------|-----------|--------|---------|
| `CORTEX_GATEWAY_URL` | sidecar | config `:gateway_url` | gRPC address of Cortex Gateway |
| `CORTEX_AGENT_NAME` | sidecar | config `:team_name` | Agent registration name |
| `CORTEX_AUTH_TOKEN` | sidecar | K8s Secret or config | Auth token for Gateway |
| `CORTEX_SIDECAR_PORT` | sidecar | hardcoded `9091` | Port sidecar listens on |
| `SIDECAR_URL` | worker | `http://localhost:9091` | Worker talks to sidecar on localhost |
| `ANTHROPIC_API_KEY` | worker | K8s Secret | API key for Claude (worker needs it) |

---

## APIs

### SpawnBackend Behaviour Callbacks

```elixir
@impl Cortex.SpawnBackend
@spec spawn(keyword()) :: {:ok, handle()} | {:error, term()}
def spawn(opts)
# Required opts:
#   :team_name       - string, agent name
#   :run_id          - string, unique run identifier
# Optional opts:
#   :namespace       - string, default "cortex"
#   :gateway_url     - string, default from app config
#   :sidecar_image   - string, default from app config
#   :worker_image    - string, default from app config
#   :timeout_ms      - integer, max pod lifetime (default 3_600_000)
#   :resources       - map, resource requests/limits override
#   :service_account - string, K8s service account name
#   :auth_token      - string, gateway auth token (or use Secret ref)
#   :image_pull_secrets - list of strings
#   :registration_timeout_ms - integer, how long to wait for sidecar registration (default 60_000)

@impl Cortex.SpawnBackend
@spec stream(handle()) :: {:ok, Enumerable.t()} | {:error, term()}
def stream(handle)
# Returns a lazy stream of status events:
#   {:pod_phase, "Pending" | "Running" | "Succeeded" | "Failed"}
#   {:registered, agent_id}
#   {:done}
# NOTE: Unlike Local backend, K8s pods don't pipe stdout. The stream
# monitors pod phase transitions and registration status.

@impl Cortex.SpawnBackend
@spec stop(handle()) :: :ok
def stop(handle)
# Deletes the Pod. Idempotent — 404 is treated as success.

@impl Cortex.SpawnBackend
@spec status(handle()) :: :running | :done | :failed
def status(handle)
# Maps K8s Pod phase:
#   "Pending"   -> :running  (still starting)
#   "Running"   -> :running
#   "Succeeded" -> :done
#   "Failed"    -> :failed
#   "Unknown"   -> :failed
#   not found   -> :done     (already cleaned up)
```

### Helper Functions (not part of behaviour)

```elixir
@spec build_pod_spec(keyword()) :: map()
# Constructs the Pod manifest map from config options.

@spec connect() :: {:ok, K8s.Conn.t()} | {:error, term()}
# Establishes K8s API connection (in-cluster or kubeconfig).

@spec pod_name(String.t(), String.t()) :: String.t()
# Generates deterministic pod name: "cortex-<run_id_short>-<team_name>"
# Sanitized to K8s naming rules (lowercase, alphanumeric + hyphens, max 63 chars).

@spec wait_for_running(handle(), non_neg_integer()) :: :ok | {:error, :pod_start_timeout}
# Polls pod status until Running or Failed. Used internally by spawn/1.

@spec cleanup_run_pods(String.t(), String.t()) :: :ok
# Deletes all pods with label cortex.dev/run-id=<run_id> in the namespace.
# Used for batch cleanup when a run finishes.
```

### K8s API Interactions

All K8s API calls go through the `k8s` Elixir library:

| Operation | K8s API Call | When |
|-----------|-------------|------|
| Create Pod | `K8s.Client.create(pod_manifest)` | `spawn/1` |
| Get Pod | `K8s.Client.get("v1", "Pod", name: ..., namespace: ...)` | `status/1`, `wait_for_running/2` |
| Delete Pod | `K8s.Client.delete("v1", "Pod", name: ..., namespace: ...)` | `stop/1` |
| List Pods | `K8s.Client.list("v1", "Pod", namespace: ..., label_selectors: ...)` | `cleanup_run_pods/2` |

---

## Architecture / Component Boundaries

### How SpawnBackend.K8s Fits Into the Spawn Pipeline

```
YAML Config (backend: k8s)
  |
  v
Runner.Executor
  |-- sees provider: external, backend: k8s
  |-- calls SpawnBackend.K8s.spawn(team_name: "researcher", run_id: "abc")
  |     |-- builds Pod spec (sidecar + worker containers)
  |     |-- K8s.Client.create(pod) -> Pod created
  |     |-- waits for Pod phase = Running
  |     |-- waits for agent to appear in Gateway.Registry
  |     |-- returns {:ok, handle}
  |
  |-- dispatches work via Provider.External (unchanged)
  |     |-- finds agent by name in Gateway.Registry
  |     |-- pushes TaskRequest via gRPC
  |     |-- waits for TaskResult
  |
  |-- calls SpawnBackend.K8s.stop(handle) on completion
        |-- K8s.Client.delete(pod)
        |-- returns :ok
```

### Components Touched

1. **`Cortex.SpawnBackend.K8s`** (new) — the core module implementing the behaviour
2. **`Cortex.SpawnBackend.K8s.PodSpec`** (new) — pure-function module that builds Pod manifest maps from config; separated for testability
3. **`Cortex.SpawnBackend.K8s.Connection`** (new) — handles K8s API connection setup (in-cluster vs kubeconfig); separated so tests can inject a mock connection
4. **Config** — `config/config.exs` and `config/runtime.exs` additions for K8s defaults (namespace, images, gateway URL)

### Pod Lifecycle Management

```
spawn/1 called
  |
  v
Create Pod via K8s API
  |
  v
Poll Pod status (Pending -> Running)
  |           |
  |           v (timeout or error)
  |         return {:error, :pod_start_timeout}
  |         + delete failed Pod
  v
Pod Running -> sidecar boots -> registers with Gateway
  |
  v
Poll Gateway.Registry for agent name
  |           |
  |           v (timeout)
  |         return {:error, :registration_timeout}
  |         + delete Pod
  v
Return {:ok, handle}
  ... Provider.External dispatches work ...
  |
  v
stop/1 called -> Delete Pod via K8s API -> :ok
```

### Cleanup Strategy

1. **Normal cleanup:** `stop/1` deletes the Pod by name.
2. **Batch cleanup:** `cleanup_run_pods/2` deletes all Pods matching a `cortex.dev/run-id` label — used when a full run finishes.
3. **Safety net:** Pods have `activeDeadlineSeconds` (default 3600) so they self-terminate if Cortex crashes without cleanup.
4. **Startup cleanup:** On Cortex boot, optionally scan for orphaned Pods with `cortex.dev/managed-by: cortex` label and delete them.

---

## Correctness Invariants

1. **Every Pod created by `spawn/1` must be deleted by `stop/1` or batch cleanup.** No orphan Pods.
2. **`stop/1` is idempotent.** Calling it twice, or on an already-deleted Pod, returns `:ok`.
3. **Pod names are deterministic and unique** within a run — `cortex-<run_id_short>-<team_name>` prevents collisions across concurrent runs.
4. **Pod names conform to K8s naming rules** — lowercase, alphanumeric + hyphens, max 63 chars.
5. **`status/1` never raises** — API errors map to `:failed`, not found maps to `:done`.
6. **Auth tokens are never logged** — env var values for `CORTEX_AUTH_TOKEN` and `ANTHROPIC_API_KEY` must never appear in logs or telemetry.
7. **`spawn/1` cleans up on partial failure** — if sidecar container starts but worker fails, the whole Pod is deleted.
8. **K8s connection is established lazily** — if K8s is not configured, modules that don't use K8s backend are unaffected.

---

## Tests

### Unit Tests — `test/cortex/spawn_backend/k8s_test.exs`

Mock the K8s API client using `Mox` or a test adapter:

1. **`spawn/1` creates a Pod with correct spec** — verify container names, images, env vars, labels, resource limits
2. **`spawn/1` returns error when K8s API fails** — simulate 403/500 from create
3. **`spawn/1` returns error on pod start timeout** — simulate Pod stuck in Pending
4. **`spawn/1` returns error on registration timeout** — Pod Running but sidecar never registers
5. **`spawn/1` cleans up Pod on partial failure** — verify delete called after timeout
6. **`stop/1` deletes the Pod** — verify K8s delete API called
7. **`stop/1` is idempotent** — 404 from K8s treated as success
8. **`status/1` maps Pod phases correctly** — Pending->:running, Running->:running, Succeeded->:done, Failed->:failed
9. **`status/1` handles missing Pod** — returns :done
10. **Pod name generation** — verify sanitization, length limits, uniqueness

### PodSpec Unit Tests — `test/cortex/spawn_backend/k8s/pod_spec_test.exs`

1. **Default spec has all required fields** — containers, env, labels
2. **Custom images override defaults**
3. **Custom resource limits applied**
4. **Secret refs used when configured**
5. **Pod name sanitization** — special chars, long names, uppercase

### Integration Tests — `test/cortex/spawn_backend/k8s_integration_test.exs`

Tagged `@tag :k8s` (excluded by default, run explicitly):

1. **Full lifecycle: spawn -> status -> stop** — real Pod on kind cluster
2. **Pod cleanup on stop** — verify Pod gone after stop
3. **Batch cleanup** — create multiple Pods, cleanup_run_pods deletes all
4. **Gateway registration** — sidecar registers with Cortex Gateway (requires Gateway running)

### Failure Injection Tests — `test/cortex/spawn_backend/k8s_failure_test.exs`

1. **Invalid image** — Pod stuck in ImagePullBackOff, spawn returns error
2. **Resource quota exceeded** — K8s rejects Pod, spawn returns error
3. **Pod eviction during run** — status returns :failed

### Commands

```bash
mix test test/cortex/spawn_backend/k8s_test.exs
mix test test/cortex/spawn_backend/k8s/pod_spec_test.exs
mix test --include k8s test/cortex/spawn_backend/k8s_integration_test.exs
```

---

## Benchmarks + "Success"

### What to Measure

| Metric | How | Target |
|--------|-----|--------|
| Pod creation latency | Time from `K8s.Client.create` to Pod phase = Running | < 15s (pre-pulled images) |
| Registration latency | Time from Pod Running to agent in Gateway.Registry | < 10s |
| Total spawn-to-ready | Time from `spawn/1` call to `{:ok, handle}` return | < 30s |
| Cleanup latency | Time from `stop/1` call to Pod deleted | < 5s |
| Batch cleanup (10 pods) | Time to delete all pods for a run | < 15s |

### Success Criteria

- `mix test test/cortex/spawn_backend/k8s_test.exs` — all pass (unit, mocked)
- `mix test --include k8s` — all pass on a kind cluster with pre-pulled images
- Pod spawn-to-ready < 30s on kind with pre-pulled images
- No orphan Pods after test suite completes
- `mix compile --warnings-as-errors` passes
- `mix credo --strict` passes

### Benchmark Command

```bash
mix run bench/k8s_spawn_bench.exs
```

---

## Engineering Decisions & Tradeoffs

### Decision 1: Use the `k8s` Elixir library (not `bonny` or raw HTTP)

- **Decision:** Use the [`k8s`](https://hex.pm/packages/k8s) Elixir library for K8s API communication.
- **Alternatives considered:**
  - **`bonny`** — an operator framework, much heavier than needed. We're not building a K8s operator; we just need CRUD on Pods.
  - **Raw HTTP via `Req`/`Finch`** — possible, but we'd have to handle auth (kubeconfig parsing, token refresh, in-cluster service account), TLS, and API versioning ourselves.
  - **`kazan`** — less actively maintained than `k8s`.
- **Why:** `k8s` is lightweight, actively maintained, handles both in-cluster and kubeconfig auth, and provides a clean Elixir API for CRUD operations. It doesn't bring operator machinery we don't need.
- **Tradeoff acknowledged:** Adding a dependency. If `k8s` has bugs or goes unmaintained, we'd need to swap it. Mitigated by the fact that our usage is simple CRUD — easy to replace.

### Decision 2: Pods (not Jobs) with `restartPolicy: Never`

- **Decision:** Create bare Pods with `restartPolicy: Never`, not K8s Jobs.
- **Alternatives considered:**
  - **K8s Jobs** — Jobs manage pod lifecycle and retries. They're designed for batch workloads.
  - **Deployments** — designed for long-running services with replicas; wrong abstraction for one-shot agent runs.
- **Why:** Agent runs are one-shot: start, do work, stop. We don't want K8s to restart a failed agent (Cortex controls retry logic at the orchestration layer). Jobs add completion tracking we don't need, and the Job object persists after completion requiring separate cleanup. Bare Pods with `restartPolicy: Never` are simpler and match our lifecycle model exactly.
- **Tradeoff acknowledged:** No built-in retry from K8s. If a Pod is evicted, Cortex must detect the failure and decide whether to re-spawn. This is intentional — we want orchestration-level control over retries, not K8s-level.

### Decision 3: Separate PodSpec module for testability

- **Decision:** Extract Pod spec construction into `SpawnBackend.K8s.PodSpec`, a pure-function module.
- **Alternatives considered:**
  - **Inline in K8s module** — fewer files, but spec construction is complex enough to warrant isolation.
- **Why:** Pod spec generation is pure data transformation — input config, output map. Testing it requires zero mocking. Separating it makes unit tests fast and focused.
- **Tradeoff acknowledged:** One more module to maintain. Acceptable given the complexity of the Pod spec (two containers, env vars, probes, resources, labels).

### Decision 4: `activeDeadlineSeconds` as safety net

- **Decision:** Set `activeDeadlineSeconds` on all spawned Pods (default 3600s = 1 hour).
- **Alternatives considered:**
  - **No deadline** — rely entirely on Cortex calling `stop/1`. Risk: if Cortex crashes, Pods run forever.
  - **K8s CronJob for cleanup** — adds complexity and another resource to manage.
- **Why:** Defense in depth. Cortex should always call `stop/1`, but if it crashes or is restarted, the Pod self-terminates after the deadline. This prevents resource leaks.
- **Tradeoff acknowledged:** If an agent legitimately needs > 1 hour, the Pod is killed. Configurable via `:timeout_ms` in spawn config.

---

## Risks & Mitigations

### Risk 1: `k8s` library may not support all needed auth modes

- **Risk:** The `k8s` library might not handle in-cluster auth, exec-based auth (EKS/GKE), or specific kubeconfig formats.
- **Impact:** `spawn/1` would fail on certain clusters. Blocking for production.
- **Mitigation:** Spike: add `k8s` dep, write a script that connects to a kind cluster and creates a test Pod. Verify in-cluster auth works with a test Deployment in kind.
- **Validation time:** ~10 minutes

### Risk 2: Pod readiness timing — sidecar must register before worker starts polling

- **Risk:** The worker container starts polling `GET /task` before the sidecar has registered with Gateway. This could cause the worker to spin or fail.
- **Impact:** Race condition — worker may time out or report errors before the sidecar is ready.
- **Mitigation:** Use a readiness probe on the sidecar container (`/healthz`). The worker container uses an `initContainer` or startup probe that waits for `localhost:9091/healthz`. Alternatively, the worker already retries `GET /task` with backoff — verify this is sufficient.
- **Validation time:** ~10 minutes (check sidecar healthz endpoint + worker retry behavior)

### Risk 3: Gateway reachability from within the K8s cluster

- **Risk:** Pods in the K8s cluster can't reach the Cortex Gateway gRPC endpoint, especially when Cortex runs outside the cluster (local dev).
- **Impact:** Sidecar can't register, agent is never available for work.
- **Mitigation:** For local dev: document port-forward or NodePort setup. For production: Cortex runs in-cluster and Gateway is exposed as a K8s Service. Test with kind + port-forward in CI.
- **Validation time:** ~15 minutes

### Risk 4: Image pull latency makes spawn slow

- **Risk:** If container images aren't pre-pulled on the node, pulling them adds 30-60s to spawn time.
- **Impact:** Spawn-to-ready exceeds target. Bad UX for local dev.
- **Mitigation:** For kind/minikube: provide a `make k8s-load-images` target that pre-loads images. For production: use a private registry close to the cluster. Document image pull policies (`IfNotPresent` vs `Always`).
- **Validation time:** ~10 minutes

### Risk 5: RBAC permissions not configured

- **Risk:** The ServiceAccount used by Cortex doesn't have permission to create/delete Pods.
- **Impact:** `spawn/1` returns 403 Forbidden. Blocking.
- **Mitigation:** Provide a K8s manifest (`k8s/rbac.yaml`) with the minimum required Role + RoleBinding. Document the required permissions. Test in CI with kind cluster.
- **Validation time:** ~5 minutes

---

## Recommended API Surface

### Primary Module: `Cortex.SpawnBackend.K8s`

```elixir
# SpawnBackend behaviour callbacks
@spec spawn(keyword()) :: {:ok, Handle.t()} | {:error, term()}
@spec stream(Handle.t()) :: {:ok, Enumerable.t()} | {:error, term()}
@spec stop(Handle.t()) :: :ok
@spec status(Handle.t()) :: :running | :done | :failed

# Helper: batch cleanup all pods for a run
@spec cleanup_run_pods(String.t(), String.t()) :: :ok
```

### Pod Spec Builder: `Cortex.SpawnBackend.K8s.PodSpec`

```elixir
@spec build(keyword()) :: map()
@spec pod_name(String.t(), String.t()) :: String.t()
@spec sanitize_name(String.t()) :: String.t()
```

### Connection: `Cortex.SpawnBackend.K8s.Connection`

```elixir
@spec connect() :: {:ok, K8s.Conn.t()} | {:error, term()}
@spec connect(keyword()) :: {:ok, K8s.Conn.t()} | {:error, term()}
```

---

## Folder Structure

```
lib/cortex/spawn_backend/
  k8s.ex                    # Main module - SpawnBackend behaviour impl
  k8s/
    pod_spec.ex             # Pure-function Pod manifest builder
    connection.ex           # K8s API connection setup

test/cortex/spawn_backend/
  k8s_test.exs              # Unit tests (mocked K8s API)
  k8s/
    pod_spec_test.exs       # Pod spec builder tests (pure, no mocks)
  k8s_integration_test.exs  # Integration tests (real kind cluster, @tag :k8s)
  k8s_failure_test.exs      # Failure injection tests (mocked)

config/
  config.exs                # Add :cortex, Cortex.SpawnBackend.K8s defaults
  runtime.exs               # Add K8S_ env var reading

bench/
  k8s_spawn_bench.exs       # Spawn latency benchmark

k8s/
  rbac.yaml                 # ServiceAccount + Role + RoleBinding manifest
```

---

## Step-by-Step Task Plan

### Task 1: Add `k8s` dependency and K8s connection module

- **Outcome:** `k8s` hex dependency added; `Cortex.SpawnBackend.K8s.Connection` module connects to a K8s cluster.
- **Files to create/modify:**
  - `mix.exs` — add `{:k8s, "~> 2.0"}`
  - `lib/cortex/spawn_backend/k8s/connection.ex` — new module
  - `test/cortex/spawn_backend/k8s/connection_test.exs` — new test
  - `config/config.exs` — add K8s default config
  - `config/runtime.exs` — add K8S_ env var reading
- **Verification:**
  ```bash
  mix deps.get && mix compile --warnings-as-errors
  mix test test/cortex/spawn_backend/k8s/connection_test.exs
  ```
- **Commit message:** `feat: add k8s dependency and Connection module for K8s API access`

### Task 2: PodSpec builder — pure-function Pod manifest generation

- **Outcome:** `Cortex.SpawnBackend.K8s.PodSpec` builds correct Pod manifests with sidecar + worker containers, env vars, labels, probes, and resource limits. Fully tested with no external dependencies.
- **Files to create/modify:**
  - `lib/cortex/spawn_backend/k8s/pod_spec.ex` — new module
  - `test/cortex/spawn_backend/k8s/pod_spec_test.exs` — new test
- **Verification:**
  ```bash
  mix test test/cortex/spawn_backend/k8s/pod_spec_test.exs
  mix compile --warnings-as-errors
  ```
- **Commit message:** `feat: PodSpec builder for K8s sidecar + worker container manifests`

### Task 3: SpawnBackend.K8s — behaviour implementation with mocked K8s API

- **Outcome:** `Cortex.SpawnBackend.K8s` implements all four behaviour callbacks. Unit tests verify correct K8s API calls, error handling, and lifecycle management using a mocked K8s client.
- **Files to create/modify:**
  - `lib/cortex/spawn_backend/k8s.ex` — new module
  - `test/cortex/spawn_backend/k8s_test.exs` — new test
  - `test/support/k8s_mock.ex` — mock helpers (if needed)
- **Verification:**
  ```bash
  mix test test/cortex/spawn_backend/k8s_test.exs
  mix compile --warnings-as-errors
  mix credo --strict
  ```
- **Commit message:** `feat: SpawnBackend.K8s behaviour impl with lifecycle management`

### Task 4: Telemetry events and cleanup helpers

- **Outcome:** Telemetry events emitted for pod_created, pod_ready, pod_deleted, pod_failed. `cleanup_run_pods/2` batch-deletes all pods for a run. Idempotency tested.
- **Files to create/modify:**
  - `lib/cortex/spawn_backend/k8s.ex` — add telemetry + cleanup
  - `lib/cortex/telemetry.ex` — add K8s event emitters
  - `test/cortex/spawn_backend/k8s_test.exs` — extend tests
- **Verification:**
  ```bash
  mix test test/cortex/spawn_backend/k8s_test.exs
  mix compile --warnings-as-errors
  ```
- **Commit message:** `feat: K8s spawn telemetry events and batch pod cleanup`

### Task 5: RBAC manifest and integration tests with kind

- **Outcome:** K8s RBAC manifest provided. Integration tests pass on a kind cluster — full spawn/status/stop lifecycle with real Pods.
- **Files to create/modify:**
  - `k8s/rbac.yaml` — new manifest
  - `test/cortex/spawn_backend/k8s_integration_test.exs` — new test
  - `test/cortex/spawn_backend/k8s_failure_test.exs` — new test
  - `Makefile` — add `k8s-test` target
- **Verification:**
  ```bash
  kind create cluster --name cortex-test 2>/dev/null || true
  make k8s-load-images
  mix test --include k8s test/cortex/spawn_backend/k8s_integration_test.exs
  ```
- **Commit message:** `feat: K8s RBAC manifest and integration tests with kind`

### Task 6: Benchmark and documentation

- **Outcome:** Spawn latency benchmark runnable. Config documented. CLAUDE.md and EXPLAIN.md contributions ready.
- **Files to create/modify:**
  - `bench/k8s_spawn_bench.exs` — new benchmark
  - `config/config.exs` — finalize K8s config with comments
- **Verification:**
  ```bash
  mix run bench/k8s_spawn_bench.exs
  mix format --check-formatted
  mix compile --warnings-as-errors
  mix test
  ```
- **Commit message:** `feat: K8s spawn benchmark and config documentation`

---

## CLAUDE.md contributions (proposed, do NOT write the file)

## From SpawnBackend.K8s Engineer

### Coding Style
- K8s Pod specs are plain Elixir maps — do NOT use structs or Ecto schemas for them
- Pod name generation must be deterministic: `cortex-<run_id_short>-<team_name>`, sanitized to K8s DNS-1123 rules
- All K8s API calls go through `K8s.Client` — never raw HTTP
- Auth tokens and API keys must never appear in Logger output or telemetry metadata

### Dev Commands
```bash
# K8s integration tests (requires kind cluster)
kind create cluster --name cortex-test
make k8s-load-images
mix test --include k8s

# Spawn benchmark (requires kind cluster)
mix run bench/k8s_spawn_bench.exs

# Cleanup orphaned pods
kubectl delete pods -l app.kubernetes.io/managed-by=cortex -n cortex
```

### Before You Commit (K8s-specific)
1. `mix test test/cortex/spawn_backend/k8s_test.exs` — all unit tests pass
2. `mix test test/cortex/spawn_backend/k8s/pod_spec_test.exs` — spec builder tests pass
3. Pod names sanitized — no uppercase, no special chars, max 63 chars
4. No auth tokens in log statements
5. `stop/1` handles 404 gracefully (already-deleted pods)

### Guardrails
- `activeDeadlineSeconds` is ALWAYS set on spawned Pods — do not remove this safety net
- `restartPolicy: Never` — agent retry logic lives in Cortex, not K8s
- Labels `cortex.dev/run-id` and `cortex.dev/team` are mandatory on all Pods — they enable batch cleanup

---

## EXPLAIN.md contributions (proposed outline bullets)

### Flow / Architecture
- SpawnBackend.K8s creates a K8s Pod with two containers (sidecar + worker) sharing localhost networking
- The sidecar boots first, connects to Cortex Gateway via gRPC, and registers the agent
- The worker polls the sidecar's HTTP API for tasks, executes them, and posts results back
- Cortex waits for Gateway registration before dispatching work via Provider.External
- On completion, Cortex deletes the Pod

### Key Engineering Decisions + Tradeoffs
- Bare Pods (not Jobs) with `restartPolicy: Never` — Cortex owns retry logic, K8s owns compute
- `k8s` Elixir library for API access — lightweight, supports in-cluster + kubeconfig auth
- PodSpec builder as a separate pure-function module — fast unit tests, no mocking needed
- `activeDeadlineSeconds` as defense-in-depth against orphaned Pods

### Limits of MVP + Next Steps
- Single namespace per Cortex instance (multi-tenancy is future work)
- No auto-scaling — Cortex creates one Pod per agent per run
- No GPU/node affinity scheduling
- No persistent volumes (agent state is ephemeral)
- Future: K8s operator for CRD-based lifecycle, HPA integration, node selector support

### How to Run Locally + Validate
- Install `kind`: `brew install kind`
- Create cluster: `kind create cluster --name cortex-test`
- Load images: `make k8s-load-images`
- Run integration tests: `mix test --include k8s`
- Run benchmark: `mix run bench/k8s_spawn_bench.exs`
- For production: ensure RBAC manifest applied (`kubectl apply -f k8s/rbac.yaml`)

---

## READY FOR APPROVAL
