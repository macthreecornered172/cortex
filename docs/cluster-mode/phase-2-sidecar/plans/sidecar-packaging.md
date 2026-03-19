# Sidecar Packaging Engineer Plan

## You are in PLAN MODE.

### Project
I want to build the **Sidecar Packaging** for Cortex Cluster Mode Phase 2.

**Goal:** build the **CLI entrypoint, escript build configuration, Docker image, and convenience tooling** so that the Cortex sidecar can be distributed as a single binary, run locally via a helper script, and deployed as a container alongside agents in Docker or Kubernetes environments.

### Role + Scope
- **Role:** Sidecar Packaging Engineer
- **Scope:** I own the CLI entrypoint module (`Cortex.Sidecar.CLI`), the escript configuration in `mix.exs`, the sidecar Dockerfile, the local run script, and the usage guide. I do NOT own the sidecar core (Application, Config, Connection, State — Sidecar Core Engineer), the HTTP API (Router, Handlers — Sidecar HTTP API Engineer), or the integration tests (Integration Test Engineer).
- **File I will write:** `docs/cluster-mode/phase-2-sidecar/plans/sidecar-packaging.md`
- **No-touch zones:** do not edit any other files; do not write code.

---

## Functional Requirements

- **FR1:** A CLI entrypoint module (`Cortex.Sidecar.CLI`) that serves as the `main/1` function for the escript. Parses `--help`, `--version`, and passes control to `Cortex.Sidecar.Application`.
- **FR2:** `mix.exs` updated with `escript: [main_module: Cortex.Sidecar.CLI]` so that `mix escript.build` produces a `cortex_sidecar` executable.
- **FR3:** The escript starts cleanly with just `CORTEX_GATEWAY_URL` and `CORTEX_AGENT_NAME` set. All other config has sensible defaults (port 9090, heartbeat interval 15s, role "agent", capabilities empty list).
- **FR4:** A Dockerfile (`infra/docker/sidecar.Dockerfile`) that builds the escript in a build stage and copies it into a minimal Erlang runtime image.
- **FR5:** A convenience shell script (`scripts/run-sidecar.sh`) that sets default environment variables and runs the escript, with usage examples in comments.
- **FR6:** A usage guide (`docs/cluster-mode/SIDECAR_GUIDE.md`) documenting configuration, local usage, Docker usage, and Kubernetes sidecar deployment.

## Non-Functional Requirements

- **NF1:** The escript must start in under 2 seconds on a modern machine (excluding Erlang VM boot).
- **NF2:** The Docker image should be under 100MB (Erlang runtime + escript only; no build tools, no source code).
- **NF3:** The CLI must print clear error messages when required environment variables are missing, then exit with a non-zero status code.
- **NF4:** `--help` output must list all environment variables and their defaults in a human-readable table.
- **NF5:** The escript must handle SIGTERM/SIGINT gracefully, allowing the sidecar to send a disconnect to the gateway before shutting down.
- **NF6:** The convenience script must work on macOS and Linux (POSIX-compatible shell).

## Assumptions / System Model

