# External Compute Spawning

> Enable Cortex to spawn agents on remote compute (Docker, Kubernetes) and route orchestration work to registered sidecar agents — all through unified Provider and SpawnBackend abstractions that preserve the existing local CLI workflow as the default.

---

## Problem & Motivation

Cortex currently spawns all agents as local `claude -p` Erlang port processes on the same machine running the orchestrator. This limits scale (10 agents = 10 heavyweight processes on your laptop) and means the orchestrator and agents share failure domains. We want Cortex to spawn agents anywhere — local containers, k8s Jobs, cloud VMs — and route orchestration work to them through the existing Gateway infrastructure.

The existing Cluster Mode work already provides the gRPC plumbing: the proto defines `TaskRequest`/`TaskResult`, the Go sidecar exposes `GET /task` and `POST /task/result`, and the Gateway tracks registered agents. But nothing in the orchestration layer sends `TaskRequest` to external agents yet — `Gateway.Registry.route_task_result/2` is a no-op placeholder.

This project bridges that gap through two convergent flows:

- **Flow A — Work to existing agents:** Orchestrator → `Provider.External` → Gateway → already-connected sidecar → agent
- **Flow B — Spawn new agent + sidecar:** Orchestrator → `SpawnBackend.K8s` (creates Pod with agent + sidecar containers) → sidecar boots & registers with Gateway → `Provider.External` assigns work

Both flows converge at `Provider.External` + `Gateway.Discovery`. The Provider abstraction routes tasks; the SpawnBackend abstraction creates compute when needed. Users who don't need remote compute keep using `Provider.CLI` + `SpawnBackend.Local` (the default) with zero changes to their workflow.

---

## Definition of Done

1. A `Provider` behaviour abstracts how Cortex communicates with LLMs. Existing CLI spawning works through `Provider.CLI`. `Provider.External` routes work to registered sidecar agents via Gateway.
2. A `SpawnBackend` behaviour abstracts where agents run. Existing local spawning works through `SpawnBackend.Local`. New backends `SpawnBackend.Docker` and `SpawnBackend.K8s` spawn agents as co-deployed agent+sidecar units.
3. YAML configs support `provider` and `backend` fields per team. Omitting both preserves current CLI behaviour.
4. The orchestration layer (DAG, mesh, gossip) works with any provider/backend combination.
5. `Provider.External` dispatches `TaskRequest` to sidecar agents discovered via `Gateway.Discovery`, and `Gateway.Registry.route_task_result/2` delivers results back to the orchestrator.
6. `SpawnBackend.Docker` and `SpawnBackend.K8s` co-deploy an agent process + sidecar container as a single unit (Pod with 2 containers in K8s), where the sidecar registers with Gateway on boot, making the agent available to `Provider.External`.
7. The LiveView dashboard shows remote agent status.
8. All existing tests continue to pass; new code has comprehensive tests.

---

## Key Components

- **Provider behaviour** (`lib/cortex/provider.ex`) — unified interface for LLM communication
- **Provider.CLI** (`lib/cortex/provider/cli.ex`) — wraps existing Spawner for `claude -p` (default, no sidecar)
- **Provider.External** (`lib/cortex/provider/external.ex`) — dispatches `TaskRequest` to sidecar agents via Gateway
- **Gateway.Discovery** (`lib/cortex/gateway/discovery.ex`) — capability-based agent routing for `Provider.External`
- **SpawnBackend behaviour** (`lib/cortex/spawn_backend.ex`) — unified interface for agent compute
- **SpawnBackend.Local** (`lib/cortex/spawn_backend/local.ex`) — wraps existing local port spawning (default)
- **SpawnBackend.Docker** (`lib/cortex/spawn_backend/docker.ex`) — spawn agent + sidecar in Docker containers
- **SpawnBackend.K8s** (`lib/cortex/spawn_backend/k8s.ex`) — spawn agent + sidecar as Kubernetes Pod (2 containers)
- **Config updates** — provider/backend fields in YAML config schema
- **Dashboard updates** — remote agent status in LiveView

### Existing Infrastructure (from Cluster Mode)

These components already exist and are leveraged by Phases 2–3:

- **Gateway.Registry** (`lib/cortex/gateway/registry.ex`) — tracks registered agents by ID, capability, transport; `route_task_result/2` is a no-op placeholder to be wired in Phase 2
- **Gateway.GrpcServer** (`lib/cortex/gateway/grpc_server.ex`) — bidirectional gRPC stream handling `RegisterRequest`, `Heartbeat`, `TaskResult`, etc.
- **Proto** (`proto/cortex/gateway/v1/gateway.proto`) — defines `TaskRequest`, `TaskResult`, `AgentMessage`/`GatewayMessage` envelopes
- **Go sidecar** (`sidecar/`) — exposes `GET /task` + `POST /task/result` HTTP API for the agent process; connects to Gateway via gRPC

