# Agent Worker Design

The missing piece between the sidecar and actual agent execution.

## Architecture

```
Cortex (control plane)     Sidecar (relay)          Agent Worker (brain)
──────────────────────     ──────────────           ────────────────────
Parses YAML                gRPC ↔ Cortex            Polls GET /task
Builds DAG                 HTTP API for worker       Runs claude -p (or Claude API)
Constructs prompts         Routes peer messages      Executes tool calls
Injects upstream context   Exposes /roster, /ask     Posts POST /task/result
Tracks run state           Manages connections
Serves UI
Spawns/kills pods (K8s)
```

## Control Plane → Worker: What gets sent

Cortex already builds rich prompts with upstream context, team info, and instructions.
For external agents, extend the TaskRequest to include peer awareness:

```protobuf
message TaskRequest {
  string task_id = 1;
  string prompt = 2;           // full prompt with upstream context baked in
  repeated string tools = 3;   // available tools
  int64 timeout_ms = 4;
  map<string, string> context = 5;  // structured metadata
}
```

The prompt includes:
- Role and task assignments (from YAML)
- Upstream team results (injected by executor, same as local agents)
- Active peer roster (from Gateway.Registry)
- Sidecar API docs (how to communicate with peers)
- Message inbox instructions

The context map carries structured data the worker can use programmatically:
- `model`: which Claude model to use
- `sidecar_url`: localhost:9091
- `peers`: JSON array of peer agents
- `max_turns`: agentic loop limit
- `permission_mode`: tool restrictions

## Peer Communication as Tools

Agents don't know about HTTP or gRPC. They see tools:

```json
[
  {
    "name": "send_message",
    "description": "Send a message to another agent in the mesh. Fire and forget.",
    "input_schema": {
      "type": "object",
      "properties": {
        "to": {"type": "string", "description": "Agent name"},
        "content": {"type": "string", "description": "Message content"}
      },
      "required": ["to", "content"]
    }
  },
  {
    "name": "ask_agent",
    "description": "Ask another agent a question and wait for their response.",
    "input_schema": {
      "type": "object",
      "properties": {
        "to": {"type": "string", "description": "Agent name"},
        "question": {"type": "string", "description": "Your question"}
      },
      "required": ["to", "question"]
    }
  },
  {
    "name": "check_inbox",
    "description": "Check for messages from other agents or the coordinator.",
    "input_schema": {
      "type": "object",
      "properties": {}
    }
  },
  {
    "name": "broadcast",
    "description": "Send a message to all agents in the mesh.",
    "input_schema": {
      "type": "object",
      "properties": {
        "content": {"type": "string", "description": "Message to broadcast"}
      },
      "required": ["content"]
    }
  }
]
```

The worker handles tool calls by translating to sidecar HTTP API:

```
Claude calls: ask_agent {to: "researcher-b", question: "What schema did you pick?"}
  → Worker: POST localhost:9091/ask/researcher-b
  → Sidecar: gRPC to researcher-b's sidecar
  → researcher-b processes and responds
  → Sidecar: returns response to worker
  → Worker: feeds response as tool_result to Claude
  → Claude continues reasoning with the answer
```

## Agent Worker Implementations

### V1: claude -p (ships today)
```
Poll GET /task → run `claude -p "prompt"` → POST /task/result
```
- Simplest possible — shell out to the CLI
- No tool management (claude CLI handles it)
- No peer communication tools (claude -p doesn't support custom tools)
- Good for: testing, local dev, basic tasks

### V2: Claude API with tools (production)
```
Poll GET /task → Claude Messages API loop → handle tool calls → POST /task/result
```
- Direct API calls, no CLI dependency
- Custom tools: bash, file_write, send_message, ask_agent, check_inbox, broadcast
- Agentic loop: Claude calls tools → worker executes → feeds results back → repeat
- Token tracking, cost reporting
- Good for: production, K8s, distributed workloads

### V3: Pluggable runtime (future)
```
Poll GET /task → any LLM or custom code → POST /task/result
```
- Swap Claude for OpenAI, Gemini, local models
- Or skip LLMs entirely — custom code that processes tasks
- The sidecar HTTP API is the universal interface

## K8s Pod Architecture

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: agent-researcher-a
  labels:
    cortex.dev/run-id: "abc-123"
    cortex.dev/team: "researcher-a"
spec:
  containers:
    - name: sidecar
      image: cortex-sidecar:v1
      env:
        - name: CORTEX_GATEWAY_URL
          value: "cortex-control-plane:4001"
        - name: CORTEX_AGENT_NAME
          value: "researcher-a"
        - name: CORTEX_AUTH_TOKEN
          valueFrom:
            secretKeyRef:
              name: cortex-gateway-token
              key: token
      ports:
        - containerPort: 9091

    - name: worker
      image: cortex-agent-worker:v1
      env:
        - name: SIDECAR_URL
          value: "http://localhost:9091"
        - name: ANTHROPIC_API_KEY
          valueFrom:
            secretKeyRef:
              name: anthropic-api-key
              key: key
```

Both containers share localhost. Sidecar handles gRPC, worker handles execution.

## What Exists vs What to Build

| Component | Status |
|-----------|--------|
| Cortex prompt building (role, tasks, upstream context) | Built |
| Cortex DAG executor + ExternalAgent | Built |
| Provider.External → gRPC → Sidecar | Built |
| Sidecar gRPC client + HTTP API | Built |
| Sidecar peer messaging (roster, ask, messages, broadcast) | Built |
| Agent worker V1 (claude -p) | Written, not built/tested |
| Agent worker V2 (Claude API + tools) | Not built |
| Peer communication tools for Claude | Not built |
| Extended TaskRequest with peer roster | Not built |
| SpawnBackend.Docker | Not built (Phase 4) |
| SpawnBackend.K8s | Not built (Phase 4) |

## Build Order

1. **Agent worker V1** — `claude -p`, polls sidecar, posts result. Makes examples work.
2. **Extended prompt** — add peer roster + sidecar API docs to the executor's prompt builder.
3. **Agent worker V2** — Claude API with agentic loop + peer communication tools.
4. **SpawnBackend.Docker** — Cortex runs `docker run` to start sidecar + worker pods.
5. **SpawnBackend.K8s** — Cortex creates K8s pod specs.
