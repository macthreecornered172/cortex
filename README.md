# Cortex

Multi-agent orchestration system built on Elixir/OTP. Cortex manages teams of AI agents that collaborate on complex, multi-step objectives via `claude -p` processes. It supports two coordination modes: **DAG orchestration** for structured, dependency-aware execution, and **gossip protocol** for emergent, decentralized knowledge sharing.

## Features

### Orchestration
- **DAG-based execution** -- define teams with dependencies in YAML, execute in parallel tiers using Kahn's algorithm
- **Continue Run** -- pick up interrupted runs where the Runner left off (terminal closed, node crash). Reads config from DB, skips completed teams, re-executes remaining tiers with full context injection
- **Resume sessions** -- resume stalled `claude -p` sessions via `claude --resume <session_id>`, extracted from NDJSON logs
- **Restart with context** -- spawn fresh sessions for expired ones, injecting log history so agents know what was already done
- **File-based messaging** -- inbox/outbox per team, outbox watcher polls for progress messages, coordinator can send messages mid-run

### Observability
- **Live token tracking** -- spawner parses intermediate NDJSON usage, streams to LiveView via PubSub in real-time
- **Activity feed** -- tool use events extracted from NDJSON, displayed as real-time feed on run detail page
- **Coordinator status** -- Runner processes register in Elixir Registry; dashboard shows alive/dead with auto-cleanup on process death
- **Stalled detection** -- per-team last_seen timestamps; teams flagged stalled after 5 minutes of no PubSub events
- **Diagnostics tab** -- LogParser parses NDJSON logs into structured timelines with auto-diagnosis (died during tool, hit max turns, no session, etc.)
- **Auto-generated summaries** -- run summary auto-builds on tier completion, includes per-team status, tokens, and diagnostics
- **Telemetry + Prometheus** -- structured telemetry events for runs, tiers, teams, tools; Prometheus scraping via `/metrics`
- **Grafana dashboards** -- pre-configured dashboards (start with `make up` for Phoenix + Prometheus + Grafana stack)

### Gossip Protocol
- **CRDT-backed knowledge stores** -- per-agent KnowledgeStore GenServers with vector clocks for conflict-free convergence
- **Push-pull exchange** -- agents compare digests, identify missing/newer entries, merge with causal ordering
- **Topology strategies** -- full mesh, ring, and random-k peering
- **Coordinator mode** -- file-based agent I/O with configurable exchange rounds

### Dashboard (LiveView)
- **Run detail** -- 5 tabs: Overview, Activity, Messages, Logs, Diagnostics
- **Overview tab** -- coordinator status card, status grid (pending/running/stalled/done/failed), DAG visualization, team cards with tokens and health indicators
- **Messages tab** -- per-team inbox/outbox viewer with send message form
- **Logs tab** -- raw NDJSON log viewer with collapsible parsed JSON, sort toggle
- **Diagnostics tab** -- event timeline, diagnosis banner, per-team resume/restart buttons
- **Team detail** -- individual team page with prompt, logs, resume/restart/mark-failed actions
- **Gossip view** -- interactive topology visualization, round-by-round knowledge propagation

### Infrastructure
- **Pluggable tool system** -- sandboxed tool execution with timeout enforcement and crash isolation
- **Persistent event log** -- all orchestration events stored in SQLite via Ecto
- **Idle liveness checks** -- spawner checks if port process is alive every 2 minutes, catches silent deaths

## Quick Start

### Prerequisites

- Elixir 1.17+
- Erlang/OTP 27+

### Setup

```bash
git clone <repo-url> && cd cortex
mix deps.get
mix ecto.create
mix ecto.migrate
mix test
```

### Start the dashboard

```bash
mix phx.server
# Visit http://localhost:4000
```

### Run an orchestration

