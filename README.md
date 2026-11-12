# franky-box

A single-binary, SQLite-backed **task inbox/outbox queue for LLM agents** written in Zig.

Agents register, poll their inbox, claim tasks atomically, post results to the outbox, and consumers ack results. One `tasks` table is the whole state machine: `output IS NULL` = inbox, `output IS NOT NULL` = outbox, `consumed_at IS NOT NULL` = consumed. No background workers — retention sweeps piggyback on normal API calls.

```
                       ┌──────────────────────┐
   dispatch ──────────▶│ inbox  (output NULL) │──claim──▶ agent works
                       │ outbox (output set)  │◀─complete/fail─ agent posts
   consumer acks ─────▶│ archive (retired)     │
                       └──────────────────────┘
```

## Quick start

```sh
zig build
FRANKY_BOX_ADMIN_TOKEN=$(openssl rand -hex 24) ./zig-out/bin/franky-box
# listening on 0.0.0.0:8080
```

Open `http://localhost:8080/admin` for the built-in htmx admin UI (agents, inbox, outbox, archive, workstreams, dispatch form).

## Environment

| Var | Meaning | Default |
|---|---|---|
| `FRANKY_BOX_ADMIN_TOKEN` | Admin API token | `admin-token-change-me` (**change it**) |
| `FRANKY_BOX_PORT` | Listen port | `8080` |
| `FRANKY_BOX_UPDATE_REPO` | Repo override for `franky-box update` | `fr12k/franky-box` |
| `FRANKY_BOX_UPDATE_BASE_URL` | GitHub API base (tests) | `https://api.github.com` |

## API

Auth: agents use `Authorization: Bearer <agent_secret>`; admin routes use the admin token (header or `fb_admin_token` cookie).

### Agents
| Method & path | Description |
|---|---|
| `POST /v1/agents` | Register. Empty body → server-generated `agent-N` + secret (legacy). JSON body → named agent with metadata: `{"agent_id","secret","name"?,"skills"?,"card_url"?}` (secret ≥ 16 chars). **Registrations persist** in SQLite and survive restarts. |
| `GET /v1/agents/{id}/card` | Per-agent card (name, skills, card_url) — public discovery metadata. |
| `GET /.well-known/agent-card.json` | The box's own card (A2A-style), lists registered agents. |

### Tasks — dispatch
| Method & path | Description |
|---|---|
| `POST /v1/tasks/dispatch` | Simple dispatch to `agent-0` (legacy). Body = payload. |
| `POST /v1/tasks/dispatch-advanced` | Full dispatch (admin/producer). JSON: `{"agent_id","action"?,"payload"?,"workstream_id"?\|"workstream_name"?,"priority"?,"available_at"?,"blocked_by"?:[task ids],"idempotency_key"?}`. |

Advanced features: **priority** (higher first), **scheduled dispatch** (`available_at`, claimable only after), **DAG dependencies** (`blocked_by` — claim waits until every dependency has output; completed *and* failed both unblock; a missing id blocks), **idempotency** (same `idempotency_key` returns the original task instead of duplicating).

