# Cortex HostPath Workspace Design Prompt

Drop this into a Cortex agent session to kick off the design discussion.

---

**Context:** Cortex is an Elixir/Phoenix multi-agent orchestration engine. When a run executes, agents work inside a `.cortex/` workspace directory that holds all artifacts — state, results, logs, messages, and knowledge files. Cortex also has an output store (`Cortex.Output.Store`) that periodically syncs the workspace to a configurable storage backend. In local/dev mode the backend is `Output.Store.Local`, which writes to a `base_path` directory on the local filesystem.

**The scenario:** In a Kubernetes deployment (kind, minikube, or bare-metal), Cortex runs in one pod and clients (e.g., a Go API bridge) run in separate pods. Clients need to read agent outputs — the full deliverables agents produce, plus workspace artifacts like state, logs, and messages. Today, the output store writes to a local path inside the Cortex pod, which other pods can't access.

**What we want:**

1. A way to configure Cortex's output store `base_path` to point at a shared volume mount (e.g., a Kubernetes `hostPath` or `PersistentVolumeClaim`) so that agent outputs are written to a location other pods can read from directly on disk — no API call needed.

2. The workspace sync (`Cortex.Orchestration.WorkspaceSync`) already pushes the full `.cortex/` directory tree to the output store every 30 seconds. If the output store's `base_path` is a shared mount, clients automatically get access to all workspace files.

3. This should be a configuration-level change, not a code change. The `Output.Store.Local` backend already supports a configurable `base_path`:

   ```elixir
   config :cortex, Cortex.Output.Store.Local,
     base_path: "/shared/cortex/outputs"
   ```

   The question is how to make this easy to set up in K8s manifests and document the pattern.

**What needs to be designed:**

1. **K8s volume configuration** — what volume type for each scenario?
   - `hostPath` for single-node clusters (kind, minikube) — simple, survives pod restarts
   - `PersistentVolumeClaim` for multi-node clusters — needs a storage class, more setup
   - What access mode? `ReadWriteOnce` is fine if Cortex is the only writer and clients just read

2. **Mount paths** — where should the volume be mounted in the Cortex pod? In the client pods? Should the path be the same in both for simplicity, or configurable per-pod?

3. **Key layout on disk** — the output store writes files at `<base_path>/runs/<run_id>/teams/<team_name>/output` for team outputs and `<base_path>/runs/<run_id>/workspace/<relative_path>` for workspace files. Clients need to know this layout to read files directly. Should we:
   - Document the key layout as a stable contract?
   - Provide a lightweight client library (Go package) that knows the layout?
   - Add a manifest/index file at `<base_path>/runs/<run_id>/workspace/_manifest.json` (already exists) that clients can read to discover files?

4. **Environment-based config** — the `base_path` should be settable via environment variable for 12-factor deployments:
   ```elixir
   config :cortex, Cortex.Output.Store.Local,
     base_path: System.get_env("CORTEX_OUTPUT_PATH", "priv/outputs")
   ```

5. **Helm chart / K8s manifests** — if Cortex has deployment manifests, they need:
   - A volume definition (hostPath or PVC)
   - A volumeMount on the Cortex pod
   - Documentation for clients to add a matching volumeMount to their own pods
   - An env var (`CORTEX_OUTPUT_PATH`) pointing to the mount path

6. **Cleanup and retention** — with a shared volume, old run outputs accumulate. Should Cortex:
   - Provide a TTL/retention policy for output store entries?
   - Leave cleanup to the operator (cron job, manual)?
   - Add a `mix cortex.cleanup` task?

**Questions to discuss:**
- Is `hostPath` sufficient for local K8s dev, or should we support NFS/EFS from the start?
- Should clients read files directly from the shared volume, or always go through the Cortex REST API? (Direct read is faster, API is more portable)
- How do we handle concurrent reads (client) and writes (workspace sync) — is filesystem atomicity enough, or do we need file locking?
- Should the output store key layout be considered a stable API, or should clients always use the manifest?

**Goal:** Make it trivial to deploy Cortex in K8s and have other pods read agent outputs directly from a shared volume, with zero code changes — just configuration and volume mounts.
