# Config Engineer — Phase 1 Foundation Plan

## You are in PLAN MODE.

### Project
I want to do a **compute spawning abstraction layer for Cortex**.

**Goal:** build a **Provider + SpawnBackend config system** in which we **extend the YAML config schema with `provider` and `backend` fields, parse them from YAML, validate them, and apply defaults — so the orchestration layer can dispatch to the right Provider/SpawnBackend implementation based on per-team config**.

### Role + Scope
- **Role:** Config Engineer
- **Scope:** Own all YAML config changes for provider/backend selection across the three config systems (orchestration DAG, mesh, gossip). Specifically: schema structs, loader parsing, and validator rules. Do NOT own the Provider or SpawnBackend behaviour definitions, the CLI refactor, or the orchestration wiring.
- **File you will write:** `docs/compute-spawning/phase-1-foundation/plans/config-engineer.md`
- **No-touch zones:** do not edit Provider/SpawnBackend behaviour files, Spawner, Runner/Executor, or any LiveView code.

---

## Functional Requirements
- FR1: `Defaults` struct gains `provider` (atom, default `:cli`) and `backend` (atom, default `:local`) fields.
- FR2: `Team` struct gains optional `provider` and `backend` fields (atom or nil) that override the project-level defaults when set.
- FR3: The YAML loader parses `provider` and `backend` string values from `defaults` and per-team sections, converting them to atoms from a safe allowlist.
- FR4: The validator enforces:
  - `provider` must be one of `:cli`, `:http`, `:external`
  - `backend` must be one of `:local`, `:docker`, `:k8s`
  - Warning if `backend` is `:docker` or `:k8s` but `provider` is `:cli` (CLI requires local port)
  - Error if `provider` is `:external` (not implemented yet in Phase 1)
- FR5: Mesh and gossip config loaders parse `provider`/`backend` from their `defaults` section (they share the `Defaults` struct).
- Tests required: unit tests for all new fields in loader and validator.
- Metrics required: N/A — config parsing is not a metrics concern.

## Non-Functional Requirements
- Language/runtime: Elixir 1.16+, Erlang/OTP 26+
- Local dev: `mix test` — no external dependencies needed
- Observability: N/A for config parsing
- Safety: String-to-atom conversion must use an explicit allowlist (no `String.to_atom/1` on arbitrary user input)
- Documentation: `@moduledoc`, `@doc`, `@spec` on all new/modified public functions per project conventions
- Performance: N/A — config loading is a one-time operation per run

---

## Assumptions / System Model
- Deployment environment: local dev (config loading happens at orchestration start)
- Failure modes: invalid YAML values, unknown provider/backend strings, incompatible provider+backend combinations
- Delivery guarantees: N/A
- Multi-tenancy: N/A

---

## Data Model

### Modified Structs

- **Defaults** (`Cortex.Orchestration.Config.Defaults`)
  - Add `provider` — atom, default `:cli`, one of `[:cli, :http, :external]`
  - Add `backend` — atom, default `:local`, one of `[:local, :docker, :k8s]`
  - Existing fields unchanged: `model`, `max_turns`, `permission_mode`, `timeout_minutes`

- **Team** (`Cortex.Orchestration.Config.Team`)
  - Add `provider` — atom or nil, default `nil` (inherits from Defaults when nil)
  - Add `backend` — atom or nil, default `nil` (inherits from Defaults when nil)
  - Existing fields unchanged: `name`, `lead`, `members`, `tasks`, `depends_on`, `context`

- **Lead** — no changes. Provider/backend is a team-level concern; the lead shares the team's provider/backend.

### Validation Rules
- `provider` values: allowlist `["cli", "http", "external"]` → atoms `[:cli, :http, :external]`
- `backend` values: allowlist `["local", "docker", "k8s"]` → atoms `[:local, :docker, :k8s]`
- Unknown strings → hard error: `"invalid provider: 'foo', must be one of: cli, http, external"`
- `provider: :external` → hard error in Phase 1: `"provider 'external' is not yet implemented"`
- `backend: :docker` or `:k8s` with `provider: :cli` → soft warning: `"backend 'docker' with provider 'cli' is unusual — CLI provider requires a local port"`

### Versioning Strategy
- Additive only — omitting `provider`/`backend` preserves current behavior (defaults to `:cli`/`:local`).
- No migration needed; existing YAML files are valid as-is.

---

## APIs

### Config Struct API (public Elixir API)

No new functions. The existing `Loader.load/1`, `Loader.load_string/1`, and `Validator.validate/1` gain support for the new fields. The structs grow two fields each.

