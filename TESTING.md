# Testing

Cortex has three test layers — unit, integration, and e2e — across Elixir and Go. This doc describes every test target and when to use each.

## Quick Reference

```bash
# Verify everything locally (no API key, no Docker)
make check                  # format + compile warnings + credo + unit tests
make sidecar-check          # Go: lint + test + build

# Run with integration tests
mix test --include integration

# Full e2e with mock agents (starts real server)
make e2e-gate               # Gate flow: approve, reject, pivot notes

# Full e2e with real Claude (needs ANTHROPIC_API_KEY)
make e2e-gate-claude        # Gate flow with sense assertions
make e2e-cli                # CLI provider single-team
```

## Test Layers

| Layer | Real Claude? | Real infra? | Speed | What it proves |
|-------|-------------|-------------|-------|----------------|
| Unit | No | No | Fast (~30s) | Logic correctness with mocks |
| Integration | No | DB + mock scripts | Medium (~5s) | Plumbing, DB persistence, state transitions |
| E2E (mock) | No | Live server + mock agent | Slow (~10-50s) | Full API-driven lifecycle |
| E2E (Claude) | Yes | Live server + real Claude | Slowest (~60-300s) | Actual agent behavior, semantic verification |

## Elixir Tests

### Tags

Tests are excluded by default via `test/test_helper.exs`:

```elixir
ExUnit.start(exclude: [:pending, :integration, :e2e])
```

| Tag | Purpose | How to run |
|-----|---------|-----------|
| (none) | Unit tests — always run | `mix test` |
| `:integration` | DB sandbox + mock scripts | `mix test --include integration` |
| `:e2e` | Elixir-side e2e (needs sidecar binary) | `mix test --include e2e` |
| `:pending` | Not yet runnable (missing deps) | `mix test --include pending` |

### Make Targets

| Target | What it runs |
|--------|-------------|
| `make test` | `mix test` — unit tests only |
| `make check` | Format + compile warnings + credo strict + unit tests |
| `make lint` | Credo strict + Dialyzer |
| `make fmt` | Auto-format all files |
| `make test-integration` | `mix test --only integration` |
| `make test-elixir-all` | `mix test --include integration --include e2e` |
| `make e2e-elixir` | `mix test test/e2e/ --include e2e` |

### Test Organization

```
test/
  cortex/
    agent/              # Agent GenServer, config, registry (8 files)
    gateway/            # gRPC, protocol, auth, health (9 files)
    gossip/             # Protocol, topology, vector clock (8 files)
    mesh/               # Config, prompt, members, relay (7 files)
    messaging/          # Bus, router, inbox, mailbox (6 files)
    orchestration/      # DAG, runner, workspace, gates (14 files)
    provider/           # CLI, resolver, external (6 files)
    spawn_backend/      # Local, Docker, K8s, external (4 files)
    store/              # Store operations (2 files)
    tool/               # Behavior, executor, registry (5 files)
  cortex_web/
    components/         # LiveView components (9 files)
    live/               # Page-level LiveViews (4 files)
  e2e/                  # Elixir e2e: ExternalAgent pipeline (1 file)
  mix/tasks/            # Mix task tests (2 files)
  support/              # Helpers: mocks, sense, eventually, conn_case
```

### Key Test Files

| File | Tests | What it covers |
|------|-------|----------------|
| `orchestration/runner_test.exs` | 9 | Single/multi-team runs, errors, events |
| `orchestration/orchestration_qe_test.exs` | 6 | 12-team stress, failure cascades, parallelism |
| `orchestration/gate_test.exs` | 10 | Gate lifecycle: pause, approve, reject, cancel, notes injection |
| `orchestration/output_integration_test.exs` | 1 | Store + API output retrieval |
| `provider/cli_test.exs` | 12 | NDJSON parsing, timeouts, logging |
| `e2e/external_agent_e2e_test.exs` | 1 | Full sidecar-gRPC-gateway pipeline |

### Test Helpers (`test/support/`)

