# franky-box: Inbox/Outbox Task Dispatch Design

_A third-party inbox/outbox service for asynchronous **work dispatch & result
delivery** between agents (and humans), where one agent's outbox can be read
by another agent instead of a human._

> This is a design document, not an implementation. It sharpens the idea from
> a "generic email inbox" into a **task-oriented, 3rd-party, inbox/outbox**
> pattern that fits `franky`'s existing tenancy model (`IsolationContext`,
> `agent_id`).

---

## 1. What this is (and is not)

The user clarification is the spec. Three constraints dominate:

1. **Not for full conversations.** This is *not* an AgentMail-style threaded
   conversation channel. No multi-turn back-and-forth, no thread state.
   **A task flows, completes, and the result is delivered.** One-way-ish,
   fire-and-forget-with-result.

2. **Third-party service.** The inbox/outbox is an external HTTP service that
   agents reach over the network — not an in-process library. This is the
   "AgentMail" shape from the original idea, but for **internal agent
   coordination**, not human email. Agents *register*, get addressed by name,
   and the service holds the queue.

3. **An outbox is a consumable.** The key clarifying insight:
   > "Still an outbox of one agent can be read by a different agent instead
   > of a human."

   This flips the mental model. An agent has **two views**:

   - **Inbox** = work *assigned to me* → I consume, process, produce output.
   - **Outbox** = work *completed by me* → anyone (human **or another agent**)
     can read it.

   The outbox is both a **delivery** mechanism (upline: "here's your result")
   and a **publish** bus (downline: "agents, here's what happened").

```
                    ┌─────────────────────────────┐
    Human / Client  │        franky-box          │   Agent B (consumer)
    ── POST task ─► │  ┌────────┐   ┌────────┐   │
                    │  │ Inbox  │──►│ agent  │───┤
                    │  │ (A)    │   │ A      │   │
                    │  └────────┘   │        │   │
                    │               │ Outbox │───┼──► Agent C / Human
                    │               └────────┘   │       (reads results)
                    └─────────────────────────────┘
```

---

## 2. Core model: Task, not thread

Because it's task-oriented, the central object is a **Task**, and the unit of
conversation is `task_id` — not `thread_id`. A task has a **lifecycle**, which
replaces conversation threading:

```
submitted → accepted → in_progress → {{ completed │ failed │ rejected }}
```

| State        | Meaning                                              | Who writes it |
|--------------|------------------------------------------------------|---------------|
| `submitted`  | Task dropped into an agent's inbox; not yet picked up | Producer      |
| `accepted`   | Agent claimed it; exclusive ownership begins          | Agent         |
| `in_progress`| Agent is actively working                             | Agent         |
| `completed`  | Result written to outbox; done                        | Agent         |
| `failed`     | Agent errored; error + partial result in outbox       | Agent         |
| `rejected`   | Agent declined (schema / capability / payload mismatch) | Agent       |

A task is **owned by one agent at a time** while active (no interleaving —
this is the "conversation model" not the "mailbox model", but scoped to a
single task). It resolves to exactly one terminal state.

This is the sharpening that the original AgentMail sketch lacked: **the
`thread_id` becomes `task_id` + `status`**, and "deliver result to outbox" is
an explicit state transition instead of an implicit reply.

---

## 3. The API — inbox for work, outbox for delivery

All endpoints are addressed by agent name. Auth is a per-agent token.

### Registry / addressing

```
POST   /v1/agents
  body: { "name": "billing-agent", "capabilities": ["invoice.scan", "charge.run"] }
  →    { "agent_id", "token" }            # token is shown once

GET    /v1/agents?capability=charge.run    # discovery: route by skill, not name
GET    /v1/agents/{name}                  # resolve name → id / health
```

### Inbox (work assigned *to* an agent)