**Effective provider/backend resolution** (consumed by Integration Engineer, not implemented here):
```elixir
# Integration Engineer will add a helper like:
effective_provider = team.provider || config.defaults.provider  # => :cli
effective_backend  = team.backend  || config.defaults.backend   # => :local
```

### YAML Surface

```yaml
# New optional fields in defaults
defaults:
  model: opus
  max_turns: 100
  provider: cli          # cli | http | external (default: cli)
  backend: local         # local | docker | k8s (default: local)

# New optional fields per team
teams:
  - name: architect
    provider: http       # overrides defaults.provider for this team
    backend: k8s         # overrides defaults.backend for this team
    lead:
      role: "Architect"
    tasks:
      - summary: "Design system"
```

### Mesh/Gossip Defaults

The mesh and gossip config loaders already construct `%Defaults{}` from their `defaults` YAML section. They will parse the same `provider`/`backend` fields. Mesh/gossip agents don't have per-agent provider/backend overrides (their `Agent` structs are different from orchestration `Team` structs), so only the `defaults`-level fields apply.

---

## Architecture / Component Boundaries

### Components I Touch

1. **`Cortex.Orchestration.Config.Defaults`** — add `provider` and `backend` fields to struct, typespec, and moduledoc
2. **`Cortex.Orchestration.Config.Team`** — add optional `provider` and `backend` fields
3. **`Cortex.Orchestration.Config.Loader`** — parse new fields from YAML maps with safe atom conversion
4. **`Cortex.Orchestration.Config.Validator`** — validate provider/backend values and cross-field rules
5. **`Cortex.Mesh.Config.Loader`** — parse `provider`/`backend` from mesh defaults section
6. **`Cortex.Gossip.Config.Loader`** — parse `provider`/`backend` from gossip defaults section

### Components I Do NOT Touch
- Provider/SpawnBackend behaviours (Behaviour Architect)
- Spawner, Provider.CLI, SpawnBackend.Local (CLI Refactor Engineer)
- Runner.Executor dispatch logic (Integration Engineer)
- LiveView/dashboard

### How Config Changes Propagate
Config is loaded once at run start by `Runner` calling `Loader.load/1`. The resulting `Config` struct flows through `Executor` which will (after Integration Engineer wires it) read `team.provider`/`team.backend` to select the right Provider/SpawnBackend. No watches, no event bus — it's a static config read.

---

## Correctness Invariants

1. **Omitting provider/backend preserves existing behavior.** A YAML file with no `provider`/`backend` fields produces `defaults.provider == :cli` and `defaults.backend == :local`. All existing tests pass without modification.
2. **Unknown provider/backend strings are hard errors.** `provider: "openai"` → validation error.
3. **Atom conversion uses an explicit allowlist.** No arbitrary `String.to_atom/1` — only `"cli" → :cli`, `"http" → :http`, `"external" → :external`, `"local" → :local`, `"docker" → :docker`, `"k8s" → :k8s`.
4. **Team-level nil means "inherit from defaults."** `team.provider == nil` means use `config.defaults.provider`.
5. **Provider `:external` is a hard error in Phase 1.** Prevents users from configuring a provider that doesn't exist yet.
6. **Cross-field warnings are soft, not blocking.** `backend: k8s` + `provider: cli` produces a warning but still passes validation.

---

## Tests

### Unit Tests

**Loader tests** (`test/cortex/orchestration/config/loader_test.exs`):
- Parse `provider`/`backend` from defaults section
- Parse `provider`/`backend` per team
- Default to `:cli`/`:local` when fields are omitted
- Handle unknown strings gracefully (they become nil, validator catches them)
- Existing tests continue passing (no regressions)

**Validator tests** (`test/cortex/orchestration/config/validator_test.exs`):
- Valid provider values (`:cli`, `:http`) pass
- Invalid provider value is a hard error
- Valid backend values (`:local`, `:docker`, `:k8s`) pass
- Invalid backend value is a hard error
- `:external` provider is a hard error
- `:docker`/`:k8s` backend with `:cli` provider produces a warning
- Team-level overrides validated independently from defaults
- `nil` team-level provider/backend passes (means inherit)

**Mesh loader tests** (`test/cortex/mesh/config/loader_test.exs`):
- Parse `provider`/`backend` from mesh defaults
- Default to `:cli`/`:local` when omitted

**Gossip loader tests** (`test/cortex/gossip/config/loader_test.exs`):
- Parse `provider`/`backend` from gossip defaults
- Default to `:cli`/`:local` when omitted

### Integration Tests
N/A — config parsing is pure data transformation, no external dependencies.

