# Phase 1: OTP Foundation — Summary

> 166 tests, 0 failures. All code compiles with zero warnings.

## What Was Built

Phase 1 creates the **shared infrastructure** that everything else in Cortex sits on top of. Think of it as the plumbing — no agents actually do useful work yet, but after this phase we have the building blocks to start, manage, and coordinate them.

### 1. Mix Project Scaffold

**What it is:** The project skeleton — like `go mod init` or `npm init` but for Elixir.

- `mix.exs` — project config, dependencies, build settings
- `config/` — environment-specific settings (dev, test)
- Standard Elixir boilerplate (`.formatter.exs`, `.gitignore`, test helper)

**Dependencies we pulled in:**
- `phoenix_pubsub` — message broadcasting (events system)
- `uniq` — UUID generation for agent IDs
- `yaml_elixir` — YAML parsing (for project configs in later phases)
- `jason` — JSON encoding/decoding

### 2. Supervision Tree (`lib/cortex/application.ex`)

**What it is:** The thing that starts when the app boots. It launches 5 child processes in order:

```
Cortex.Application (the boss)
├── Phoenix.PubSub       — event broadcasting system
├── Registry              — agent lookup by ID (built-in Elixir)
├── DynamicSupervisor     — spawns/manages agent processes
├── Task.Supervisor       — spawns/manages tool execution tasks
└── Tool.Registry         — maps tool names to their code modules
```

**Why order matters:** Agents need to register themselves (Registry) and announce they've started (PubSub) during startup. Those services have to be running first.

**Key concept — Supervision:** If any of these processes crash, the supervisor automatically restarts them. This is the core value of Elixir/OTP — fault tolerance is built into the architecture, not bolted on.

### 3. Agent Registry (`lib/cortex/agent/registry.ex`)

**What it is:** A phone book for agents. When an agent starts, it registers its UUID. Any part of the system can look up an agent by ID to get its process handle (pid).

**Key functions:**
- `via_tuple(id)` — generates the "address" agents use to register themselves
- `lookup(id)` — find an agent by UUID → returns its pid or `:not_found`
- `all()` — list every running agent as `{id, pid}` pairs

**Why it matters:** Without this, you'd have no way to find a specific agent among potentially dozens running simultaneously.

### 4. Agent Supervisor (`lib/cortex/agent/supervisor.ex`)

**What it is:** The manager that starts and stops agent processes.

**Key functions:**
- `start_agent(config)` — creates a new agent process from a config map
- `stop_agent(id)` — gracefully shuts down an agent by ID
- `list_agents()` — delegates to Registry to list all running agents

**Important design choice:** Agents use `:temporary` restart strategy — if an agent crashes, it does NOT auto-restart. This is intentional. The orchestration layer (Phase 3) will decide what to do when an agent fails. You don't want the supervisor fighting the orchestrator's decisions.

### 5. Events System (`lib/cortex/events.ex`)

**What it is:** A broadcast channel. Any process can publish an event, and any process that subscribed will receive it. Like a pub/sub message bus.

**Key functions:**
- `broadcast(type, payload)` — send an event to all subscribers
- `subscribe()` — start receiving events

**Event types defined:**
- `:agent_started` — an agent booted up
- `:agent_stopped` — an agent shut down
- `:agent_status_changed` — an agent changed state (idle → running → done/failed)
- `:agent_work_assigned` — an agent received work to do

**Why it matters:** The dashboard (Phase 5), the DAG engine (Phase 3), and logging (Phase 10) all need to know what agents are doing. Instead of each agent directly notifying each observer, it just broadcasts — and anyone who cares can listen.

### 6. Agent Core (`lib/cortex/agent/`)

This is the **heart** of the system — the actual agent process.

#### Config (`config.ex`)
A validated data structure for agent settings:
- `name` — human-readable name (required)
- `role` — what the agent does (required)
- `model` — which Claude model to use (default: "sonnet")
- `max_turns` — max conversation turns (default: 200)
- `timeout_minutes` — how long before timing out (default: 30)

Validation happens upfront — bad configs are rejected before an agent ever starts.

#### State (`state.ex`)
The runtime data an agent carries while running:
- `id` — UUID, auto-generated
- `status` — one of `:idle`, `:running`, `:done`, `:failed`
- `metadata` — arbitrary key-value map for coordination
- `started_at` / `updated_at` — timestamps

#### Server (`server.ex`)
The GenServer — the actual running process. Think of it as an object that lives in its own thread with a message queue.

**Client API (how you talk to an agent from outside):**
- `get_state(id)` — check what an agent is doing
- `update_status(id, :running)` — change its status
- `update_metadata(id, key, value)` — store data on it
- `assign_work(id, work)` — give it something to do
- `stop(id)` — shut it down

Every state change broadcasts an event so observers know what's happening.

### 7. Tool Runtime (`lib/cortex/tool/`)

The system for running tools (shell commands, file operations, etc.) safely.

#### Behaviour (`behaviour.ex`)
A contract that any tool must implement — 4 functions:
- `name()` — tool identifier (e.g., "shell")
- `description()` — what it does
- `schema()` — JSON schema for its arguments
- `execute(args)` — do the thing, return `{:ok, result}` or `{:error, reason}`

#### Executor (`executor.ex`)
The **sandbox**. Runs tools in isolated processes so a crashing tool never takes down the agent that called it.

- Spawns each tool in a separate process (via Task.Supervisor)
- Enforces timeouts — if a tool takes too long, it's killed
- Catches crashes — returns a clean error instead of propagating the crash

This is critical for safety. Agents will eventually run arbitrary tools based on LLM output. A buggy tool must never crash the system.

#### Registry (`registry.ex`)
Maps tool names to their implementing modules. `register(MyTool)` → later `lookup("my_tool_name")` → get the module back.

#### Shell Tool (`builtin/shell.ex`)
The first built-in tool. Runs shell commands with safety guards:
- **Allowlist** — only permitted commands can run (ls, cat, echo, grep, etc.)
- **Argument list** — uses `System.cmd/3` which passes args directly to the OS, preventing shell injection attacks
- **Output truncation** — caps output at 64KB to prevent memory blowout

## How to Try It

```bash
cd cortex
mix deps.get
mix test              # 166 tests, 0 failures
iex -S mix            # interactive shell with everything running

# In iex:
Cortex.list_agents()  # => []
{:ok, pid} = Cortex.start_agent(%{name: "test", role: "worker"})
Cortex.list_agents()  # => [{"some-uuid", #PID<0.xxx.0>}]
```

## What's Next

Phase 2 (OTP Foundation QE) adds fault injection tests, supervisor recovery testing, and property-based tests to stress-test everything built here. Phase 3 (DAG Orchestration) builds the actual orchestration engine — YAML config parsing, DAG execution, and the `claude -p` spawner that makes agents do real work.