```
POST   /v1/agents/{name}/inbox            # producer submits a task
  body: {
    "task_type": "invoice.scan",
    "payload": { "uri": "s3://in/pdf/102.pdf" },   // or a blob/URI reference
    "priority": 5,                                  // optional, default 5
    "ttl": "2026-08-20T00:00:00Z",                  // optional expiry
    "schema": "invoice.scan.v3",                    // versioned contract
    "idempotency_key": "k-<uuid>"                   // dedupe resubmits
  }
  →    { "task_id", "status": "submitted" }

GET    /v1/agents/{name}/inbox             # poll for tasks                   (pull)
POST   /v1/agents/{name}/inbox/claim       # atomically claim one task        (pop)
GET    /v1/agents/{name}/inbox/{task}/status
```

- **Pull, not just webhook**: an agent may be off / sleeping. `claim` is the
  primary intake — the agent wakes, pulls, acks, goes back to sleep. Webhooks
  remain an optional adapter on top.
- **Claim is exclusive and idempotent**: only one agent-process claims a task;
  `task_id` guards the state transition so a duplicate claim is a no-op.

### Outbox (results delivered *by* an agent)

```
POST   /v1/agents/{name}/outbox/{task_id}/complete
  body: { "result": { "pages": 3, "total": "$120.50" } }
  →    { "task_id", "status": "completed" }

POST   /v1/agents/{name}/outbox/{task_id}/fail
  body: { "error": { "code": "UNREADABLE_PDF", "message": "..." },
          "partial": { "pages_read": 2 } }

POST   /v1/agents/{name}/outbox/{task_id}/reject
  body: { "reason": "capability 'invoice.scan' not supported by this agent" }
```

### Reading an outbox — the "another agent" consumer path

```
GET    /v1/agents/{name}/outbox                     # list completed results
GET    /v1/agents/{name}/outbox?since=<cursor>      # incremental consume
GET    /v1/agents/{name}/outbox/{task_id}           # fetch one result

POST   /v1/agents/{name}/outbox/{task_id}/ack       # consumer marks delivered
```

This is the crux of the clarified idea: **agent C consumes agent B's outbox
exactly as a human would.** The outbox is a shared, ordered result stream.
`ack` gives consumer-side idempotency without breaking the producer flow.

---

## 4. Routing layer — the real value

Like the internal design, the third-party service earns its keep in **routing**,
but here routing is about **task dispatch**, not conversation handoff:

1. **Name → service resolution** (registry): producers say `"billing-agent"`,
   the service resolves it. Discovery-by-capability lets a producer say
   `"whoever handles charge.run"` instead of hardcoding a name.

2. **Delivery semantics** — the part naive email gets wrong:
   - **At-least-once** on task delivery; `task_id` + idempotency make
     consumer retries safe.
   - **Claim-based exclusivity** prevents double-processing of one task.
   - **Dead-letter outbox** for poison tasks: `GET /v1/agents/{name}/deadletters`.
   - **Expiry** (`ttl`): tasks expire instead of rotting in an inbox.
   - **Schema pinning** (`schema` field): an agent can reject tasks whose
     payload contract it doesn't understand (`reject` transition), instead of
     guessing.

---

## 5. Tenancy — reuse `IsolationContext`

`franky-memory` already models multi-agent tenancy via `IsolationContext`
(`team_id`, `agent_id`, `user_id`, ...). franky-box should adopt the same
naming so the two systems agree about *who an agent is*:

- Every task is scoped to a **team** (`team_id`) so isolated teams don't read
  each other's inboxes/outboxes.
- The **agent** is the mailbox owner (`agent_id` = the inbox/outbox name).
- **`user_id`** scopes tasks to the end user paying / owning the work.

```
task = {
  "team_id": "acme",
  "agent_id": "billing-agent",      // = the inbox/outbox owner
  "user_id": "user-7",
  ...
}
```

This keeps franky-box addressable in the same vocabulary as franky-memory, so
an agent can correlate *a task it did* (franky-box) with *the memory it
learned from that task* (franky-memory) by a shared `agent_id`/`task_id`.

---

## 6. Authz — the "token" refined

The original idea said "maybe a token that allows to send requests." franky-box
makes it **structured and per-resource**, not one shared key:

