# MCP Facade Plan (optional, later)

**Status:** Planned — not implemented
**Date:** 2026-11-08
**Priority:** P3 — build only after P0–P2 prove out in production use
**Depends on:** nothing from P0–P2 (orthogonal surface), but benefits from the persisted agent registry

---

## 1. Why an MCP facade at all

franky-box's native API is an HTTP task queue. The agent ecosystem, however, increasingly
speaks **MCP** (Model Context Protocol, spec `2026:7:28`, Linux-Foundation-governed): every
major agent harness (Claude Code, OpenAI Agents SDK, LangGraph, Cursor, Copilot, ADK) can
attach MCP servers and expose their tools to the LLM directly.

An MCP facade turns franky-box from "a service franky agents talk to" into "a tool any
MCP-capable agent can drive". Concretely:

- A Claude Code / Cursor session could **dispatch work** to a remote franky worker fleet
  (`box.dispatch_task`) and **pick up results** (`box.read_result`) without custom glue.
- An orchestrator agent could claim/complete on behalf of sub-agents, using the mailbox
  as its coordination substrate.
- The MCP Registry (registry.modelcontextprotocol.io) could list franky-box instances,
  making a fleet discoverable.

Research conclusion (see `AGENT_INTEROP_RESEARCH.md`): MCP's stateless tool model is a
*poorer* fit for a durable inbox/outbox than A2A's stateful Task model — hence the facade
is a **convenience surface, not the core**. The core remains the REST queue + (future) A2A
endpoint mapping.

## 2. Scope: which operations become MCP tools

Only operations that make sense *synchronously* from an agent's tool loop:

| MCP tool | Wraps | Notes |
|---|---|---|
| `box_dispatch_task` | `POST /v1/tasks/dispatch-advanced` | agent_id, action, payload, priority?, blocked_by?, idempotency_key? — returns task_id |
| `box_get_task` | `GET /v1/agents/{id}/tasks/{task}` | full state incl. A2A-style state name |
| `box_cancel_task` | `POST /v1/agents/{id}/inbox/{task}/cancel` | |
| `box_read_result` | `GET /v1/results/{task}?token=` | needs the grant token passed in |
| `box_list_outbox` | `GET /v1/agents/{id}/outbox?since=` | cursor param |
| `box_ack_result` | `POST /v1/agents/{id}/outbox/{task}/ack` | |
| `box_get_agent_card` | `GET /.well-known/agent-card.json` | discovery helper |

**Deliberately NOT tools** (wrong shape for a synchronous tool call):
- `claim` — claiming is a worker-loop primitive (long-poll, lease, heartbeat); exposing it
  as a tool invites an LLM to "hold" a lease across turns it doesn't control. Workers use
  the native API/`franky_box_client`.
- `heartbeat`, `input-required` — lifecycle calls that belong to the worker harness, not
  an LLM's tool loop.
- `complete`/`fail` — a tool-LLM posting results on a worker's behalf breaks the
  worker-loop ownership model. (Revisit if a use case emerges: e.g. "agents-as-tools"
  where the MCP *client* is the worker.)

## 3. Transport & protocol requirements (2026:7:28 spec)

- **Streamable HTTP**: a single `/mcp` POST endpoint; each request is one POST; the
  response is JSON or an SSE stream scoped to that request. No `initialize` handshake
  (removed in the stateless-core revision), no `Mcp-Session-Id`.
- Each request carries protocol version + capabilities in `_meta`; any instance behind a
  load balancer can answer (stateless core).
- **JSON-RPC 2.0** framing: `tools/list` → tool schemas; `tools/call` → dispatch.
- Optional `server/discover` support.
- **Auth**: OAuth2/Client-ID-Metadata-Document or API-key header — franky-box's admin
  token maps cleanly to an API-key scheme; per-agent secrets could scope tools to one
  agent's view (filter `agent_id` from all tool inputs).

## 4. Implementation sketch (Zig, in this repo)

No new dependencies — the pieces already exist:

```
src/mcp.zig          — JSON-RPC 2.0 dispatcher + tool schemas
                       (tools/list, tools/call; std.json for schema gen)
src/mcp_tools.zig    — one function per tool → thin call into Server/store
server.zig           — route: POST /mcp  (Streamable HTTP)
```

1. `POST /mcp` route in `handleWithPath` → `mcp.handleRequest(self, body)`.
2. `mcp.handleRequest` parses JSON-RPC (`method`, `params`, `id`), dispatches:
   - `tools/list` → static JSON array of the 7 tool descriptors (name, description,
     inputSchema as JSON Schema).
   - `tools/call` → map `name` → `mcp_tools.f(self, params)`; return `content: [{type:"text", text: …}]`
     or `isError: true` with the error text (MCP convention).
   - `notifications/*`, `ping` → minimal handling.
3. Auth: reuse `requireAdmin` (admin token = full box view) or per-agent secret (scoped).
4. Everything else (retries, leases, retention) is untouched — the facade is read/dispatch-only.

Estimated effort: **2–3 days** including tests (JSON-RPC framing, tool round-trips against
a live store, auth).

## 5. Test plan

- Unit: JSON-RPC parse/format edge cases (id types, notifications without id).
- Integration: `tools/list` shape; `box_dispatch_task` → `box_get_task` → `box_read_result`
  happy path through the real store; auth rejection (401 on bad token); idempotency key
  passthrough.
- Spec checks: stateless core (no session id required), version in `_meta` accepted.

## 6. Registry listing (optional, after the facade)

Register a public franky-box deployment in the MCP Registry:
`io.github.fr12k/franky-box` namespace with `server.json` metadata (tools, auth schemes,
link to the admin UI). Private deployments self-host the registry entry or skip it.

## 7. Non-goals

- **Not** an A2A endpoint mapping (that's the larger interop play — see
  `AGENT_INTEROP_RESEARCH.md` P1; A2A's stateful Task model is the better substrate for
  full protocol-level interop).
- **Not** MCP sampling/elicitation client features — franky-box has no LLM of its own.
- **Not** exposing claim/complete as tools (see §2 rationale).
