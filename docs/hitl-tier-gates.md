# Human-in-the-Loop: Tier Gates

## Overview

Add approval gates at DAG tier boundaries so a human can review results
before the next tier starts. The run pauses after a gated tier completes,
waits for explicit approval, then continues.

## Design Decisions

### Separate field, not a status override

Gate state is orthogonal to execution status. A team can be `completed` AND
gated. We don't overload `status` (which tracks execution: pending, running,
completed, failed) with an approval concern.

Run status now includes `"gated"` as a first-class value alongside
`pending`, `running`, `completed`, `failed`, and `cancelled`.

A tier transition can be:

| Previous tier status | Gate config | Behavior                              |
|----------------------|-------------|---------------------------------------|
| `completed`          | not gated   | Proceed to next tier immediately      |
| `completed`          | gated       | Run status → `"gated"`, halt, wait    |
| (gated)              | approved    | Run status → `"running"`, continue    |
| (gated)              | rejected    | Run status → `"cancelled"`, stop      |

### No GenServer — stateless DB-driven resume

The executor halts the `reduce_while` loop when it hits a gated boundary.
The process exits. State is persisted to DB. No process sits idle waiting.

To resume: human approves (LiveView, API, CLI), which calls
`Runner.continue_run(run_id)`. This already rebuilds the DAG from DB,
skips completed tiers, and executes the rest. It's the same path used for
crash recovery — we're reusing it for intentional pauses.

**Why not a GenServer?**
- GenServers die on deploy/restart — you'd need DB persistence anyway
- A waiting GenServer adds in-memory state that can diverge from DB
- The stateless approach is simpler and already proven in the codebase
- If the approve call fails, the gate state is still in DB — user retries

**Guarding against double-clicks:** `continue_run` checks if the run is
already running (via `runner_registry` / `coordinator_alive?`) and bails
with `{:error, :already_running}`.

## Where the gate goes

In `executor.ex`, `run_tiers/6` uses `Enum.reduce_while` to walk tiers:

```
tiers
|> Enum.with_index()
|> Enum.reduce_while({:ok, :complete}, fn {team_names, tier_index}, acc ->
     # >>> gate check goes here, before execute_tier <<<
     execute_tier(...)
   end)
```

Before calling `execute_tier` for tier N, check if there's a gate between
tier N-1 and tier N. If so, persist `gate: "pending"` on the run, broadcast
`:gate_pending`, and `{:halt, {:gated, tier_index}}`.

Finalization sees the `:gated` result and marks the run appropriately
instead of marking it `"completed"`.

### Gate notes → agent prompt injection

When the executor is about to run a tier, it queries all approved
`gate_decisions` for the run that have non-nil `notes`. These are injected
into each agent's prompt as a `## Human Review Notes` section, ordered by
tier:

```
## Human Review Notes

After tier 0 (approved by alice):
  Focus the API layer on read endpoints only — writes are out of scope.

After tier 2 (approved by alice):
  Cache implementation looks good. Skip the Redis fallback for now.
```

This block is appended to the agent's system prompt (or prepended to the
user prompt — whichever the prompt builder supports). Agents in tier 1 see
notes from tier 0; agents in tier 3 see notes from tiers 0 and 2; etc.

The injection happens in `execute_tier` (or the prompt builder it calls),
not in the gate logic itself. This keeps gate logic focused on
pause/resume and prompt logic focused on context assembly.

## Config

Gates are tier-level only — they fire after all teams in a tier complete.

```yaml
gates:
  after_tier: [0, 2]   # pause after tier 0 and tier 2 complete
```

Or gate after every tier:

```yaml
gates:
  every_tier: true
```

Start with `after_tier` as the default config shape.

## Schema Changes

### Run-level gate tracking

Add to `runs` table:

```elixir
alter table(:runs) do
  add :gated_at_tier, :integer       # which tier boundary we're currently paused at (nil if not gated)
end
```

### Gate decisions table

A separate table records every gate decision for audit trail and UI display.
Each row is one gate event (pending → approved/rejected).

```elixir
create table(:gate_decisions) do
  add :run_id, references(:runs, on_delete: :delete_all), null: false
  add :tier, :integer, null: false
  add :decision, :string, null: false   # "pending" | "approved" | "rejected"
  add :decided_by, :string              # who approved/rejected (nil while pending)
  add :notes, :text                     # optional human notes explaining the decision
  timestamps()
end

create index(:gate_decisions, [:run_id, :tier])
```

Flow: when a gate fires, insert a row with `decision: "pending"`. On
approve/reject, update that row with the decision, `decided_by`, and
optional `notes`. The full history of gates is always queryable.

## Implementation Steps