- **Erlang runtime required:** Escripts require an Erlang/OTP installation on the host. This is acceptable for Phase 2. A future phase could produce a Burrito/Bakeware self-contained binary if zero-dependency is needed.
- **Single Mix project:** The sidecar is built from the main Cortex Mix project, not a separate umbrella app. This allows sharing `Cortex.Gateway.Protocol` modules directly. If the sidecar grows significantly, it can be extracted to a separate project later.
- **Sidecar Core owns Application:** `Cortex.Sidecar.Application` (owned by Sidecar Core Engineer) is the OTP application that starts the supervision tree. My CLI module calls into it after parsing arguments.
- **Config module exists:** `Cortex.Sidecar.Config` (owned by Sidecar Core Engineer) parses environment variables into a config struct. My CLI validates that required vars are present before handing off.
- **Failure modes:**
  - Missing required env vars: CLI prints error message and exits with code 1.
  - Invalid env var values (e.g., non-integer port): CLI prints validation error and exits with code 1.
  - Erlang not installed: Escript fails to start with system-level error (outside our control).
  - Gateway unreachable at startup: Sidecar starts anyway (reconnection is Core Engineer's responsibility).

## Data Model

N/A — not in scope for this role. The CLI module is stateless. It reads environment variables and command-line arguments, then delegates to the Application module.

## APIs

### CLI Interface

```
Usage: cortex_sidecar [options]

Options:
  --help       Print this help message and exit
  --version    Print version and exit

Environment Variables:
  CORTEX_GATEWAY_URL         WebSocket URL to Cortex gateway (REQUIRED)
                             Example: ws://cortex:4000/agent/websocket
  CORTEX_AGENT_NAME          Agent name for registration (REQUIRED)
  CORTEX_AGENT_ROLE          Agent role description (default: "agent")
  CORTEX_AGENT_CAPABILITIES  Comma-separated capabilities (default: "")
  CORTEX_AUTH_TOKEN           Bearer token for gateway auth (default: "")
  CORTEX_SIDECAR_PORT        Local HTTP port (default: 9090)
  CORTEX_HEARTBEAT_INTERVAL  Heartbeat interval in seconds (default: 15)

Examples:
  CORTEX_GATEWAY_URL=ws://localhost:4000/agent/websocket \
  CORTEX_AGENT_NAME=security-reviewer \
  ./cortex_sidecar

  CORTEX_GATEWAY_URL=ws://cortex:4000/agent/websocket \
  CORTEX_AGENT_NAME=code-analyst \
  CORTEX_AGENT_CAPABILITIES=security-review,code-review \
  CORTEX_SIDECAR_PORT=8080 \
  ./cortex_sidecar
```

### Escript Build

```bash
mix escript.build    # produces ./cortex_sidecar
./cortex_sidecar --help
./cortex_sidecar --version
```

### Docker Build

```bash
docker build -f infra/docker/sidecar.Dockerfile -t cortex-sidecar .
docker run -e CORTEX_GATEWAY_URL=ws://host.docker.internal:4000/agent/websocket \
           -e CORTEX_AGENT_NAME=my-agent \
           cortex-sidecar
```

## Architecture / Component Boundaries

### Components I Create

1. **`Cortex.Sidecar.CLI`** (`lib/cortex/sidecar/cli.ex`) — escript entrypoint
   - `main/1` — parses argv, dispatches to help/version/start
   - Calls `Cortex.Sidecar.Config.from_env/0` to validate environment
   - Calls `Cortex.Sidecar.Application.start/2` (or starts the OTP app via `:application.ensure_all_started/1`)
   - Blocks on the running application (prevents escript from exiting)

2. **`mix.exs` updates** — escript config added to the `project/0` function

3. **`infra/docker/sidecar.Dockerfile`** — multi-stage Docker build
   - Stage 1 (build): Elixir image, `mix deps.get`, `mix escript.build`
   - Stage 2 (runtime): Erlang-only image, copy escript binary, set entrypoint

4. **`scripts/run-sidecar.sh`** — convenience launcher script

5. **`docs/cluster-mode/SIDECAR_GUIDE.md`** — usage documentation

### Components I Depend On (owned by other teammates)

- `Cortex.Sidecar.Config` (Sidecar Core Engineer) — environment variable parsing and validation
- `Cortex.Sidecar.Application` (Sidecar Core Engineer) — OTP application startup

### How the CLI Hands Off to the Application

```
cortex_sidecar main/1
  |
  +-- parse argv (--help, --version)
  |
  +-- Cortex.Sidecar.Config.from_env()
  |     |
  |     +-- reads env vars
  |     +-- validates required fields
  |     +-- returns {:ok, config} | {:error, reasons}
  |
  +-- on {:error, reasons}: print errors, exit(1)
  |
  +-- on {:ok, config}: start OTP app
  |     |
  |     +-- Application.put_env(:cortex, :sidecar_config, config)
  |     +-- {:ok, _} = Application.ensure_all_started(:cortex_sidecar)
  |     |   (or start the sidecar supervision tree directly)
  |
  +-- block forever (Process.sleep(:infinity) or receive loop)
```

### Escript Dependency Considerations

The escript bundles compiled BEAM bytecode for the `:cortex` application and its deps. Key considerations:
- Phoenix and Ecto are NOT needed in the sidecar. The escript config should specify `app: nil` or use `escript: [app: nil]` to avoid starting the full Cortex application.
- Only the sidecar-specific modules and their deps (Jason, Mint/Gun, Bandit/Cowboy) need to be included.
- The `escript` config in `mix.exs` can use `emu_args` to set VM flags if needed (e.g., `+S 2` for 2 schedulers to keep it lightweight).

### Concurrency Model

The CLI module itself is single-threaded (runs `main/1` then blocks). All concurrency is managed by the sidecar's OTP supervision tree (Core Engineer's scope).