### Failure Injection Tests
N/A — config loading has no external failure modes beyond file I/O (already tested).

### Commands
```bash
mix test test/cortex/orchestration/config/loader_test.exs
mix test test/cortex/orchestration/config/validator_test.exs
mix test test/cortex/mesh/config/loader_test.exs
mix test test/cortex/gossip/config/loader_test.exs
mix test                        # full suite — no regressions
mix compile --warnings-as-errors
mix credo --strict
mix format --check-formatted
```

---

## Benchmarks + "Success"
N/A — config parsing is a one-time operation at orchestration start. It processes a small YAML file (typically <100 lines). There is no meaningful performance concern.

---

## Engineering Decisions & Tradeoffs

### Decision 1: Atoms for provider/backend, not strings
- **Decision:** Store `provider` and `backend` as atoms (`:cli`, `:local`) in structs, not as strings.
- **Alternatives considered:** Keep as strings and pattern match on strings downstream.
- **Why:** Atoms enable clean pattern matching in function heads (e.g., `dispatch(:cli, opts)` vs `dispatch("cli", opts)`). They are the idiomatic Elixir approach for fixed enumerations. The Provider/SpawnBackend behaviours will dispatch on these atoms.
- **Tradeoff acknowledged:** Requires careful string-to-atom conversion with an allowlist to avoid atom table pollution. We accept this small parsing complexity for cleaner downstream code.

### Decision 2: Safe atom conversion via explicit allowlist, not String.to_existing_atom
- **Decision:** Use a private `parse_provider/1` function with explicit clauses (`"cli" -> :cli`, etc.) rather than `String.to_existing_atom/1`.
- **Alternatives considered:** `String.to_existing_atom/1` — would work since the atoms are defined in the module, but raises `ArgumentError` on unknown input, making error messages harder to control.
- **Why:** Explicit clauses let us return `nil` for unknown values and generate clear validation error messages. It's also more readable and self-documenting.
- **Tradeoff acknowledged:** Adding a new provider/backend value requires updating the parse function (not just defining the atom). This is acceptable since new providers are rare and require corresponding behaviour implementations.

### Decision 3: Team-level override is nil (inherit) vs explicit atom (override)
- **Decision:** Team `provider`/`backend` default to `nil`, meaning "inherit from defaults." An explicit value overrides.
- **Alternatives considered:** Eagerly resolve the effective provider/backend in the Loader (fill in defaults at parse time).
- **Why:** Keeping `nil` preserves the distinction between "not specified" and "explicitly set to the same value as default." This gives the Integration Engineer flexibility to resolve defaults at dispatch time, and makes the config struct a faithful representation of what the user wrote.
- **Tradeoff acknowledged:** Downstream code must handle nil and fall back to defaults. This is a one-line `||` operation, so the cost is minimal.

### Decision 4: Block :external provider in Phase 1 with a hard error
- **Decision:** Return a hard validation error if `provider: external` is used, since `Provider.External` doesn't exist yet.
- **Alternatives considered:** Accept it in config and let it fail at runtime when dispatch occurs.
- **Why:** Fail-fast at config load time gives the user a clear error before any agents are spawned. Runtime failure after partial execution is much worse.
- **Tradeoff acknowledged:** When `Provider.External` ships in Phase 2, we must remember to remove this validation gate. We'll add a code comment noting this.

---

## Risks & Mitigations

### Risk 1: Existing tests break due to struct changes
- **Risk:** Adding fields to `Defaults` and `Team` structs could break pattern matches or assertions in existing tests.
- **Impact:** CI red, blocks all other work.
- **Mitigation:** Both new fields have defaults (`provider: :cli`, `backend: :local` for Defaults; `provider: nil`, `backend: nil` for Team). Existing struct construction `%Defaults{}` and `%Team{name: ..., lead: ..., tasks: ...}` will pick up defaults automatically. Run full test suite after struct changes.
- **Validation time:** < 5 minutes (run `mix test`).

### Risk 2: Atom table pollution from arbitrary YAML input
- **Risk:** If we use `String.to_atom/1` on user-provided YAML strings, a malicious or malformed config could create unbounded atoms and crash the BEAM.
- **Impact:** BEAM crash (atoms are never garbage collected).
- **Mitigation:** Use explicit pattern matching with a fixed allowlist. Unknown strings become `nil` and are caught by the validator as errors. No dynamic atom creation.
- **Validation time:** < 5 minutes (write a test with `provider: "malicious_string"` and verify it returns a validation error, not an atom).

