# Next Session Plan: Gossip Mode + Polish

## Context for Claude

Cortex is at `/Users/michaelhabib/dev/teams-sbx/cortex/` — its own git repo. 13 commits, 623 tests, 0 failures. Elixir/OTP multi-agent orchestration system with two coordination modes:

1. **DAG mode** (working, e2e tested) — structured projects with tiers and dependencies
2. **Gossip mode** (code exists but not useful yet) — CRDTs, vector clocks, knowledge stores exist but don't actually spawn `claude -p` agents

The user has zero Elixir experience — Claude drives all technical decisions. User focuses on product/architecture direction.

Read `CLAUDE.md`, `PROJECT.md`, and `EXPLAIN.md` in the project root for full context. Read the phase SUMMARYs in `docs/*/SUMMARY.md` for plain-English explanations of what was built.

---

## Priority 1: Make Gossip Mode Actually Useful

### The Problem

The gossip code (`lib/cortex/gossip/`) has the data structures (vector clocks, knowledge stores, CRDT merge, topology) but it's completely disconnected from `claude -p`. The "runner" just shuffles entries between in-memory GenServers — no real AI agents are involved.

### The Vision

Gossip mode is for **open-ended exploration** — "research this market", "explore approaches to X", "investigate this codebase". Multiple agents each explore a different angle, periodically sharing findings. After N rounds, you get a merged knowledge base with everything they collectively discovered.

### Architecture Decision: No Teams, Just Peers

In gossip mode there are NO teams, NO tiers, NO dependencies. Every agent is a peer:

- Each agent gets a `claude -p` process + a KnowledgeStore
- Each agent has a **topic/angle** to explore (not a "role" in a hierarchy)
- Agents run simultaneously (all spawned at once)
- Periodically, the gossip coordinator triggers exchanges between pairs
- Each exchange: agent A's findings are written to agent B's inbox (and vice versa) via the InboxBridge
- After all rounds complete, knowledge is collected and deduplicated

### New Config Format: `gossip.yaml`

```yaml
name: "market-research-hyrox"
mode: gossip

defaults:
  model: sonnet
  max_turns: 20
  timeout_minutes: 15

gossip:
  rounds: 5                    # number of gossip exchange rounds
  topology: random             # full_mesh | ring | random
  exchange_interval_seconds: 60  # time between rounds (agents work between exchanges)

agents:
  - name: competitor-analyst
    topic: "competitor analysis"
    prompt: |
      Research the competitive landscape for Hyrox fitness software.
      Find existing apps, their features, pricing, user counts.
      Record each finding as a separate knowledge entry.

  - name: market-sizer
    topic: "market sizing"
    prompt: |
      Estimate the total addressable market for Hyrox software.
      Look at athlete counts, event growth, spending patterns.

  - name: product-ideator
    topic: "product ideas"
    prompt: |
      Brainstorm product ideas for the Hyrox ecosystem.
      Consider what athletes, coaches, and event organizers need.

  - name: data-scout
    topic: "data sources"
    prompt: |
      Find publicly available data sources for Hyrox results,
      athlete profiles, and training data. Check APIs, scrapers, datasets.

seed_knowledge:              # optional starting knowledge for all agents
  - topic: "context"
    content: "Hyrox is a fitness racing format with 8 running + 8 workout stations. 650K+ athletes globally, doubling YoY."
```

Key differences from orchestra.yaml:
- `mode: gossip` (vs implicit DAG mode)
- `agents` not `teams` — flat list, no hierarchy
- Each agent has a `topic` and `prompt` (not `role` + `tasks`)
- `gossip` config block for rounds/topology/timing
- `seed_knowledge` for priming all agents
- No `depends_on` — everyone is a peer

### Implementation Plan

1. **Gossip Config** (`lib/cortex/orchestration/config/gossip_schema.ex`)
   - New structs for the gossip.yaml format
   - Loader detects `mode: gossip` and parses accordingly

2. **Gossip Spawner** (`lib/cortex/gossip/spawner.ex`)
   - Spawns a `claude -p` process for each agent
   - Prompt includes: agent's topic, seed knowledge, instructions to record findings
   - Agent writes findings to `.cortex/knowledge/<agent>/findings.json`
   - Uses InboxBridge for receiving knowledge from other agents

3. **Gossip Coordinator** (`lib/cortex/gossip/coordinator.ex`)
   - GenServer managing the gossip session
   - Spawns all agents simultaneously
   - Runs N rounds of exchanges:
     - Select pairs based on topology
     - Read agent A's findings, write to agent B's inbox (and vice versa)
     - Wait for exchange_interval before next round
   - After all rounds: collect all findings, merge via KnowledgeStore, deduplicate

4. **Unified Runner** — update `Runner.run/2` to detect mode and dispatch:
   - `mode: gossip` → `Gossip.Coordinator.run/2`
   - Default (no mode) → existing DAG runner

5. **CLI** — `mix cortex.run gossip.yaml` should just work (mode detection)

6. **LiveView** — gossip mode page showing agents as a mesh (not DAG tiers), knowledge entries flowing between them

---

## Priority 2: Things We Should Fix

### Flaky Tests
There's an occasional flaky test (timing-dependent). Run `mix test --repeat-until-failure 5` to find and fix it.

### DB Files in Git
`cortex_dev.db`, `cortex_test.db` and WAL files got committed. Add to `.gitignore` and remove from tracking.

### Tailwind Warning
`tailwind version is not configured` warning on every command. Fix in config.

### Run Detail DAG Viz
The SVG DAG visualization on the Run Detail page hasn't been tested with a real run through the UI. Verify it actually renders and updates. May need fixes.

### Runner + Store Edge Cases
The runner-to-store integration is best-effort (try/rescue). Test what happens when:
- DB is locked (concurrent writes)
- Run is deleted mid-execution
- Very long result summaries

---

## Priority 3: Nice to Have

### Retry + Resume
Add `claude --resume <session_id>` support for failed teams. Session IDs are already captured.

### Mixed Mode
A project that uses DAG for the build phases but gossip for the research phase. The orchestra.yaml could define phases with different modes.

### GitHub Repo
Push cortex to GitHub as its own repo. Add as submodule to teams-sbx.

---

## Suggested Approach

Start a new session, paste this plan, and tell Claude:
```
Read /Users/michaelhabib/dev/teams-sbx/cortex/docs/next-session/PLAN.md —
this is the plan for this session. Start with Priority 1: make gossip mode
actually useful with real claude -p agents. Use /team-code-project or just
build directly, your call.
```
