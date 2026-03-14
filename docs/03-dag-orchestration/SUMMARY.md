# Phase 3: DAG Orchestration — Summary

> 350 tests, 0 failures. This is the big one — Cortex can now execute multi-team projects end-to-end.

## What Was Built

Phase 3 adds the orchestration engine — the brain that takes a project definition (YAML), figures out what order to run teams in, spawns `claude -p` processes for each team, and collects results. After this phase, you can define a project in YAML and Cortex will execute it.

### 1. Config Parser (`lib/cortex/orchestration/config/`)

**What it does:** Reads an `orchestra.yaml` file and converts it into validated Elixir data structures.

**The YAML format:**
```yaml
name: "my-project"
defaults:
  model: sonnet
  max_turns: 200
  permission_mode: acceptEdits
  timeout_minutes: 30
teams:
  - name: backend
    lead:
      role: "Backend Lead"
      model: opus          # override model for this team
    context: |
      Tech stack: Go, PostgreSQL...
    members:
      - role: "API Engineer"
        focus: "REST endpoints"
    tasks:
      - summary: "Build REST API"
        details: "Create endpoints for..."
        deliverables: ["src/api/"]
        verify: "go build ./..."
    depends_on: []          # no dependencies — runs first
  - name: frontend
    depends_on: ["backend"]  # waits for backend to finish
    ...
```

**Validation catches:**
- Missing names, empty teams, duplicate team names
- Missing lead roles, missing task summaries
- Dangling dependency references (pointing to non-existent teams)
- Dependency cycles (A depends on B, B depends on A)
- Warnings for large teams (>5 members) or tasks without verify commands

### 2. DAG Engine (`lib/cortex/orchestration/dag.ex`)

**What it does:** Takes the list of teams and their dependencies, figures out which teams can run in parallel and which must wait.

**How it works — Kahn's Algorithm:**
1. Count how many dependencies each team has (its "in-degree")
2. Teams with zero dependencies go in Tier 1 (they can all run in parallel)
3. Remove those teams from the graph, reducing their dependents' in-degrees
4. Repeat — teams that now have zero dependencies go in the next tier
5. If any teams are left over, there's a cycle (error)

**Example:**
```
Input: backend (no deps), frontend (needs backend), devops (needs backend), integration (needs frontend + devops)
Output: [["backend"], ["devops", "frontend"], ["integration"]]
         Tier 1          Tier 2 (parallel)      Tier 3
```

This is the same algorithm used in build systems (Make, Bazel), package managers (npm), and CI/CD pipelines.

### 3. Workspace (`lib/cortex/orchestration/workspace.ex`)

**What it does:** Manages the on-disk state for an orchestration run. Creates a `.cortex/` directory with:

```
.cortex/
├── state.json        — per-team status, results, costs
├── registry.json     — run tracking (session IDs, timestamps)
├── results/
│   └── backend.json  — full result for each team
└── logs/
    └── backend.log   — raw claude -p output
```

**Key design:** All file writes are **atomic** — write to a `.tmp` file first, then rename. This prevents corrupted state if the process crashes mid-write.

### 4. Spawner (`lib/cortex/orchestration/spawner.ex`)

**What it does:** Runs `claude -p` as an external process and captures the result.

**How it works:**
1. Opens an Erlang Port to `claude -p <prompt> --output-format stream-json`
2. Reads NDJSON (newline-delimited JSON) output line by line
3. Looks for the final `{"type": "result"}` line with status, cost, duration
4. Optionally writes all output to a log file
5. Enforces a timeout — kills the process if it takes too long

**The result struct (`TeamResult`):**
- `team` — which team this was
- `status` — `:success`, `:error`, or `:timeout`
- `result` — the text output from Claude
- `cost_usd` — how much the API call cost
- `duration_ms` — how long it took
- `session_id` — Claude's session ID

**Testing without Claude:** Tests use mock bash scripts that echo pre-built NDJSON instead of actually running `claude`. This makes tests fast, deterministic, and free.

### 5. Prompt Injection (`lib/cortex/orchestration/injection.ex`)

**What it does:** Builds the prompt that gets sent to each team's `claude -p` session.

**Two prompt types:**
- **Solo agent** (no team members) — gets role, context, tasks, upstream results, instructions
- **Team lead** (has members) — same plus a "Your Team" section listing members and delegation instructions

**Context injection:** When team B depends on team A, team B's prompt includes a summary of what team A accomplished. This is how knowledge flows forward through the DAG.

### 6. Orchestration Runner (`lib/cortex/orchestration/runner.ex`)

**What it does:** The main engine that ties everything together.

**The `run/2` flow:**
1. Load + validate the YAML config
2. Create the workspace (`.cortex/` directory)
3. Build the DAG tiers
4. For each tier:
   - Spawn all teams in the tier **in parallel**
   - Each team: build prompt → run `claude -p` → capture result
   - Update workspace state with results
   - If any team failed and `continue_on_error` is false → stop
5. Print summary (costs, durations, statuses)

**Options:**
- `dry_run: true` — shows the execution plan without actually running anything
- `continue_on_error: true` — keep going even if a team fails
- `command: "path/to/script"` — override the spawner command (for testing)

### 7. Summary Formatter (`lib/cortex/orchestration/summary.ex`)

Produces a nice table:
```
═══════════════════════════════════════
  Cortex: my-project — Complete
═══════════════════════════════════════
  Team        │ Status  │ Cost   │ Duration
  ────────────┼─────────┼────────┼──────────
  backend     │ done    │ $1.20  │ 4m 12s
  frontend    │ done    │ $0.85  │ 3m 05s
  ────────────┼─────────┼────────┼──────────
  Total       │         │ $2.05  │ 7m 17s
```

## How to Try It

```bash
cd cortex

# Create a test orchestra.yaml (simplified example)
cat > /tmp/test-orchestra.yaml << 'YAML'
name: "test-project"
defaults:
  model: sonnet
  max_turns: 10
teams:
  - name: hello
    lead:
      role: "Greeter"
    tasks:
      - summary: "Say hello"
        verify: "echo done"
    depends_on: []
YAML

# Dry run (shows plan without executing)
# In iex:
iex -S mix
Cortex.Orchestration.Runner.run("/tmp/test-orchestra.yaml", dry_run: true)
```

## What's Next

Phase 4 (DAG Orchestration QE) will stress-test the runner with complex DAGs, failure scenarios, and concurrent tier execution. Phase 5 adds the LiveView dashboard for real-time visibility into running orchestrations.