## Correctness Invariants

1. **Required env vars enforced:** The CLI must never proceed to start the application if `CORTEX_GATEWAY_URL` or `CORTEX_AGENT_NAME` is missing or empty. It must print a clear error and exit with code 1.
2. **Clean exit codes:** `--help` and `--version` exit with code 0. Missing config exits with code 1. Successful startup runs until terminated.
3. **Version consistency:** `--version` output must match the version in `mix.exs`.
4. **Graceful shutdown:** SIGTERM triggers OTP shutdown, which propagates through the supervision tree. The sidecar connection should have a chance to send a disconnect message before the process exits.
5. **No Phoenix/Ecto in escript:** The escript must not attempt to start Phoenix or Ecto. Only sidecar-specific modules should be started.
6. **Dockerfile reproducibility:** The Dockerfile uses pinned base image versions (e.g., `erlang:27.2-slim`, `elixir:1.17-erlang-27.2`) for reproducible builds.

## Tests

### Unit Tests (`test/cortex/sidecar/cli_test.exs`)

1. **`--help` flag:** `CLI.main(["--help"])` prints usage text and exits cleanly (capture IO).
2. **`--version` flag:** `CLI.main(["--version"])` prints version string matching `Mix.Project.config()[:version]`.
3. **Missing required env vars:** With no `CORTEX_GATEWAY_URL` set, `CLI.main([])` prints error about missing gateway URL.
4. **Missing agent name:** With `CORTEX_GATEWAY_URL` set but no `CORTEX_AGENT_NAME`, prints error about missing agent name.
5. **Unknown flags:** `CLI.main(["--unknown"])` prints error and usage.

Note: Integration testing of actual escript build and Docker image is the Integration Test Engineer's scope. CLI unit tests use IO capture and do not actually start the OTP application.

### Test Commands

```bash
mix test test/cortex/sidecar/cli_test.exs
mix test test/cortex/sidecar/cli_test.exs --trace
```

### Docker Build Verification

```bash
# Build the escript
mix escript.build

# Verify it runs
./cortex_sidecar --help
./cortex_sidecar --version

# Build Docker image
docker build -f infra/docker/sidecar.Dockerfile -t cortex-sidecar .

# Verify Docker image size
docker images cortex-sidecar --format '{{.Size}}'

# Verify Docker entrypoint
docker run --rm cortex-sidecar --help
```

## Benchmarks + "Success"

No performance benchmarks needed for packaging. Success criteria:

| Criterion | Target |
|-----------|--------|
| `mix escript.build` completes | Under 30 seconds |
| `./cortex_sidecar --help` | Prints usage, exits 0 |
| `./cortex_sidecar --version` | Prints version, exits 0 |
| Missing env var | Prints error, exits 1 |
| Docker image size | Under 100MB |
| Docker `--help` works | Prints usage from container |
| `scripts/run-sidecar.sh --help` | Prints usage |
| All CLI tests pass | `mix test test/cortex/sidecar/cli_test.exs` |
| Sidecar guide is complete | Covers local, Docker, and k8s deployment |

---

## Engineering Decisions & Tradeoffs

### Decision 1: Escript in main Cortex project vs separate Mix project

- **Decision:** Keep the escript in the main Cortex Mix project.
- **Alternatives considered:** (a) Separate Mix project under `sidecar/` directory. (b) Umbrella app with `apps/sidecar/`.
- **Why:** Sharing protocol modules (`Cortex.Gateway.Protocol`, `Cortex.Gateway.Protocol.Messages`) is the primary motivation for the sidecar being in Elixir. A separate project would require publishing these as a library or using path deps, adding build complexity. The kickoff explicitly recommends keeping it in the main project for now.
- **Tradeoff acknowledged:** The escript will bundle more BEAM bytecode than strictly necessary (all of `:cortex` deps). We mitigate this by not starting Phoenix/Ecto in the sidecar's Application. If the escript grows too large, we can extract later. The escript binary size should still be reasonable (under 20MB) since it's just bytecode.

### Decision 2: `emu_args` for lightweight VM configuration