### Risk 3: Mesh/gossip loaders diverge from orchestration defaults
- **Risk:** The mesh and gossip loaders each have their own `build_defaults/1` function that constructs `%Defaults{}`. If we only update the orchestration loader, mesh/gossip configs will silently drop `provider`/`backend` fields.
- **Impact:** Users set `provider: http` in a mesh config and it's silently ignored — confusing.
- **Mitigation:** Update all three loaders in the same task. The `Defaults` struct change is automatic (new fields get defaults), but the `build_defaults/1` functions must explicitly parse the new YAML keys. Test all three.
- **Validation time:** < 5 minutes (add test cases to mesh and gossip loader tests).

### Risk 4: Validator coupling to Phase 2 readiness
- **Risk:** Blocking `:external` provider in the validator means Phase 2 must update the validator to unblock it. If this is forgotten, Phase 2 config won't work.
- **Impact:** Phase 2 blocked until validator is updated.
- **Mitigation:** Add a clear `# TODO(Phase 2): remove this gate when Provider.External ships` comment at the validation check. The External Provider Engineer's plan should list this file as a dependency.
- **Validation time:** < 2 minutes (code review check).

---

## Recommended API Surface

### Modified Functions (no new public functions)

1. **`Cortex.Orchestration.Config.Loader.load/1`** and **`load_string/1`** — unchanged signatures, now parse `provider`/`backend` from YAML.
2. **`Cortex.Orchestration.Config.Validator.validate/1`** — unchanged signature, now validates `provider`/`backend` fields.
3. **`Cortex.Mesh.Config.Loader.load/1`** and **`load_string/1`** — unchanged signatures, now parse `provider`/`backend` from defaults.
4. **`Cortex.Gossip.Config.Loader.load/1`** and **`load_string/1`** — unchanged signatures, now parse `provider`/`backend` from defaults.

### New Private Functions

- `Cortex.Orchestration.Config.Loader.parse_provider/1` — `"cli" → :cli | "http" → :http | "external" → :external | _ → nil`
- `Cortex.Orchestration.Config.Loader.parse_backend/1` — `"local" → :local | "docker" → :docker | "k8s" → :k8s | _ → nil`
- Same two functions in mesh and gossip loaders (or extract to a shared helper if the duplication is >10 lines).

---

## Folder Structure

No new files or directories needed. All changes are modifications to existing modules:

```
lib/cortex/orchestration/config/
  schema.ex            # modify Defaults + Team structs
  loader.ex            # modify build_defaults/1, build_team/1; add parse_provider/1, parse_backend/1
  validator.ex         # modify collect_errors/1, collect_warnings/1

lib/cortex/mesh/config/
  loader.ex            # modify build_defaults/1; add parse_provider/1, parse_backend/1

lib/cortex/gossip/config/
  loader.ex            # modify build_defaults/1; add parse_provider/1, parse_backend/1

test/cortex/orchestration/config/
  loader_test.exs      # add provider/backend parsing tests
  validator_test.exs   # add provider/backend validation tests

test/cortex/mesh/config/
  loader_test.exs      # add provider/backend defaults parsing tests

test/cortex/gossip/config/
  loader_test.exs      # add provider/backend defaults parsing tests
```

---

## Step-by-Step Task Plan

### Task 1: Add provider/backend fields to schema structs
- **Outcome:** `Defaults` has `provider: :cli` and `backend: :local` fields. `Team` has `provider: nil` and `backend: nil` fields. All types updated.
- **Files to create/modify:**
  - `lib/cortex/orchestration/config/schema.ex` — modify `Defaults` and `Team` defstructs and typespecs
- **Exact verification command(s):**
  - `mix compile --warnings-as-errors`
  - `mix test` (all existing tests should still pass since defaults are safe)
- **Suggested commit message:** `feat(config): add provider and backend fields to Defaults and Team structs`

### Task 2: Parse provider/backend in orchestration loader
- **Outcome:** `Loader.build_defaults/1` parses `provider` and `backend` from YAML. `build_team/1` parses team-level overrides. Unknown strings become `nil`.
- **Files to create/modify:**
  - `lib/cortex/orchestration/config/loader.ex` — modify `build_defaults/1`, `build_team/1`; add `parse_provider/1`, `parse_backend/1`
  - `test/cortex/orchestration/config/loader_test.exs` — add tests for new field parsing
- **Exact verification command(s):**
  - `mix test test/cortex/orchestration/config/loader_test.exs`
  - `mix format --check-formatted`
- **Suggested commit message:** `feat(config): parse provider/backend fields from orchestration YAML`

