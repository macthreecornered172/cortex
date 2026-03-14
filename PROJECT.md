# Cortex

> Multi-agent orchestration system built on Elixir/OTP — DAG-based task execution, gossip-based exploration, self-healing, real-time visibility.

---

## Problem & Motivation

We need a system that can accomplish large, complex, multi-step objectives using multiple AI agents. Tasks and projects naturally decompose into DAGs — teams with dependencies, executed in tiers. The Go agent-orchestra CLI proved this concept but hit limits: file-based messaging, manual failure handling, no real-time visibility, and bolted-on cross-team communication.

Elixir/OTP is the right runtime for this. Each agent is a GenServer with its own heap and mailbox. Supervisors handle fault tolerance declaratively. PubSub gives native cross-agent messaging. LiveView provides a real-time dashboard with zero custom JavaScript. Distribution across BEAM nodes is built in.

Cortex replaces agent-orchestra with a system that's more capable, more observable, and more resilient.

---

## Definition of Done

- Define a project as YAML: teams, tasks, dependencies, config
- System builds DAG (Kahn's algorithm), executes tier-by-tier
- Teams within a tier run in parallel, tiers execute sequentially
- State flows forward — completed team results are injected into downstream prompts
- Failed teams restart via supervision with configurable retry
- LiveView dashboard shows real-time DAG execution, team status, costs, logs
- Gossip mode available for emergent exploration tasks
- Production-ready: metrics, logging, distributed tracing, Grafana dashboards
- Clean, documented, modular codebase

---

## Key Components

- **Agent Server** — GenServer managing agent lifecycle, state, and coordination
- **DAG Engine** — Kahn's algorithm for topological sort, tier extraction
- **Spawner** — Spawns `claude -p` processes, captures stream-json results
- **Prompt Injector** — Builds prompts with role, context, tasks, upstream results
- **Workspace** — Run state management (status, results, logs, registry)
- **Config** — YAML parsing and validation for project definitions
- **LLM Client** — Behaviour-based Claude API client with rate limiting
- **Tool Runtime** — Sandboxed tool execution in isolated processes
- **Gossip Protocol** — Peer-to-peer knowledge exchange (secondary coordination mode)
- **Knowledge Store** — CRDT-based conflict-free knowledge merging
- **LiveView Dashboard** — Real-time DAG visualization and control panel
- **Persistence** — Ecto + SQLite for run history, results, events
- **Observability** — Telemetry, Prometheus, Grafana, Loki, Tempo

---

## Tech Stack

- **Language:** Elixir
- **Framework:** Phoenix + LiveView
- **OTP:** GenServer, DynamicSupervisor, Registry, PubSub, Task
- **Database:** SQLite via Ecto
- **LLM:** Claude API via `Req` HTTP client
- **Observability:** Telemetry, Prometheus (via `prom_ex`), Grafana, Loki, Tempo
- **Testing:** ExUnit + Mox + Benchee

---

## Non-Goals

- Not a hosted SaaS platform (local-first tool)
- Not building a custom LLM — uses external APIs
- No mobile or desktop clients — LiveView web UI only
- Not a general-purpose agent framework — opinionated around DAG orchestration

---

## Constraints

- Must work as a standalone Mix project (no umbrella app for v1)
- Claude API is the primary LLM provider (others via behaviour)
- LiveView for all UI — zero custom JavaScript unless absolutely necessary
- Agent-to-agent communication via native BEAM messaging (no external message brokers)

---

## Team Roles by Phase

| Phase | Teammates |
|-------|-----------|
| OTP Foundation | Agent Core, LLM Client, Tool Runtime, Scaffold |
| OTP Foundation QE | Agent Core QE, LLM Client QE, Tool Runtime QE, Integration QE |
| DAG Orchestration | Config, DAG Engine, Prompt Injection, Spawner, Workspace, Orchestration Loop |
| DAG Orchestration QE | Config QE, DAG QE, Spawner QE, E2E QE, State QE |
| LiveView Dashboard | Phoenix Setup, DAG Viz, Run Management, Persistence |
| LiveView Dashboard QE | LiveView QE, Persistence QE, Visual QE |
| Gossip + Advanced | Gossip Protocol, Knowledge Store, Topology, Distribution |
| Gossip + Advanced QE | Gossip QE, CRDT QE, Distribution QE |
| Performance | Benchmarks, Profiling, Load Testing, Optimization |
| SRE | Telemetry, Logging, Tracing, Infra |
| Polish | Documentation, README, Code Quality, Developer Experience |

---

## Phases

| # | Phase | Config | Type | Goal |
|---|-------|--------|------|------|
| 1 | OTP Foundation | docs/01-otp-foundation/kickoff.yaml | Build | Agent GenServer, supervision, LLM client, tool execution, config, PubSub |
| 2 | OTP Foundation QE | docs/02-otp-foundation-qe/kickoff.yaml | QE | Unit tests, integration tests, fault injection, supervision recovery |
| 3 | DAG Orchestration | docs/03-dag-orchestration/kickoff.yaml | Build | YAML config, DAG engine, prompt injection, spawner, workspace, orchestration loop |
| 4 | DAG Orchestration QE | docs/04-dag-orchestration-qe/kickoff.yaml | QE | E2E runs, failure recovery, concurrent tiers, timeout handling, state integrity |
| 5 | LiveView Dashboard | docs/05-liveview-dashboard/kickoff.yaml | Build | Phoenix setup, DAG viz, run management, agent logs, persistence |
| 6 | LiveView Dashboard QE | docs/06-liveview-dashboard-qe/kickoff.yaml | QE | LiveView tests, real-time updates, persistence roundtrips, UI edge cases |
| 7 | Gossip + Advanced | docs/07-gossip-advanced/kickoff.yaml | Build | Gossip protocol, CRDTs, knowledge store, topology, distribution |
| 8 | Gossip + Advanced QE | docs/08-gossip-advanced-qe/kickoff.yaml | QE | Gossip convergence, CRDT semantics, cross-node, merge correctness |
| 9 | Performance | docs/09-performance/kickoff.yaml | Perf | Benchmarks, profiling, bottleneck identification, optimization, load testing |
| 10 | SRE | docs/10-sre/kickoff.yaml | Ops | Telemetry, structured logging, distributed tracing, Grafana + Prometheus + Loki + Tempo |
| 11 | Polish | docs/11-polish/kickoff.yaml | Polish | Documentation, READMEs, code cleanup, module organization, readability |

---

## Usage in Phase Planning

This file is the source of truth for all planning phases.
List it as the first dependency in every phase config:

```yaml
dependencies:
  - PROJECT.md
```