### 1. Config + validation
- Add `gates` key to `Config` schema (`config/schema.ex`)
- Validate in `config/validator.ex`
- Parse `after_tier` list into a MapSet for O(1) lookup

### 2. DB migration + schema
- Add gate fields to `runs` table
- Update `Run` Ecto schema with gate fields

### 3. Executor gate logic
- In `run_tiers`, before `execute_tier`: check if `tier_index` is gated
- If gated: set `run.status = "gated"`, set `gated_at_tier`, insert a
  `gate_decisions` row with `decision: "pending"`, broadcast `:gate_pending`,
  halt the reduce_while loop
- Finalization: detect `:gated` result, leave run in `"gated"` status
  (do not overwrite to `"completed"`)
- In `execute_tier` (or prompt builder): query approved gate decisions with
  notes for this run, format as `## Human Review Notes`, inject into each
  agent's prompt before dispatch

### 4. approve_gate / continue_run

`approve_gate(run_id, opts)` is the only entry point for resuming a gated run:

1. Load run — if `status != "gated"`, return `{:ok, :noop}` (idempotent)
2. Update the pending `gate_decisions` row: set decision to `"approved"`,
   `decided_by`, and optional `notes` from opts
3. Clear `gated_at_tier`, set `run.status = "running"`
4. Call `continue_run(run_id)` — which skips completed tiers as usual
5. If `continue_run` returns `{:error, :already_running}`, that's fine —
   the gate was already approved and the run is in progress. Return `{:ok, :already_running}`.

This makes the whole flow idempotent: multiple approve clicks are harmless.

### 5. reject_gate / cancel_run

`reject_gate(run_id, opts)` stops a gated run permanently:

1. Load run — if `status != "gated"`, return `{:ok, :noop}` (idempotent)
2. Update the pending `gate_decisions` row: set decision to `"rejected"`,
   `decided_by`, and optional `notes`
3. Set `run.status = "cancelled"`, clear `gated_at_tier`
4. Broadcast `:run_cancelled`

`cancel_run(run_id)` can be called on any active run (running or gated):

1. If running: look up the coordinator/runner process via `runner_registry`,
   send a shutdown signal, wait for graceful termination. Kill any child
   agent processes (sidecar, ExternalAgent GenServers) associated with the
   run. Set `run.status = "cancelled"`.
2. If gated: equivalent to `reject_gate` without requiring notes.
3. If already completed/failed/cancelled: `{:ok, :noop}`

Process cleanup order:
- Stop the coordinator (which stops dispatching new work)
- Terminate any in-flight agent processes for the run
- Mark incomplete `team_runs` as `"cancelled"`
- Persist final run status

### 6. LiveView UI
- Show gate status on run detail (banner or inline in tier visualization)
- "Approve & Continue" button with optional notes textarea
- "Reject" / "Cancel Run" button
- Disable buttons while run is resuming (broadcast handles this)
- Show gate decision history: tier, decision, who, when, notes
- Run status badge reflects `"gated"` and `"cancelled"` states

### 7. PubSub events
- `:gate_pending` — run hit a gate, waiting for approval
- `:gate_approved` — human approved, run resuming
- `:run_cancelled` — run was cancelled (from gate rejection or explicit cancel)
- LiveView subscribes and updates in real-time

### 8. Mix task / API
- `mix cortex.approve <run_id> [--notes "..."]` — approve a gated run
- `mix cortex.reject <run_id> [--notes "..."]` — reject a gated run
- `mix cortex.cancel <run_id>` — cancel any active run (running or gated)
- Optional: REST endpoints for programmatic use

## Files to Modify

| File | Change |
|------|--------|
| `orchestration/config/schema.ex` | Add `gates` to config struct |
| `orchestration/config/validator.ex` | Validate gate declarations |
| `orchestration/runner/executor.ex` | Gate check in `run_tiers` reduce_while |
| `orchestration/runner.ex` | `approve_gate/2`, `reject_gate/2`, `cancel_run/1` public API |
| `store/schemas/run.ex` | Add `gated_at_tier` field, `"gated"`/`"cancelled"` status |
| `store/schemas/gate_decision.ex` | New schema for gate decisions |
| `priv/repo/migrations/` | Add gate columns + gate_decisions table |
| `orchestration/runner/executor.ex` or prompt builder | Inject gate notes into agent prompts |
| `cortex_web/live/run_detail_live.ex` | Approve/reject UI, gate history, cancel button |

## Not in scope (for now)
- Per-team gates (gate at team level rather than tier level)
- Rollback (undo completed tier work on rejection)
- Timeout-based auto-approve
- Gate conditions (auto-approve if tests pass, etc.)
- Mesh/gossip mode gates (different execution model)
