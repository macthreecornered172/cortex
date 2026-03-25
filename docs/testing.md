# Testing Levels

## Definitions

| Level | Real Claude? | Real infra? | What it proves |
|-------|-------------|-------------|----------------|
| **Unit** | No | No | Logic correctness with mocks |
| **Integration** | No | Yes (Docker, gRPC, processes) | Infrastructure works, plumbing connects |
| **E2E** | Mock or real | Yes | Full pipeline end-to-end |

## Make Targets

### Unit tests

```bash
make test                   # All Elixir unit tests (mocked, no external deps)
make sidecar-test           # Go sidecar unit tests
make test-elixir-all        # All Elixir tests including integration + e2e tags
```

### Integration tests (no Claude, no API key)

```bash
make docker-integration     # Docker API lifecycle: container CRUD, networks, labels, logs
make e2e-shell              # Sidecar <-> gRPC <-> Gateway protocol
make e2e-elixir             # Elixir-side ExternalAgent pipeline (mock sidecar)
```

### E2E tests

```bash
make e2e-local              # Local processes: Cortex + sidecar + worker (mock agent)
make e2e-docker             # Docker containers: mock agent (no API key needed)
make e2e-docker-claude      # Docker containers: real Claude CLI (needs API key + claude image)
```

### CI / lint

```bash
make check                  # Format + compile warnings + credo + unit tests
make sidecar-check          # Go lint + test + build
```

### Docker image builds

```bash
make docker-combo           # Build cortex-agent-worker:latest (mock mode, no Claude CLI)
make docker-combo-claude    # Build cortex-agent-worker:latest with Claude CLI installed
```

## What each e2e target exercises

### `make e2e-local` (local processes)

```
Cortex (mix phx.server)
  -> Executor sees provider: external, backend: local
  -> ExternalSpawner forks sidecar + worker as OS processes
  -> Sidecar registers with Gateway via gRPC
  -> Worker polls sidecar, gets task, runs mock or claude -p
  -> Result flows: worker -> sidecar -> Gateway -> Cortex
  -> Run completes
```

### `make e2e-docker` / `make e2e-docker-claude` (Docker containers)

```
Cortex (mix phx.server)
  -> Executor sees provider: external, backend: docker
  -> SpawnBackend.Docker creates network + sidecar + worker containers
  -> Sidecar registers with Gateway via gRPC
  -> Worker polls sidecar, gets task, runs mock or claude -p (inside container)
  -> Result flows: worker -> sidecar -> Gateway -> Cortex
  -> Executor calls stop -> containers + network removed
  -> Run completes
```

## Known gaps

- **K8s e2e**: No e2e test yet for `backend: k8s`. Needs `kind` or `minikube`.
- **Multi-team Docker e2e with real Claude**: `TestDockerDAGMultiTeam` passes with mock
  agent but hasn't been validated with real Claude in containers yet.