- **Decision:** Set `emu_args: ~c"-S 2 +sbwt none"` in the escript config to limit the VM to 2 schedulers and disable busy-wait on scheduler threads.
- **Alternatives considered:** Default VM settings (auto-detect CPU count, busy-wait enabled).
- **Why:** The sidecar is a lightweight process — one WebSocket connection, one small HTTP server. It doesn't need 8+ schedulers consuming CPU on an 8-core machine. 2 schedulers are sufficient. Disabling busy-wait reduces idle CPU usage, which matters when running as a sidecar alongside an agent that needs the CPU.
- **Tradeoff acknowledged:** If the sidecar handles many concurrent HTTP requests or heavy JSON parsing, 2 schedulers could become a bottleneck. This is unlikely given the sidecar serves a single local agent. The setting can be overridden via `ERL_FLAGS` environment variable if needed.

### Decision 3: Multi-stage Docker build with Erlang-only runtime

- **Decision:** Use a multi-stage Dockerfile — Elixir build stage, Erlang-only runtime stage.
- **Alternatives considered:** (a) Single-stage with full Elixir image. (b) Alpine-based Erlang image. (c) Distillery/Burrito for self-contained binary.
- **Why:** The escript only needs the Erlang runtime, not the Elixir compiler. Erlang-slim images are ~80MB smaller than Elixir images. Alpine would be even smaller but has known issues with BEAM DNS resolution and OpenSSL. Debian-slim Erlang images are the sweet spot.
- **Tradeoff acknowledged:** The image still requires Erlang (~60-80MB base). A Go sidecar would produce a ~10MB static binary with zero runtime dependency. For Phase 2, the Erlang image size is acceptable given the code-sharing benefits.

---

## Risks & Mitigations

### Risk 1: Escript bundles too many dependencies

- **Risk:** The escript includes all Cortex deps (Phoenix, LiveView, Ecto, Tailwind) making it 50MB+ and slow to start.
- **Impact:** Large binary, slow startup, confusing error messages if Phoenix tries to start.
- **Mitigation:** The sidecar's Application module (Core Engineer's scope) must NOT start the full Cortex application — only the sidecar supervision tree. In `mix.exs`, we can explore using `escript: [app: nil]` to prevent auto-starting the `:cortex` app, and manually start only needed applications (`:jason`, `:mint`, etc.). If the binary is too large, we can investigate `escript: [strip_beams: true]` to remove debug info, or extract to a separate project.
- **Validation:** After first build, check binary size with `ls -lh cortex_sidecar` and startup time with `time ./cortex_sidecar --version`.

### Risk 2: Escript cannot start sidecar supervision tree without full Cortex app

- **Risk:** The sidecar modules may depend on modules that depend on Phoenix/Ecto being started (transitive dependencies).
- **Impact:** Escript crashes on startup with `:undef` or `:noproc` errors.
- **Mitigation:** The sidecar modules should have a clean dependency boundary — they depend on `Gateway.Protocol` (pure functions, no GenServer) and their own supervision tree. The CLI module explicitly starts only needed OTP applications. Early integration testing (Task 4) catches this.
- **Validation:** Build escript, run with required env vars, confirm it starts without errors.

### Risk 3: Sidecar Core / HTTP API modules not ready when packaging starts

- **Risk:** CLI module depends on `Cortex.Sidecar.Config` and `Cortex.Sidecar.Application` which may not exist yet.
- **Impact:** Cannot build or test the escript.
- **Mitigation:** Tasks 1-3 (CLI, mix.exs, Dockerfile, script, guide) can be developed with a stub Application/Config. Task 1 explicitly notes that CLI tests mock the Config module. Packaging work is largely independent — the CLI, Dockerfile, and script are infrastructure that wraps whatever the Core/API engineers produce.
- **Validation:** CLI tests pass with stubs; full integration tested after Core/API modules are ready.

### Risk 4: Docker build fails due to missing system deps or network issues

- **Risk:** The Dockerfile `mix deps.get` step fails in CI/air-gapped environments.
- **Impact:** Cannot build Docker image.
- **Mitigation:** Use `--build-arg` for hex mirror configuration. Document that `mix deps.get` must succeed in the build environment. For air-gapped builds, deps can be vendored via `mix deps.get && cp -r deps/ vendor/`.
- **Validation:** Build the Docker image locally and in CI.

### Risk 5: Graceful shutdown doesn't propagate through escript

- **Risk:** SIGTERM kills the escript process immediately without triggering OTP shutdown callbacks.
- **Impact:** Sidecar disconnects abruptly without notifying the gateway.
- **Mitigation:** Escripts run on the BEAM VM which handles SIGTERM via `:init.stop/0`. The supervision tree's `terminate/2` callbacks fire. Verify this behavior in integration testing. If needed, install a custom signal handler via `:os.set_signal/2` (OTP 26+).
- **Validation:** Start the sidecar, send SIGTERM, verify gateway receives disconnect event.