### Tasks — worker loop
| Method & path | Description |
|---|---|
| `POST /v1/agents/{id}/inbox/claim` | Atomic claim: one `UPDATE…RETURNING`. Locks the row for 300 s (visibility timeout), increments `try_count`, poison-pills at 3 attempts. 204 when nothing claimable. Priority-first ordering; skips cancelled, scheduled-future, dependency-blocked, and parked tasks. |
| `POST /v1/agents/{id}/inbox/{task}/heartbeat?extend=N` | **Extend the lease** (default 300 s, max 86400). Call periodically for tasks running longer than the lease — otherwise the task is re-queued and double-executed. |
| `POST /v1/agents/{id}/inbox/{task}/input-required` | **Human-in-the-loop**: agent parks the task (`{"query":"…"}`) and releases the lease; the task is hidden from claims. |
| `POST /v1/agents/{id}/inbox/{task}/input` | Deliver the answer (raw text or `{"input":"…"}`); re-locks the lease and appends the input to the payload. Producer/admin or agent auth. |
| `POST /v1/agents/{id}/inbox/{task}/cancel` | Cancel (unclaimed → finalized immediately; claimed → marked, next claim finalizes it; late `complete`/`fail` are fenced out). Optional `{"reason":"…"}`. |
| `GET /v1/agents/{id}/tasks/{task}` | Full task state incl. A2A-style `state` name (`submitted`/`working`/`completed`/`failed`/`canceled`). |
| `POST /v1/agents/{id}/outbox/{task}/complete` | Post a successful result. Response carries a signed **grant token**. |
| `POST /v1/agents/{id}/outbox/{task}/fail` | Post a failure (error JSON). |
| `GET /v1/agents/{id}/outbox?since=ts` | Read unconsumed results after `since` (cursor polling; `YYYY-MM-DD HH:MM:SS.fff`). |
| `POST /v1/agents/{id}/outbox/{task}/ack` | Consume one result (idempotent). |
| `POST /v1/agents/{id}/outbox/ack-all?before=ts` | Consume everything ≤ ts. |
| `GET /v1/results/{task}?token=…` | Read one result via **verified grant token** (HMAC-SHA256 over `task_id:expiry` with the agent's secret; constant-time compare). |

### Webhooks (push notifications)
| Method & path | Description |
|---|---|
| `POST /v1/webhooks` | Register (admin). `{"url","task_id"?,"agent_id"?,"secret"?}` — one of task/agent scope required; secret auto-generated when absent. |
| `GET /v1/webhooks?task_id=&agent_id=` | List subscriptions (admin). |
| `DELETE /v1/webhooks/{sub_id}` | Delete (admin). |

On every terminal transition (`completed`/`failed`/`canceled`) the box POSTs `{"event","agent_id","task_id"}` to matching URLs with headers `X-Franky-Box-Event: task.<event>` and `X-Franky-Box-Signature: sha256=<hex HMAC-SHA256 of the body>` (Stripe-style). Delivery is best-effort, bounded connect (3 s), fire-and-forget: failures are logged, never block the API call; **outbox polling remains the source of truth**.

## Retention (no cron)

Piggybacked on `dispatch`/`claim`/`ack` sweeps: consumed results retire to `tasks_archive` after a 1-hour grace window; unconsumed results after a 90-day safety net. Inbox items are never purged. Nothing is hard-deleted; `GET /admin/archive` lists the newest 500. See `RETENTION.md`.

## Design docs

| Doc | Content |
|---|---|
| `AGENT_INTEROP_RESEARCH.md` | Landscape research: A2A/MCP/protocol mapping + the P0–P2 roadmap this release implements. |
| `AUTH.md` | Credential model, grant tokens, (aspirational) producer policies & multi-tenancy. |
| `RETENTION.md` | Consumption/ack model and archive lifecycle. |
| `INBOX_OUTBOX.md` | The v0 single-table design (historical, largely implemented). |
| `INTEGRATION_PLAN.md` | The franky-agent `--mode worker` client side. |
| `MCP_FACADE_PLAN.md` | Planned optional MCP server surface. |

## Using as a library

The build exports two Zig modules:
- `franky_box` — full server + store (links the vendored SQLite).
- `franky_box_client` — lightweight client only (`box_client.zig` + `box_types.zig`, no SQLite).

```zig
// build.zig.zon dependency + fb_dep.module("franky_box_client")
const client = try franky.box_client.BoxClient.init(allocator, io, .{
    .base_url = "http://localhost:8080",
    .agent_id = "agent-0",
    .agent_secret = "…",
    .team_id = "default",
});
defer client.deinit();
const raw = try client.claim(); // ?ClaimedTask
```

## Development

```sh
zig build test        # unit + integration tests
zig build test-integration
zig build             # binary in zig-out/bin
```

Vendored SQLite (WAL, FTS5) — no system libsqlite3 needed; cross-compilation works. Zig 0.17-dev.

## Delivery semantics (read this before building a consumer)

- Delivery is **at-least-once**; handle claims idempotently (a crash after claim re-queues after the lease).
- **A claim is a lease, not ownership** — heartbeat long tasks, or accept re-execution.
- Terminal states are immutable: cancelled tasks reject late `complete`/`fail`; failed tasks stay failed.
- Idempotency keys dedupe *producer* retries; consumers dedupe by `task_id`.
