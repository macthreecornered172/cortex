# Phase 2.5: Mesh/Cluster LiveView UI

## Goal

Add a "Cluster" tab to the Cortex LiveView dashboard that shows connected agents in real-time — registrations, heartbeats, status changes, and peer communication. This makes the Phase 2 sidecar + gRPC work visible in the UI.

## Context

Phase 2 added:
- Go sidecar binary that connects to the Cortex gateway via gRPC on port 4001
- `Gateway.Registry` tracks all connected agents (gRPC + WebSocket)
- PubSub events fire on `:agent_registered`, `:agent_unregistered`, `:agent_status_changed` via `Cortex.Gateway.Events`
- The existing `MeshLive` (`/mesh`) visualizes SWIM membership protocol — this is different. We need a new page for the agent gateway mesh.
- Run `make e2e` to see agents registering — the UI should show this live.

## Existing Infrastructure (read these files)

- `lib/cortex_web/live/dashboard_live.ex` — subscribes to gateway events, shows agent count. Use as pattern.
- `lib/cortex_web/live/mesh_live.ex` — SWIM protocol viz. Naming reference (we're adding a cluster/gateway view, not replacing this).
- `lib/cortex_web/router.ex` — add route here
- `lib/cortex_web/layouts/root.html.heex` — add nav item here
- `lib/cortex_web/components/core_components.ex` — reuse `.status_badge`, `.header`
- `lib/cortex/gateway/registry.ex` — `list/0`, `get/1`, `count/0` for initial state
- `lib/cortex/gateway/registered_agent.ex` — agent struct with `name`, `role`, `capabilities`, `status`, `transport`, `last_heartbeat`
- `lib/cortex/gateway/events.ex` — PubSub topic and event types

## What to Build

### 1. `lib/cortex_web/live/cluster_live.ex` — New LiveView page

**Mount:**
- Subscribe to `Cortex.Gateway.Events` (`:agent_registered`, `:agent_unregistered`, `:agent_status_changed`)
- Load initial agent list from `Gateway.Registry.list()`

**UI sections:**
- **Header:** "Cluster" with connected agent count badge
- **Agent cards/table:** Each agent shows:
  - Name, role, status (with status_badge)
  - Transport badge (`:grpc` = blue, `:websocket` = green)
  - Capabilities as tags
  - Last heartbeat (relative time, e.g., "3s ago")
  - Registered at timestamp
  - Agent ID (truncated, copyable)
- **Empty state:** "No agents connected. Start a sidecar to see agents appear."
- **Auto-updates:** Cards update in real-time as PubSub events arrive

**Event handling:**
```elixir
handle_info(%{type: :agent_registered, payload: agent}, socket)
  → prepend agent to list, flash "Agent connected: {name}"

handle_info(%{type: :agent_unregistered, payload: %{agent_id: id}}, socket)
  → remove from list, flash "Agent disconnected: {name}"

handle_info(%{type: :agent_status_changed, payload: %{agent_id: id, status: status}}, socket)
  → update agent status in list
```

**Refresh:** Periodic heartbeat check (every 5s) to update "last seen" times.

### 2. Router + Nav

- Add `live "/cluster", ClusterLive, :index` to router
- Add nav item in `root.html.heex` sidebar (between "Mesh" and "Jobs")
- Icon: server/network icon (heroicon)

### 3. Styling

- Match existing dark theme (bg-gray-950, text-gray-300)
- Use the cortex color palette (cortex-400 for highlights)
- Agent cards: bg-gray-900, border-gray-800, rounded-lg
- Transport badge: small pill next to agent name
- Status: reuse `.status_badge` component
- Capabilities: small rounded tags (bg-gray-800, text-gray-400)

## Verification

1. `mix compile --warnings-as-errors`
2. `mix test` — all existing tests pass
3. Manual: Start gateway (`make server`), connect sidecar (`make e2e`), see agent appear in `/cluster`
4. Manual: Kill sidecar, see agent disappear from `/cluster`

## Files to Create/Modify

| File | Action |
|------|--------|
| `lib/cortex_web/live/cluster_live.ex` | Create — main LiveView |
| `lib/cortex_web/router.ex` | Modify — add `/cluster` route |
| `lib/cortex_web/layouts/root.html.heex` | Modify — add nav item |

## Not in Scope

- Peer request visualization (Phase 3)
- Run-from-mesh workflow (Phase 3)
- Message flow visualization (Phase 3)
- Knowledge store UI (Phase 3)