```bash
# Dry run (show execution plan without spawning)
mix run -e 'Cortex.Orchestration.Runner.run("orchestra.yaml", dry_run: true) |> IO.inspect()'

# Full run
mix run -e 'Cortex.Orchestration.Runner.run("orchestra.yaml") |> IO.inspect()'

# Resume stalled teams in an existing workspace
mix cortex.resume /path/to/workspace

# Resume with auto-retry on rate limits
mix cortex.resume /path/to/workspace --auto-retry --retry-delay 120
```

### Start with Grafana stack

```bash
make up    # Phoenix:4000 + Prometheus:9090 + Grafana:3000 (admin/cortex)
```

## Configuration

Cortex projects are defined in `orchestra.yaml` files:

```yaml
name: "my-project"
workspace_path: /tmp/my-project

defaults:
  model: sonnet                  # LLM model (default: sonnet)
  max_turns: 200                 # Max conversation turns per agent
  permission_mode: acceptEdits   # How agents handle file edits
  timeout_minutes: 30            # Per-team timeout

teams:
  - name: backend
    lead:
      role: "Backend Engineer"
      model: opus                # Optional per-team model override
    members:
      - role: "Database Expert"
        focus: "Schema design and migrations"
    tasks:
      - summary: "Build the REST API"
        details: "Implement CRUD endpoints for all resources"
        deliverables:
          - "lib/api/router.ex"
        verify: "mix test test/api/"
    context: |
      Use Phoenix framework with Ecto for persistence.

  - name: frontend
    lead:
      role: "Frontend Engineer"
    tasks:
      - summary: "Build the web UI"
    depends_on:
      - backend               # Waits for backend to complete
```

### Configuration Fields

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `name` | Yes | -- | Project name |
| `workspace_path` | No | `"."` | Directory for `.cortex/` workspace |
| `defaults.model` | No | `"sonnet"` | Default LLM model |
| `defaults.max_turns` | No | `200` | Max conversation turns |
| `defaults.permission_mode` | No | `"acceptEdits"` | Permission mode |
| `defaults.timeout_minutes` | No | `30` | Per-team timeout |
| `teams[].name` | Yes | -- | Unique team identifier |
| `teams[].lead.role` | Yes | -- | Team lead role description |
| `teams[].lead.model` | No | project default | Model override |
| `teams[].members` | No | `[]` | Team member list |
| `teams[].tasks` | Yes | -- | At least one task |
| `teams[].depends_on` | No | `[]` | Team name dependencies |
| `teams[].context` | No | `nil` | Additional prompt context |

## Architecture

### Supervision Tree

```
Cortex.Supervisor (one_for_one)
  |-- Phoenix.PubSub (Cortex.PubSub)
  |-- Registry (Cortex.Agent.Registry)
  |-- DynamicSupervisor (Cortex.Agent.Supervisor)
  |-- Task.Supervisor (Cortex.Tool.Supervisor)
  |-- Cortex.Tool.Registry (Agent)
  |-- Registry (Cortex.Orchestration.RunnerRegistry)
  |-- Registry (Cortex.Messaging.MailboxRegistry)
  |-- Cortex.Messaging.Router
  |-- Cortex.Messaging.Supervisor
  |-- Cortex.Repo (Ecto/SQLite)
  |-- Cortex.Store.EventSink
  |-- CortexWeb.Telemetry
  |-- TelemetryMetricsPrometheus.Core
  |-- CortexWeb.Endpoint (Phoenix)
```

### DAG Orchestration (`lib/cortex/orchestration/`)

The orchestration engine loads YAML configs, builds a dependency DAG using Kahn's algorithm, and executes teams in parallel tiers. Each team spawns an external `claude -p` process via Erlang ports, streams NDJSON output for real-time token/activity tracking, and records results to both the workspace (`.cortex/state.json`) and the DB.