- **Per-agent credential**: `billing-agent`'s token lets it `claim` its own
  inbox and write its own outbox. It cannot read another agent's outbox.
- **Per-task token** (optional, powerful): an agent's *result* carries a
  single-use token that grants a specific downstream consumer read access —
  a capability-safe "here's your delivered result" handoff.
- **Read-scoped tokens for consumers**: agent C gets a token limited to
  `GET /v1/agents/billing-agent/outbox` — enough to consume results, not
  enough to impersonate the producer.
- **Scope = team + agent + resource** so a stolen token is contained.

This is a real improvement over AgentMail/email, which has no authz model at
all.

---

## 7. Implementation notes (if we build it)

Two viable shapes, given it's a Zig monorepo (`franky-memory` already links
SQLite — `vendor/sqlite3.c`):

### Option A — Embed alongside franky-memory (fastest to start)
Add an `InboxOutboxStore` beside `SqliteStore` in the same SQLite file:
`tasks`, `inbox`, `outbox` tables with `status` + `agent_id` indexes. Serving
it over HTTP is a thin FastAPI/Zig-ZigHTTP adapter that maps the REST verbs
above onto store queries. Reuses the existing `Db` wrapper and SQLite binding
already in `src/embedded/`.

### Option B — Standalone franky-box HTTP service
A separate small service owning the queues, exposing the `/v1/**` API, backed
by its own SQLite/Postgres. Agents are HTTP clients. This is the "true"
third-party version the idea asks for, and matches the outbox-consumed-by-
another-agent flow most cleanly (no assumption both agents share a process).

Recommended: **start with Option A behind an HTTP adapter** to validate the
lifecycle, then extract to Option B once the semantics are stable. The API
(external contract) stays the same either way — which is the point of making
it a *service-shaped* design.

---

## 8. Sharpening questions resolved

| Original idea                      | franky-box answer                                   |
|------------------------------------|-----------------------------------------------------|
| "thread_id for context"            | `task_id` + lifecycle/state; no threads             |
| "one-way blast vs threaded"        | It's **one task → one result**; outbox is a consume stream |
| "inbox/outbox API"                 | `/inbox` = claim work; `/outbox` = deliver result   |
| "send to other agents by name"     | Registry + per-agent token + capability discovery   |
| "outbox read by an agent"          | **Yes** — outbox `GET`+`ack` is the cross-agent path |
| Where does it live?                | 3rd-party HTTP service (Option B), modeled after AgentMail but task-oriented |

---

## Phase 1 deliverable summary

If we move forward, the first concrete slice is:

1. `types.zig` + new `Task` / `TaskState` / `TaskResult` structs (mirroring
   `MemoryType`, `IsolationContext` style).
2. `test/` covering the **state machine**: `submitted → claimed → completed /
   failed / rejected`, idempotent claim, idempotent complete, outbox-audit.
3. SQLite schema for `tasks` + `inbox` + `outbox` in `sqlite_store.zig`
   (or a sibling store file).
4. A minimal HTTP adapter mapping the `/v1/**` verbs above.

Design is pinned. Next steps focus on **Option B (standalone 3rd-party service)** with two critical design refinements:

### Refinement A: Chain / Handoff vs Fan-Out
- **Model**: Default to **Chain / Handoff**. Agent A's completed task result is intended for a specific downstream consumer (Agent B or human) authorized via a per-task read token or team tenancy.
- **Consumption**: The outbox is a durable result stream, but consumption uses `ack` to mark delivery. Once acked by the designated consumer, the result transitions to historical archive.

### Refinement B: Task Payload & Result Contract
The `payload` and `result` fields follow a strict content-addressed union:
1. **Inline JSON**: For small payloads / results (`<= 64KB`), stored directly in SQLite.
2. **Reference URI**: For large assets (PDFs, checkpoints, datasets), a URI string (`s3://`, `memory://`, `https://`) accompanied by an optional SHA-256 integrity hash (`sha256:...`).

---