### Task 3: Validate provider/backend in orchestration validator
- **Outcome:** Validator checks provider/backend values on both defaults and per-team. Hard errors for invalid/unknown values and `:external`. Soft warning for `:cli` + remote backend.
- **Files to create/modify:**
  - `lib/cortex/orchestration/config/validator.ex` — add `validate_provider_backend/2` to error pipeline, add cross-field warning
  - `test/cortex/orchestration/config/validator_test.exs` — add validation tests
- **Exact verification command(s):**
  - `mix test test/cortex/orchestration/config/validator_test.exs`
  - `mix credo --strict`
- **Suggested commit message:** `feat(config): validate provider/backend fields with allowlists and cross-field rules`

### Task 4: Parse provider/backend in mesh and gossip loaders
- **Outcome:** Mesh and gossip `build_defaults/1` functions parse `provider`/`backend` from their YAML defaults section. Tests cover the new fields.
- **Files to create/modify:**
  - `lib/cortex/mesh/config/loader.ex` — modify `build_defaults/1`; add `parse_provider/1`, `parse_backend/1`
  - `lib/cortex/gossip/config/loader.ex` — modify `build_defaults/1`; add `parse_provider/1`, `parse_backend/1`
  - `test/cortex/mesh/config/loader_test.exs` — add defaults parsing tests
  - `test/cortex/gossip/config/loader_test.exs` — add defaults parsing tests
- **Exact verification command(s):**
  - `mix test test/cortex/mesh/config/loader_test.exs`
  - `mix test test/cortex/gossip/config/loader_test.exs`
- **Suggested commit message:** `feat(config): parse provider/backend in mesh and gossip config loaders`

### Task 5: Full suite verification and formatting pass
- **Outcome:** All tests pass, code is formatted, credo is clean, no warnings.
- **Files to create/modify:** Any fixups from prior tasks.
- **Exact verification command(s):**
  - `mix format`
  - `mix compile --warnings-as-errors`
  - `mix credo --strict`
  - `mix test`
- **Suggested commit message:** `chore(config): format and lint pass for provider/backend config changes`

---

## CLAUDE.md contributions (proposed, do NOT write the file)

### From Config Engineer

**Coding style:**
- Provider/backend values are atoms (`:cli`, `:http`, `:external`, `:local`, `:docker`, `:k8s`), never strings, in struct fields.
- Never use `String.to_atom/1` on YAML input — always use the explicit `parse_provider/1` and `parse_backend/1` allowlist functions.
- Team-level `provider`/`backend` of `nil` means "inherit from defaults." Resolution happens at dispatch time, not at config load time.

**Dev commands:**
```bash
mix test test/cortex/orchestration/config/  # config unit tests
mix test test/cortex/mesh/config/           # mesh config tests
mix test test/cortex/gossip/config/         # gossip config tests
```

**Before you commit:**
- Verify that omitting `provider`/`backend` from YAML still produces `:cli`/`:local` defaults.
- Verify that `provider: external` produces a hard validation error (until Phase 2 ships).
- Run `mix test` — no regressions in existing config tests.

**Guardrails:**
- Do not add new provider/backend atom values without also updating `parse_provider/1`, `parse_backend/1`, and the validator allowlists in all three loaders (orchestration, mesh, gossip).
- The `:external` provider gate in the validator has a `# TODO(Phase 2)` comment — remove it when `Provider.External` ships.

---

## EXPLAIN.md contributions (proposed outline bullets)

- **Config flow:** YAML file → `Loader.load/1` → `build_config/1` (with `parse_provider/1`, `parse_backend/1` for safe atom conversion) → `Validator.validate/1` → `%Config{}` struct with provider/backend fields
- **Key decision — atoms over strings:** Provider/backend are stored as atoms for idiomatic pattern matching in dispatch. Conversion uses explicit allowlists to prevent atom table pollution.
- **Key decision — nil means inherit:** Team-level `nil` defers to project defaults. This keeps the config struct a faithful representation of the YAML and lets dispatch code handle resolution.
- **Key decision — Phase 1 blocks :external:** `provider: external` is a hard error until `Provider.External` exists. Fail-fast at config time beats runtime confusion.
- **Limits of MVP:** Only `:cli` and `:http` providers pass validation. Docker/k8s backends are parseable but useless without `SpawnBackend.Docker`/`SpawnBackend.K8s` (Phase 3). The config is forward-compatible — users can set these values in YAML now, and they'll work when the implementations land.
- **How to validate locally:** `mix test test/cortex/orchestration/config/` covers all config parsing and validation. Load a sample YAML with `Loader.load_string/1` in IEx to verify interactively.

---

## READY FOR APPROVAL