Key modules:
- **Runner** -- top-level orchestrator: `run/2`, `continue_run/2`, `resume_run/2`, `coordinator_alive?/1`
- **DAG** -- Kahn's algorithm for topological sort into execution tiers
- **Spawner** -- spawns `claude -p` via ports, parses NDJSON, extracts session IDs, detects rate limits
- **Workspace** -- manages `.cortex/` directory: `state.json`, `registry.json`, per-team logs and results
- **Injection** -- builds rich prompts with role, tasks, upstream team results, inbox instructions
- **LogParser** -- parses NDJSON logs into structured timelines with auto-diagnosis
- **Config.Loader** -- YAML parsing and validation into typed Config structs

### Gossip Protocol (`lib/cortex/gossip/`)

Agents in gossip mode each have a KnowledgeStore (GenServer) holding entries with vector clocks. The gossip protocol performs push-pull exchanges: agents compare digests, identify missing/newer entries, and merge with causal ordering. Concurrent conflicts are resolved by confidence score, then timestamp.

### Messaging (`lib/cortex/messaging/`)

File-based messaging (InboxBridge) for team coordination during runs, plus an in-process messaging system (Router, Mailbox, Bus) for agent-to-agent communication.

### Web Dashboard (`lib/cortex_web/live/`)

Phoenix LiveView provides a real-time dashboard. All pages subscribe to PubSub events for live updates without polling.

- **DashboardLive** -- system overview, recent runs
- **RunListLive** -- filterable run history
- **RunDetailLive** -- tabbed run view (overview, activity, messages, logs, diagnostics)
- **TeamDetailLive** -- individual team inspection with resume/restart/mark-failed
- **NewRunLive** -- launch runs from the web UI
- **GossipLive** -- gossip session viewer with topology visualization

### Persistence (`lib/cortex/store/`)

Ecto with SQLite stores run history, team results, and event logs. The EventSink GenServer subscribes to PubSub and persists events automatically.

Schemas: `Run`, `TeamRun`, `EventLog`

## Workspace Layout

When a run executes, it creates a `.cortex/` directory:

```
.cortex/
  state.json          # Per-team status, result summaries, token counts
  registry.json       # Team registry: names, session IDs, timestamps
  results/
    <team>.json       # Full result per team
  logs/
    <team>.log        # Raw NDJSON output from claude -p
  messages/
    <team>/
      inbox.json      # Messages received by team
      outbox.json     # Messages sent by team
```

## Running Tests

```bash
mix test                              # All tests (671 tests, ~8s)
mix test --trace                      # Verbose output
mix test test/cortex/orchestration/   # Specific directory
mix test --cover                      # With coverage
```

## Benchmarks

```bash
mix run bench/agent_bench.exs    # Agent lifecycle benchmarks
mix run bench/gossip_bench.exs   # Gossip protocol benchmarks
mix run bench/dag_bench.exs      # DAG engine benchmarks
```

## Development

```bash
mix format                       # Format code
mix format --check-formatted     # Check formatting (CI)
mix compile --warnings-as-errors # Compile check (CI)
```

## Project Structure

```
cortex/
  bench/                          # Benchee benchmark scripts
  config/                         # Environment configs
  lib/
    cortex/
      agent/                      # Agent GenServer, Config, State, Registry
      gossip/                     # KnowledgeStore, Protocol, VectorClock, Topology
      messaging/                  # InboxBridge, OutboxWatcher, Router, Mailbox, Bus
      orchestration/              # Runner, DAG, Spawner, Workspace, Config, LogParser
      perf/                       # Profiler utilities
      store/                      # Ecto schemas (Run, TeamRun, EventLog), EventSink
      tool/                       # Tool behaviour, executor, registry
      application.ex              # OTP application and supervision tree
      events.ex                   # PubSub event broadcasting
      health.ex                   # System health checks
      telemetry.ex                # Telemetry event definitions
    cortex_web/
      components/                 # Phoenix components (core, DAG)
      live/                       # LiveView modules (dashboard, runs, teams, gossip)
      endpoint.ex                 # Phoenix endpoint
      router.ex                   # Route definitions
  priv/
    repo/migrations/              # Ecto migrations
  test/                           # Test suite (mirrors lib/ structure)
```