| File | Purpose |
|------|---------|
| `sense.ex` | Semantic assertions: `assert_sense/2`, `refute_sense/2` |
| `eventually.ex` | Polling: `assert_eventually/3` for timing-sensitive tests |
| `mocks.ex` | Mox definitions: `MockProvider`, `MockSpawnBackend` |
| `test_tools.ex` | Mock tools: Echo, Slow, Crasher, Killer, BadReturn |
| `conn_case.ex` | Phoenix HTTP + LiveView test setup with DB sandbox |

## Go Tests

### Sidecar Unit Tests

```bash
make sidecar-test           # go test ./... -race -v
make sidecar-lint           # go vet + golangci-lint
make sidecar-check          # lint + test + build
```

Packages tested: `internal/`, `internal/api/`, `internal/config/`, `internal/gateway/`, `internal/state/`

### E2E Tests (`e2e/`)

All Go e2e tests start a real Cortex server (`mix phx.server`), drive behavior via REST API calls, and poll for results.

| Test | Make target | Infra needed | API key? |
|------|-----------|-------------|----------|
| `TestGateApproveAndContinue` | `make e2e-gate` | None (mock agent) | No |
| `TestGateReject` | `make e2e-gate` | None (mock agent) | No |
| `TestGateClaudeApproveWithPivot` | `make e2e-gate-claude` | None | Yes |
| `TestDockerDAGSimple` | `make e2e-docker-simple` | Docker | No |
| `TestDockerDAGMultiTeam` | `make e2e-docker-multi` | Docker | No |
| `TestDockerDAGSimple` (claude) | `make e2e-docker-simple-claude` | Docker | Yes |
| `TestDockerDAGMultiTeam` (claude) | `make e2e-docker-multi-claude` | Docker | Yes |
| `TestCLIDAGSimple` | `make e2e-cli` | None | Yes |
| `TestCLIDAGMultiTeam` | `make e2e-cli-multi` | None | Yes |
| `TestK8sDAGSimple` | `make e2e-k8s-simple` | kind cluster | No |
| `TestK8sDAGMultiTeam` | `make e2e-k8s-multi` | kind cluster | No |
| `TestExternalAgentE2E` | `make e2e-local` | Sidecar binary | No |
| `TestDocker*` (8 tests) | `make docker-integration` | Docker | No |

### E2E with `sense` (LLM-powered assertions)

The `TestGateClaudeApproveWithPivot` test uses [`github.com/itsHabib/sense`](https://github.com/itsHabib/sense) for semantic verification. After a human approves a gate with "pivot to REST", `sense.Assert` evaluates whether the downstream agent's output actually describes a REST API instead of GraphQL:

```go
sense.Assert(t, resultSummary).
    Context("agent was told to pivot from GraphQL to REST via gate notes").
    Expect("describes a REST API implementation, not GraphQL").
    Expect("references HTTP methods, resource URLs, or JSON endpoints").
    Run()
```

Requires `ANTHROPIC_API_KEY` — skipped automatically if not set.

### K8s Infrastructure Targets

| Target | Purpose |
|--------|---------|
| `make e2e-k8s-setup` | Create kind cluster, load images, deploy Cortex |
| `make e2e-k8s-setup-claude` | Same + Claude CLI in container |
| `make e2e-k8s-observability` | Deploy Loki + Promtail + Prometheus + Grafana |
| `make e2e-k8s-teardown` | Delete kind cluster |

### Docker Build Targets

| Target | Purpose |
|--------|---------|
| `make sidecar-build` | Build Go sidecar binary |
| `make worker-build` | Build Go agent-worker binary |
| `make docker-combo` | Build cortex-agent-worker image (mock mode) |
| `make docker-combo-claude` | Build cortex-agent-worker image (with Claude CLI) |

## Before You Commit

Run these in order:

```bash
mix format
mix compile --warnings-as-errors
mix credo --strict
mix test
```

Or just: `make check`

For Go changes: `make sidecar-check`

## Important Notes

- Do NOT pipe `mix test` to `tail`, `grep`, or any other command — it hangs forever. Run it bare.
- Go e2e tests kill stale BEAM processes on startup/teardown (`TestMain`). Don't run them while a dev server is up.
- The `CLAUDE_COMMAND` env var overrides the agent command for CLI provider runs (used by mock e2e tests).
- `SENSE_SKIP=1` disables all sense LLM calls (for offline dev).