---

## Recommended API Surface

### `Cortex.Sidecar.CLI`

```elixir
@spec main([String.t()]) :: no_return()
def main(argv)
# Parses argv, validates env, starts sidecar or prints help/version.
# Exits with code 0 for --help/--version, 1 for errors, blocks on success.
```

Internal helpers (private):

```elixir
defp parse_args(argv) :: :help | :version | :start | {:error, String.t()}
defp print_help() :: :ok
defp print_version() :: :ok
defp start_sidecar() :: no_return()
defp print_error(message) :: :ok
```

### `mix.exs` additions

```elixir
def project do
  [
    # ... existing config ...
    escript: escript()
  ]
end

defp escript do
  [
    main_module: Cortex.Sidecar.CLI,
    name: "cortex_sidecar",
    app: nil,
    emu_args: ~c"-S 2 +sbwt none"
  ]
end
```

### Dependencies on Other Teammates' APIs

```elixir
# Sidecar Core Engineer
Cortex.Sidecar.Config.from_env() :: {:ok, Config.t()} | {:error, [String.t()]}
Cortex.Sidecar.Application.start(type, args) :: {:ok, pid()} | {:error, term()}
```

---

## Folder Structure

```
lib/
  cortex/
    sidecar/
      cli.ex                    # CLI entrypoint (Sidecar Packaging Engineer)
      application.ex            # OTP Application (Sidecar Core Engineer)
      config.ex                 # Config parsing (Sidecar Core Engineer)
      connection.ex             # WebSocket client (Sidecar Core Engineer)
      state.ex                  # State manager (Sidecar Core Engineer)
      router.ex                 # HTTP router (Sidecar HTTP API Engineer)
      handlers/                 # HTTP handlers (Sidecar HTTP API Engineer)

test/
  cortex/
    sidecar/
      cli_test.exs              # CLI tests (Sidecar Packaging Engineer)

infra/
  docker/
    sidecar.Dockerfile          # Sidecar Docker image (Sidecar Packaging Engineer)

scripts/
  run-sidecar.sh                # Local run script (Sidecar Packaging Engineer)

docs/
  cluster-mode/
    SIDECAR_GUIDE.md            # Usage guide (Sidecar Packaging Engineer)
```

Files I create: `cli.ex`, `cli_test.exs`, `sidecar.Dockerfile`, `run-sidecar.sh`, `SIDECAR_GUIDE.md`
Files I modify: `mix.exs` (add escript config)
Files I depend on: `application.ex`, `config.ex` (Sidecar Core Engineer)

---

## Tighten the plan into 4-7 small tasks (STRICT)

### Task 1: CLI entrypoint with --help and --version

- **Outcome:** `Cortex.Sidecar.CLI` module with `main/1` that handles `--help` (prints usage with env var reference), `--version` (prints version from mix config), and unknown flags (prints error + usage). Does NOT yet start the sidecar — just the arg parsing and output.
- **Files to create:** `lib/cortex/sidecar/cli.ex`, `test/cortex/sidecar/cli_test.exs`
- **Exact verification command(s):**
  ```bash
  mix compile --warnings-as-errors
  mix test test/cortex/sidecar/cli_test.exs --trace
  mix format --check-formatted
  mix credo --strict
  ```
- **Suggested commit message:** `feat(sidecar): add CLI entrypoint with --help and --version`

### Task 2: CLI startup with env var validation and escript config

- **Outcome:** `CLI.main([])` reads env vars via `Cortex.Sidecar.Config.from_env/0`, prints clear errors for missing required vars, and starts the sidecar application on success. `mix.exs` updated with `escript/0` config. `mix escript.build` produces a working `cortex_sidecar` binary.
- **Files to modify:** `lib/cortex/sidecar/cli.ex`, `mix.exs`
- **Files to modify (tests):** `test/cortex/sidecar/cli_test.exs`
- **Exact verification command(s):**
  ```bash
  mix compile --warnings-as-errors
  mix test test/cortex/sidecar/cli_test.exs --trace
  mix escript.build
  ./cortex_sidecar --help
  ./cortex_sidecar --version
  mix format --check-formatted
  mix credo --strict
  ```
- **Suggested commit message:** `feat(sidecar): add env var validation and escript build config`

### Task 3: Sidecar Dockerfile

