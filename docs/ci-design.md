# CI / GitHub Actions Design

## Goal

Automate the test layers described in TESTING.md so every PR gets fast feedback and broken code never lands on main.

## Workflow Tiers

### Tier 1 — PR Gate (every push / PR, blocks merge)

**Trigger:** `pull_request` to `main`, `push` to `main`
**Time budget:** ~5 min (all jobs parallel)
**Secrets needed:** none
**Branch protection:** required to pass before merge

All four jobs run in parallel:

| Job | Steps | Maps to |
|-----|-------|---------|
| **elixir-check** | Install Elixir 1.17 + deps → `make check` | format, compile warnings, credo strict, unit tests |
| **go-check** | Install Go 1.25.1 → `make sidecar-check` | vet, golangci-lint, unit tests, build |
| **elixir-integration** | `make test-integration` | DB sandbox + mock script integration tests |
| **e2e-gate** | Start Phoenix server → `make e2e-gate` | Gate approve/reject flow with mock agent |

Everything that can run without secrets or heavy infra runs on every PR. Broken code never lands on main.

Both Elixir jobs use SQLite (already in deps), so no database service needed.
The `e2e-gate` job needs Docker — GitHub-hosted `ubuntu-latest` runners have it pre-installed.

The `e2e-gate` job needs to:
1. Install Elixir + Go, fetch deps, create + migrate DB
2. Start `mix phx.server` in background
3. Wait for health check (`/health/ready`)
4. Run Go test

Caching:
- Elixir: `_build/` + `deps/` keyed on `mix.lock`
- Go: module cache keyed on `go.sum`
- Dialyzer PLT: keyed on Elixir version + `mix.lock` (optional, see Tier 1b)

#### Tier 1b — Dialyzer (optional, slower)

Dialyzer is slow on first run (PLT build) but fast with a cached PLT. Options:
- **A) Include in PR gate** — cache the PLT aggressively, adds ~1-2 min with warm cache
- **B) Run only on main push** — faster PR feedback, still catches type issues post-merge
- **Recommendation:** Start with (A) since it should be fast with a warm PLT cache, and catching type errors pre-merge is the whole point

### Full Suite (manual trigger)

**Trigger:** `workflow_dispatch` only (button click in Actions tab)
**Time budget:** ~15-20 min (parallel where possible)
**Secrets needed:** `ANTHROPIC_API_KEY`

Runs everything in TESTING.md — the PR gate jobs plus all the heavy stuff:

| Job | Maps to | Needs |
|-----|---------|-------|
| **elixir-check** | `make check` | — |
| **go-check** | `make sidecar-check` | — |
| **elixir-integration** | `make test-integration` | — |
| **elixir-e2e** | `make e2e-elixir` | sidecar binary |
| **e2e-gate** | `make e2e-gate` | Phoenix server |
| **e2e-gate-claude** | `make e2e-gate-claude` | Phoenix server, API key |
| **docker-integration** | `make docker-integration` | Docker |
| **docker-e2e-mock** | `make e2e-docker-simple` + `make e2e-docker-multi` | Docker, combo image |
| **docker-e2e-claude** | `make e2e-docker-simple-claude` + `make e2e-docker-multi-claude` | Docker, combo image, API key |
| **cli-e2e** | `make e2e-cli` + `make e2e-cli-multi` | Phoenix server, API key |
| **e2e-local** | `make e2e-local` | sidecar + worker binaries |
| **k8s-e2e** | `make e2e-k8s-simple` + `make e2e-k8s-multi` | kind cluster |

Jobs are grouped by infra dependency so they can share setup:
- **No infra group:** elixir-check, go-check, elixir-integration (parallel)
- **Phoenix server group:** e2e-gate, e2e-gate-claude, cli-e2e (parallel, each starts own server)
- **Docker group:** docker-integration, docker-e2e-mock, docker-e2e-claude (parallel)
- **Binary group:** e2e-local, elixir-e2e (need `make sidecar-build worker-build` first)
- **K8s group:** k8s-e2e (needs kind setup first)

## Workflow Files

```
.github/
  workflows/
    ci.yml              # PR gate — every push, blocks merge
    full-suite.yml      # Everything — manual trigger only
```

## Environment Matrix

| Dependency | Version | Source |
|------------|---------|--------|
| Elixir | 1.17.x | `erlef/setup-beam` action |
| OTP | 27.x | `erlef/setup-beam` action |
| Go | 1.25.x | `actions/setup-go` |
| Docker | pre-installed | `ubuntu-latest` runner |
| SQLite | pre-installed | `ubuntu-latest` runner |
| kind | 0.20+ | `helm/kind-action` (K8s only) |

## Caching Strategy

```yaml
# Elixir deps + build
- uses: actions/cache@v4
  with:
    path: |
      deps
      _build
    key: elixir-${{ runner.os }}-${{ hashFiles('mix.lock') }}

# Go modules
- uses: actions/cache@v4
  with:
    path: ~/go/pkg/mod
    key: go-${{ runner.os }}-${{ hashFiles('sidecar/go.sum') }}

# Dialyzer PLT (Tier 1b / main only)
- uses: actions/cache@v4
  with:
    path: priv/plts
    key: dialyzer-${{ runner.os }}-${{ hashFiles('mix.lock') }}
```

## Status Badges

Add to README after setup:
```markdown
[![CI](https://github.com/OWNER/cortex/actions/workflows/ci.yml/badge.svg)](https://github.com/OWNER/cortex/actions/workflows/ci.yml)
```

## Open Questions

- [ ] Where does the repo live? (needed for badge URLs and secret configuration)
- [ ] Dialyzer in PR gate (with PLT caching) or separate job?
