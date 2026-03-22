You are building SpawnBackend.Local support for `provider: external` in Cortex.

Right now, running an external agent config requires manually starting 3 processes in 3 terminals (Cortex, sidecar, agent-worker). Your job is to make Cortex auto-spawn the sidecar + worker locally so users just paste YAML and click launch.

## Context

Read these first:
- docs/agent-worker/phase-2/kickoff.yaml (task breakdown)
- docs/compute-spawning/agent-worker-design.md (architecture)
- lib/cortex/spawn_backend/local.ex (current SpawnBackend.Local — handles provider: cli)
- lib/cortex/spawn_backend.ex (SpawnBackend behaviour)
- lib/cortex/orchestration/runner/executor.ex (where dispatch happens)
- lib/cortex/provider/resolver.ex (how provider + backend are resolved)
- sidecar/cmd/agent-worker/main.go (worker binary — polls sidecar, runs claude)
- sidecar/cmd/cortex-sidecar/ (sidecar binary — gRPC + HTTP API)
- examples/external-simple.yaml (single external agent config)

## What to Build

When a config says `provider: external` + `backend: local` (or just `provider: external` since `local` is the default backend), Cortex should:

1. **Pick a free port** for the sidecar (use `:gen_tcp.listen(0, ...)` or similar)
2. **Fork the sidecar binary** as an Erlang Port with env vars:
   - `CORTEX_GATEWAY_URL=localhost:4001`
   - `CORTEX_AGENT_NAME=<team_name>`
   - `CORTEX_AUTH_TOKEN=<gateway_token>`
   - `CORTEX_SIDECAR_PORT=<free_port>`
3. **Wait for registration** — poll Gateway.Registry until the agent appears (with timeout)
4. **Fork the agent-worker binary** as an Erlang Port with env vars:
   - `SIDECAR_URL=http://localhost:<free_port>`
5. **Dispatch the task** through Provider.External as normal
6. **Clean up** — kill both processes when the team run finishes (success or failure)

### Binary Discovery

The sidecar and worker binaries need to be locatable. Use a config-based approach:

```elixir
# config/config.exs
config :cortex, Cortex.SpawnBackend.Local,
  sidecar_bin: "sidecar/bin/cortex-sidecar",
  worker_bin: "sidecar/bin/agent-worker"
```

Fall back to env vars `CORTEX_SIDECAR_BIN` / `CORTEX_WORKER_BIN` if set.

### Gateway Token

Read the gateway auth token from `Application.get_env(:cortex, :gateway_token)` or `System.get_env("CORTEX_GATEWAY_TOKEN")`. The spawned sidecar needs this to authenticate with the gRPC server.

### Where to Hook In

Look at how `dispatch_to_provider` works in executor.ex. Currently for `ProviderExternal`, it calls `run_via_external_agent` which does `ensure_external_agent` → `ExternalSupervisor.start_agent`.

For `backend: local`, the flow should be:
1. Before dispatching, check if a sidecar + worker need to be spawned
2. Spawn them via SpawnBackend.Local
3. Wait for Gateway.Registry registration
4. Then dispatch via Provider.External as normal
5. After the team run completes, clean up the spawned processes

### Multi-Agent DAGs

For configs like `external-dag.yaml` with 3 external agents, each team gets its own sidecar + worker pair on different ports. The executor already runs teams in parallel within a tier, so each team's spawn + dispatch happens independently.

## Constraints

- Don't break existing `provider: cli` + `backend: local` path — that's the default
- Don't break `provider: external` with manually-started sidecars — that should still work (if a sidecar is already registered, skip spawning)
- All existing tests must pass (`mix test`)
- Add tests for the new spawn path
- Binary paths should be configurable, not hardcoded
- Clean up spawned processes even on crashes/timeouts

## Verification

1. `mix test` — all existing tests pass
2. `mix compile --warnings-as-errors` — clean
3. Manual test: start `mix phx.server`, paste `external-simple.yaml` in UI, run completes without manual sidecar/worker setup
4. Manual test: paste `external-dag.yaml`, all 3 agents spawn and complete
5. Manual test: start sidecar manually, run external config — Cortex skips spawning, uses existing sidecar
