You are building the agent worker for Cortex — the "brain" process that runs
alongside the sidecar in a pod. Your job is to make the full external agent
pipeline work end-to-end.

## Context

Read these first:
- docs/compute-spawning/agent-worker-design.md (full design doc)
- docs/compute-spawning/PROJECT.md (project overview)
- sidecar/cmd/agent-worker/main.go (V1 skeleton — polls sidecar, runs claude -p)
- sidecar/internal/api/status.go (GET /task and POST /task/result handlers)
- sidecar/internal/api/router.go (full sidecar HTTP API)
- lib/cortex/orchestration/runner/executor.ex (how prompts are built and dispatched)
- lib/cortex/provider/external/task_push.ex (how tasks are pushed to sidecars)
- examples/external-simple.yaml (single external agent example)
- examples/external-dag.yaml (multi-agent DAG example)
- e2e/external_agent_test.go (Go e2e test — reference for how the full pipeline works)

## What to Build

### Phase 1: Agent Worker V1 — make it work with claude -p

1. Build and test sidecar/cmd/agent-worker (skeleton exists)
2. Add a make target: `make worker-build` → builds bin/agent-worker
3. Verify the full flow works locally:
   - Terminal 1: CORTEX_GATEWAY_TOKEN=my-token mix phx.server
   - Terminal 2: sidecar with CORTEX_AGENT_NAME=worker
   - Terminal 3: agent-worker with SIDECAR_URL=http://localhost:9091
   - Terminal 4: POST /api/runs with external-simple.yaml config
   - Task flows through, claude -p runs, result comes back, run completes
4. Update the e2e test to use the real agent-worker instead of the fake poller
5. Update make e2e to build and use the agent-worker

### Phase 2: Extended Prompt with Peer Awareness

1. Modify the executor's prompt builder to include:
   - Active peer roster (query Gateway.Registry for all agents in this run)
   - Sidecar API docs (how to message peers)
2. Add peer info to the TaskRequest context map
3. Verify with external-dag.yaml — each agent's prompt should list its peers

### Phase 3: Agent Worker V2 — Claude API with tools

1. Replace claude -p with direct Claude Messages API calls
2. Implement agentic loop (tool calls → execute → feed back → repeat)
3. Add peer communication tools: send_message, ask_agent, check_inbox, broadcast
4. Worker translates tool calls to sidecar HTTP API calls
5. Token and cost tracking in the result

## Constraints
- Go code lives in sidecar/ directory
- Elixir changes are minimal — just prompt builder extensions
- Don't break existing tests (mix test must still pass)
- Don't break make e2e
- The sidecar binary should NOT change — the worker is separate
- Test each phase before moving to the next