- **Outcome:** Multi-stage Dockerfile that builds the escript in an Elixir build stage and copies it to a minimal Erlang runtime image. Entrypoint is the escript binary.
- **Files to create:** `infra/docker/sidecar.Dockerfile`
- **Exact verification command(s):**
  ```bash
  docker build -f infra/docker/sidecar.Dockerfile -t cortex-sidecar .
  docker run --rm cortex-sidecar --help
  docker images cortex-sidecar --format '{{.Size}}'
  ```
- **Suggested commit message:** `infra(sidecar): add Dockerfile for sidecar binary`

### Task 4: Convenience run script

- **Outcome:** A POSIX shell script that sets default environment variables, validates required ones, and runs the escript. Includes commented usage examples.
- **Files to create:** `scripts/run-sidecar.sh`
- **Exact verification command(s):**
  ```bash
  chmod +x scripts/run-sidecar.sh
  scripts/run-sidecar.sh --help
  # Verify POSIX compliance
  shellcheck scripts/run-sidecar.sh
  ```
- **Suggested commit message:** `feat(sidecar): add convenience run script for local development`

### Task 5: Sidecar usage guide

- **Outcome:** Comprehensive guide covering configuration reference (all env vars with types, defaults, examples), local usage, Docker usage, and Kubernetes sidecar container deployment pattern.
- **Files to create:** `docs/cluster-mode/SIDECAR_GUIDE.md`
- **Exact verification command(s):**
  ```bash
  # Verify all env vars mentioned in the guide match those in Config module
  # Verify all examples in the guide are syntactically correct
  # Manual review
  ```
- **Suggested commit message:** `docs(sidecar): add comprehensive sidecar usage guide`

---

## CLAUDE.md contributions (do NOT write the file; propose content)

### From Sidecar Packaging Engineer

**Dev commands:**
```bash
# Build sidecar escript
mix escript.build

# Run sidecar locally
./cortex_sidecar --help
./cortex_sidecar --version
CORTEX_GATEWAY_URL=ws://localhost:4000/agent/websocket CORTEX_AGENT_NAME=test ./cortex_sidecar

# Run via convenience script
scripts/run-sidecar.sh

# Build sidecar Docker image
docker build -f infra/docker/sidecar.Dockerfile -t cortex-sidecar .
```

**Architecture notes:**
- The sidecar is built as an Elixir escript from the main Cortex project
- `Cortex.Sidecar.CLI` is the escript entrypoint (`main/1`)
- The escript does NOT start Phoenix or Ecto — only the sidecar supervision tree
- Escript VM flags: `-S 2 +sbwt none` (2 schedulers, no busy-wait)

**Before you commit checklist (additions):**
- After modifying sidecar modules, verify `mix escript.build` still succeeds
- Verify `./cortex_sidecar --help` still prints correct usage

---

## EXPLAIN.md contributions (do NOT write the file; propose outline bullets)

**Packaging & Distribution:**
- The sidecar is packaged as an Elixir escript — a single executable file containing compiled BEAM bytecode
- `mix escript.build` produces `cortex_sidecar` in the project root
- The escript requires an Erlang/OTP runtime on the host machine
- A multi-stage Dockerfile builds the escript and packages it with a minimal Erlang runtime (~80MB image)
- The sidecar shares protocol modules with the gateway — same parsing, validation, and message structs
- VM is configured for low resource usage: 2 schedulers, no busy-wait threads

**Running the Sidecar:**
- Locally: set `CORTEX_GATEWAY_URL` and `CORTEX_AGENT_NAME`, run `./cortex_sidecar`
- Docker: `docker run -e CORTEX_GATEWAY_URL=... -e CORTEX_AGENT_NAME=... cortex-sidecar`
- Kubernetes: deploy as a sidecar container in the agent pod, sharing localhost networking

**Key Engineering Decisions:**
- Escript in main project (not separate repo) — enables sharing protocol modules without publishing a library
- Lightweight VM config (`-S 2`) — sidecar is a thin proxy, doesn't need many schedulers
- Erlang-slim runtime image (not Alpine) — avoids DNS/SSL issues common with musl libc on BEAM

**Limits of MVP + Next Steps:**
- Requires Erlang runtime on host (consider Burrito/Bakeware for zero-dep binary later)
- Escript bundles all Cortex deps (larger than necessary); extract to separate project if size is a concern
- No health check endpoint in Docker (add `HEALTHCHECK` directive once HTTP API is stable)
- No Helm chart or k8s manifests yet — guide documents the pattern, infrastructure as code comes later

---

## READY FOR APPROVAL