---

## Tech Stack

- **Language:** Elixir 1.16+, Erlang/OTP 26+
- **Framework:** Phoenix 1.7, LiveView
- **gRPC:** existing proto + `GRPC` Elixir library (Gateway ↔ sidecar)
- **K8s client:** `k8s` Elixir library (k8s API communication)
- **Docker:** Docker Engine API via HTTP (unix socket)
- **Database:** SQLite via Ecto (existing)
- **Sidecar:** Go (existing, `sidecar/` directory)
- **Testing:** ExUnit, Mox for provider/backend mocking

---

## Non-Goals

- **Sidecar binary changes** — the Go sidecar already exposes the needed HTTP + gRPC interfaces; we consume them, not modify them
- **Agent-to-agent tool use** — separate feature (peer requests exist in proto but are out of scope)
- **Provider.HTTP (Claude Messages API)** — a useful Provider implementation but orthogonal to the external compute story; can be added independently later (see Future Work)
- **Multi-provider beyond Claude** — OpenAI/Ollama adapters are future work
- **Auto-scaling** — k8s HPA or Fly autoscale; we do manual spawning for now
- **GPU/hardware-specific scheduling** — out of scope

---

## Constraints

- Must not break existing CLI-based orchestration — all current tests pass
- `provider: cli` + `backend: local` (the default) must work without a sidecar, Gateway, or any network dependency
- Must work with existing YAML config format (additive fields only)
- External provider requires Gateway to be running and at least one sidecar-connected agent registered
- Docker backend requires Docker Engine running locally
- K8s backend requires a valid kubeconfig and cluster access
- Existing Spawner module is the primary integration point — refactor, don't rewrite

---

## Team

| Role | Focus |
|------|-------|
| Behaviour Architect | Provider and SpawnBackend behaviour definitions |
| CLI Refactor Engineer | Wrap existing Spawner into Provider.CLI + SpawnBackend.Local |
| Config Engineer | YAML config updates for provider/backend fields |
| Integration Engineer | Wire orchestration layer to use Provider abstraction |
| External Provider Engineer | Provider.External + Gateway.Discovery integration |
| Task Routing Engineer | Wire `route_task_result/2` back into orchestration Runner |
| Docker Backend Engineer | SpawnBackend.Docker with agent+sidecar co-deployment |
| K8s Backend Engineer | SpawnBackend.K8s Pod spec with agent + sidecar containers |
| Container Spec Engineer | Dockerfile, agent image, sidecar init, startup scripts |
| Streaming & Dashboard Engineer | Output streaming from remote backends, LiveView updates |

---

## Provider × Backend Compatibility

Not all combinations make sense. This matrix shows which pairings are valid:

| | SpawnBackend.Local | SpawnBackend.Docker | SpawnBackend.K8s |
|---|---|---|---|
| **Provider.CLI** | Default. Local `claude -p` port process. No sidecar. | N/A — CLI requires local port | N/A — CLI requires local port |
| **Provider.External** | N/A — External needs sidecar | Spawn agent+sidecar in Docker, route via Gateway | Spawn agent+sidecar Pod, route via Gateway |

The two deployment modes:
1. **`cli` + `local`** (default) — current behaviour, zero new dependencies, no sidecar
2. **`external` + `docker`/`k8s`** — spawn agent+sidecar pair, route work through Gateway

---

## Phases

| Phase | Config | Goal |
|-------|--------|------|
| 1 — Foundation | `docs/compute-spawning/phase-1-foundation/kickoff.yaml` | Provider & SpawnBackend behaviours; refactor existing code into Provider.CLI + SpawnBackend.Local |
| 2 — External Provider | `docs/compute-spawning/phase-2-external-provider/kickoff.yaml` | Provider.External + Gateway.Discovery; wire `route_task_result/2` to deliver results back to orchestrator |
| 3 — Remote Backends | `docs/compute-spawning/phase-3-remote-backends/kickoff.yaml` | SpawnBackend.Docker/K8s with agent+sidecar co-deployment pattern |

### Phase 1 — Foundation

Extract `Provider` and `SpawnBackend` behaviours from the existing codebase. Refactor the current `Spawner` into `Provider.CLI` + `SpawnBackend.Local` behind those behaviours. Wire the orchestration `Runner.Executor` to dispatch through `Provider` instead of calling `Spawner` directly. Add `provider`/`backend` fields to YAML config (defaulting to `cli`/`local`). All existing tests must pass — this is a pure refactor with no new capabilities.

### Phase 2 — External Provider

