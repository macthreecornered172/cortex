You are building the agent worker for Cortex — the "brain" process that runs
alongside the sidecar in a pod. Your job is to make the full external agent
pipeline work end-to-end.

## Architecture Decision

Cortex (Elixir) is the control plane — it stays. It handles orchestration,
DAG scheduling, run tracking, REST API, and the LiveView dashboard.

The Go data plane (sidecar + agent worker) handles execution — receiving
tasks from Cortex via gRPC and running Claude to process them.

The external agent infrastructure was built and tested but is currently gated.
Your first step is to ungate it, then finish the agent worker.

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

## What's Gated (needs ungating)

The external path was gated in commit 8ee64e9. To ungate:
1. `config/config.exs` — set `start_server: true` for GrpcEndpoint
2. `lib/cortex/orchestration/config/validator.ex` — remove the external block
   (make `validate_external_blocked` a no-op again)
3. `lib/cortex/application.ex` — add ExternalSupervisor back to the supervision tree
4. `lib/cortex/orchestration/runner/executor.ex` — restore the Provider.External
   dispatch path (dispatch_to_provider for ProviderExternal, run_via_external_agent,
   ensure_external_agent)
5. `test/test_helper.exs` — remove :external from exclude list
6. Update tests: validator tests back to "accepted", loader test back to "parses"
7. Run `mix test` — all 1382+ tests should pass

Reference the commit before gating (5f4a86b) for what to restore.

## What to Build

### Phase 1: Ungate + Agent Worker V1 (claude -p)

1. Ungate the external path (see above)
2. Build and test sidecar/cmd/agent-worker (skeleton exists)
3. Add make targets: `make worker-build` → builds bin/agent-worker
4. Verify the full flow works locally:
   - Terminal 1: CORTEX_GATEWAY_TOKEN=my-token mix phx.server
   - Terminal 2: sidecar with CORTEX_AGENT_NAME=worker
   - Terminal 3: agent-worker with SIDECAR_URL=http://localhost:9091
   - Terminal 4: POST /api/runs with external-simple.yaml config
   - Task flows through, claude -p runs, result comes back, run completes
5. Update the e2e test to use the real agent-worker instead of the fake poller
6. Update make e2e to build and use the agent-worker
7. Run `mix test` and `make e2e` — both must pass

### Phase 2: Extended Prompt with Peer Awareness

1. Modify the executor's prompt builder to include:
   - Active peer roster (query Gateway.Registry for all agents in this run)
   - Sidecar API docs (how to message peers)
2. Add peer info to the TaskRequest context map
3. Verify with external-dag.yaml — each agent's prompt should list its peers

### Phase 3: Agent Worker V2 — Claude API with tools

1. Replace claude -p with direct Claude Messages API calls (Anthropic Go SDK)
2. Implement agentic loop (tool calls → execute → feed back → repeat)
3. Add peer communication tools: send_message, ask_agent, check_inbox, broadcast
4. Worker translates tool calls to sidecar HTTP API calls
5. Token and cost tracking in the result

### Phase 4: Postgres + Production Readiness

1. Swap SQLite → Postgres (Ecto adapter change)
2. Docker Compose for local dev (Cortex + Postgres)
3. Dockerfile for Cortex (Elixir release)
4. Dockerfile for sidecar + agent-worker

## Constraints
- Go code lives in sidecar/ directory
- Elixir is the control plane — keep it clean and focused
- Don't break existing tests (mix test must still pass)
- Don't break make e2e
- The sidecar binary should NOT change — the worker is separate
- Test each phase before moving to the next
- Verify before committing — no WIP commits