Implement `Provider.External` to dispatch `TaskRequest` messages to sidecar-connected agents discovered via `Gateway.Discovery`. Wire `Gateway.Registry.route_task_result/2` (currently a no-op) to deliver `TaskResult` back to the orchestration `Runner` as completed team results. This is **Flow A**: routing work to agents that are already registered with Gateway (connected manually or from a prior spawn). Key integration points:

- `Provider.External.run_task/2` → find agent by capability via `Registry.list_by_capability/2` → push `TaskRequest` via `Registry.get_push_pid/2`
- `GrpcServer.handle_task_result/2` → `Registry.route_task_result/2` → callback/message to `Runner.Executor` with the `TeamResult`
- Gateway.Discovery handles agent selection (capability match, load balancing, health checks)

### Phase 3 — Remote Backends

Implement `SpawnBackend.Docker` and `SpawnBackend.K8s` to provision compute that co-deploys an agent process alongside a sidecar as a single unit. This is **Flow B**: the orchestrator creates new compute when no suitable agent is already registered.

**K8s co-deployment pattern (Pod with 2 containers):**
```yaml
# Conceptual Pod spec — SpawnBackend.K8s generates this
apiVersion: v1
kind: Pod
spec:
  containers:
    - name: agent
      image: cortex-agent:latest          # runs claude or custom agent
      env:
        - name: CORTEX_SIDECAR_URL
          value: "http://localhost:9090"   # talks to sidecar via localhost
    - name: sidecar
      image: cortex-sidecar:latest        # Go sidecar binary
      env:
        - name: CORTEX_GATEWAY_ADDR
          value: "gateway.cortex:4001"    # registers with Gateway on boot
        - name: CORTEX_AGENT_NAME
          value: "$(TEAM_NAME)"
        - name: CORTEX_CAPABILITIES
          value: "$(CAPABILITIES)"
      ports:
        - containerPort: 9090             # agent-facing HTTP API
```

**Lifecycle:**
1. `SpawnBackend.K8s.spawn/1` creates Pod with agent + sidecar containers
2. Sidecar boots, connects to Gateway via gRPC, sends `RegisterRequest`
3. Gateway registers the agent → now discoverable by `Provider.External`
4. Orchestrator dispatches `TaskRequest` via `Provider.External` → Gateway → sidecar → agent
5. Agent completes work, calls sidecar `POST /task/result` → sidecar sends `TaskResult` via gRPC → Gateway → orchestrator
6. `SpawnBackend.K8s.terminate/1` deletes the Pod when the run completes

**Docker variant:** Same pattern but with `docker run` launching two linked containers on a shared network.

---

## Architecture Diagram

```
                          ┌──────────────────────────────┐
                          │      Orchestration Layer      │
                          │  Runner.Executor / DAG / Mesh │
                          └──────────┬───────────────────┘
                                     │ dispatch via Provider behaviour
                          ┌──────────┴──────────┐
                          ▼                      ▼
                  ┌──────────────┐      ┌───────────────────┐
                  │ Provider.CLI │      │ Provider.External  │
                  │ claude -p    │      │ Gateway route      │
                  │ (default)    │      │ TaskRequest        │
                  └──────┬───────┘      └────────┬──────────┘
                         │                       │
                         ▼                       ▼
                ┌────────────────┐    ┌─────────────────────┐
                │ SpawnBackend   │    │  Gateway.Discovery   │
                │  .Local        │    │  (capability routing)│
                │ (Erlang port)  │    └─────────┬───────────┘
                └────────────────┘              │
                                                ▼
                                      ┌─────────────────┐
                                      │ Gateway.Registry │
                                      │ (registered      │
                                      │  sidecar agents) │
                                      └────────┬────────┘
                                               │ gRPC stream
                                ┌──────────────┴──────────────┐
                                ▼                              ▼
                      ┌──────────────────┐          ┌──────────────────┐
                      │  Pre-registered  │          │ SpawnBackend     │
                      │  agent+sidecar   │          │ .Docker / .K8s   │
                      │  (Flow A)        │          │ creates new      │
                      │                  │          │ agent+sidecar    │
                      │                  │          │ (Flow B)         │
                      └──────────────────┘          └──────────────────┘
```

---

## Future Work

- **Provider.HTTP** — Call the Claude Messages API directly with SSE streaming and an agentic conversation loop (send → stream → tool_use → execute → repeat). This is an independent Provider implementation that doesn't require a sidecar or Gateway. It can be added as a standalone phase after or in parallel with the phases above.
- **Multi-provider adapters** — OpenAI, Ollama, etc. behind the same Provider behaviour.
- **Auto-scaling** — k8s HPA integration for SpawnBackend.K8s.

---

## Usage in Phase Planning

This file is the source of truth for all planning phases.
List it as the first dependency in every phase config:

```yaml
dependencies:
  - docs/compute-spawning/PROJECT.md
```
