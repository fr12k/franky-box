# Agent Interconnection Research & Roadmap for franky-box

**Date:** 2026-11-08
**Status:** Research summary — **P0–P2 IMPLEMENTED** (see §4 below); P3 + MCP facade remain open
**Scope:** (1) audit of the current franky-box docs vs. code, (2) survey of how LLM agents are connected across the industry, (3) what franky-box should implement next.

---

## 0. Implementation status (2026-11-08)

The P0-P2 items below shipped on the `feat/agent-interop-p0-p2` branch:

- **P0:** grant-token **verification** (`verifyGrantTokenFor`, constant-time — `/v1/results` no
  longer a stub) and a real expiry clock (tokens were previously generated with
  `now_seconds=0`, dead on arrival); **heartbeat** lease extension
  (`POST /v1/agents/{id}/inbox/{task}/heartbeat?extend=N`); **persisted agent registry**
  (agents table, `loadAgents()` on startup — registrations survive restarts); README + doc
  status notes.
- **P1:** **cancel** with terminal-state fencing (late complete/fail rejected);
  **GetTask** (`GET /v1/agents/{id}/tasks/{task}`) with A2A-style state names;
  **Agent Cards** (`GET /v1/agents/{id}/card`, `GET /.well-known/agent-card.json`);
  **webhook push** (`/v1/webhooks` CRUD; signed `X-Franky-Box-Signature` delivery on
  completed/failed/canceled — bounded connect, fire-and-forget).
- **P2:** **priority** claims (`ORDER BY priority DESC, rowid ASC`); **scheduled dispatch**
  (`available_at`); **DAG dependencies** (`blocked_by` — strict: a missing dependency id
  blocks); **idempotency keys** (producer retry dedupe; unique partial index, also on the
  archive); **human-in-the-loop** (`input-required` parks the task, `input` resumes);
  poison-pill claims now return 204 instead of handing the poisoned row to the agent.

Still open: P3 (capability routing, SSE progress, multi-tenancy, audit trail, liveness)
and the optional **MCP facade** — see `MCP_FACADE_PLAN.md`.

---

## Part 1 — Repo audit: are the documents up to date?

Verified against upstream `fr12k/franky-box` @ `548302d` (fresh clone + `zig build test` passes: unit + integration).

| Document | Last touched | Up to date? | Findings |
|---|---|---|---|
| `README.md` | 2026-08-08 | ❌ **Empty** | Contains only `# franky-box`. No install, no API reference, no examples. Biggest doc gap. |
| `RETENTION.md` | 2026-09-08 | ✅ Accurate | Matches code: `consumed_at`, ack/ack-all, 1h grace, 90d safety net, `tasks_archive` same-file move, partial indexes, `?since=` lexicographic cursor. Header has a typo: `**Date:** 2026:9:08` (colons instead of dashes, inconsistent with its own URL-decode example). |
| `INBOX_OUTBOX.md` | 2026-09-08 | ⚠️ Partially | v0 design doc. Retention §D (7-day hard purge) is **superseded** by RETENTION.md (stated). §2 "Central Routing" (shortest-queue-for-action dispatch) is **designed but NOT implemented**. Trailing chat artifacts ("Should we write a minimal 30-line Python implementation…") should be cleaned up. |
| `AUTH.md` | 2026-08-08 | ❌ Aspirational | Specifies producer policies (public/team-scoped/signed), per-task grant-token **verification**, revocation, and multi-tenant `team_id` isolation. Code reality: `POST /v1/agents` returns `team_id: "default"`; `handleGetResult` is a **stub** — it only checks that `?token=` exists and replies `{"status":"result_available"}` without validating the HMAC grant (`generateGrantToken` exists; **no `verifyGrantToken` was ever written**). Tenant is hardcoded `"default-team"` everywhere. Admin token defaults to `admin-token-change-me`. |
| `INTEGRATION_PLAN.md` | 2026-08-08 | ⚠️ Stale-ish | Describes the franky-agent `--mode worker` side (not this repo's code). Endpoint list still matches, but it predates the retention/ack model (no ack endpoints mentioned, "passive purge → removes tasks >7 days" is outdated). Its client-path `src/coding/box_client.zig` lives in this repo as `src/box_client.zig`. |

**Code facts the docs don't state anywhere (README should):**
- Single `tasks` table; **nullability is the state machine** — `output IS NULL` = inbox, `output IS NOT NULL` = outbox; `consumed_at IS NULL` = awaiting consumer.
- Atomic claim: single `UPDATE … WHERE task_id = (SELECT … WHERE output IS NULL AND (locked_until IS NULL OR …)) RETURNING …` — one winner, no lock table. Visibility timeout **300 s**, poison pill at `try_count >= 3`.
- Zig 0.17, vendored SQLite amalgamation (WAL), htmx 4 admin UI embedded at compile time (no CDN). Exports two modules: `franky_box` (server+store) and `franky_box_client` (client-only, no SQLite).
- **Agent registry is in-memory only** — agents registered via `POST /v1/agents` vanish on restart. `dispatch` hardcodes `agent-0` + `action="process"`.
- No LICENSE file.

---

## Part 2 — How are LLM agents connected? (landscape, late 2026)

### 2.1 The protocol stack has consolidated

The fragmented 2024–25 "agent protocol wars" are over. A clean division of labor emerged, and essentially everything else merged into A2A:

- **MCP** (Anthropic → Linux Foundation; spec `2026:7:28`) — **agent↔tools/data**. Stateful→stateless core (no initialize handshake), Streamable HTTP, tasks extension for long-running ops, Registry, MRTR elicitation. Sampling deprecated. The dominant "agent as MCP server / agents as tools" federated pattern.
- **A2A** (Google → Linux Foundation; **v1.0.0**, 2026-03) — **agent↔agent**. The de-facto standard for task delegation between opaque agents. IBM's ACP (BeeAI) merged in (Aug 2025); Cisco's AGNTCY/AIP became the surrounding infra (directory/identity/observability) rather than a competing wire format; Google ADK's chat-style "ACP" was abandoned in favor of A2A.
- **AG-UI** (CopilotKit, 1.0) — agent↔frontend event stream. Complementary.
- **ANP** — decentralized DID-based "internet of agents"; niche.
- Survey taxonomy (arXiv:2505.02279): MCP = tool tier, ACP = messaging tier, A2A = collaboration/task tier, ANP = decentralized-market tier.

### 2.2 A2A in one screen (what franky-box maps onto)

- **Agent Card** at `/.well-known/agent-card.json`: name, skills[], securitySchemes, capabilities (streaming, pushNotifications), interfaces.
- **Task**: server-generated `id`, `contextId` (groups related tasks), 9 states: `SUBMITTED, WORKING, INPUT_REQUIRED, AUTH_REQUIRED, COMPLETED, FAILED, CANCELED, REJECTED (+UNSPECIFIED)`. Terminal tasks are **immutable** — refinements become new tasks in the same context.
- **Message/Part/Artifact**: role'd parts (text/data/url), streamable artifacts.
- **Ops**: `SendMessage`, `SendStreamingMessage` (SSE), `GetTask`, `ListTasks` (cursor paginated), `CancelTask`, `GetAgentCard`, push-notification config CRUD (webhook URL + auth).
- **Auth**: OAuth2+PKCE/Device Code, API keys, mTLS — identity in HTTP headers, never in the payload.

**Mapping to franky-box** (near 1:1):

| franky-box today | A2A concept |
|---|---|
| agent registry (in-memory map) | Agent Card / directory |
| `tasks` row | Task |
| `output IS NULL` (inbox) | SUBMITTED |
| claim (locked_until set) | WORKING (+lease) |
| complete / fail | COMPLETED / FAILED |
| poison pill (try_count≥3) | FAILED via DLQ |
| `workstream_id` | `contextId` (exact analog) |
| ack / consumed_at | consumption receipt (delivery≠completion) |
| grant_token (stubbed) | push-notification config auth |
| `?since=` cursor | ListTasks pagination |

### 2.3 Architectural patterns (what a mailbox buys you)

Direct patterns: orchestrator–worker/supervisor, hierarchical teams, sequential pipelines, handoffs/swarm routing, group chat, debate/ensemble (MoA), blackboard, pub/sub bus, shared scratchpad. Framework reality check: OpenAI Agents SDK & Claude Code subagents are **in-process** (handoffs or agents-as-tools); LangGraph communicates via **shared checkpointed graph state** (interrupt/resume); CrewAI passes task outputs as context with `expected_output` contracts; AutoGen-core is the clearest **distributed pub/sub** precedent (topics, subscribe/publish over gRPC). Products (Manus wide-research, Devin subagents, Copilot /fleet) converge on orchestrator + isolated-context subagents + parallel fan-out.

Key queue semantics that must hold (from SQS/NATS/Temporal practice):
1. **Claim must be a single atomic UPDATE…WHERE** — franky-box already does this correctly.
2. **"A claim is a lease, not ownership"** — lease must exceed worst-case processing time, or you need heartbeats. LLM tasks regularly exceed franky-box's fixed 300 s → **guaranteed duplicate execution today**.
3. **At-least-once delivery; idempotent handling** — idempotency keys recommended.
4. **Ack ≠ complete** — franky-box has this right (claim / complete / ack are distinct).
5. Fencing: acking should reference the claim generation, not just task id.

Durable-execution engines (Temporal/Restate/Inngest) provide the *other half* — resume-from-checkpoint, sagas, human-in-the-loop waits. A mailbox provides ownership transfer, not resumption; agents own their scratchpad. Keep this boundary explicit.

Academic guidance: graph-structured communication beats star/chain/tree on complex open-ended tasks (MultiAgentBench); topology should be adaptive (GPTSwarm, AMAS); structured intermediate artifacts beat free-form chat (MetaGPT); parallel ensembles with aggregation scale reliably (MoA, Agent Forest).

### 2.4 Convergent requirements across frameworks/products/runtimes

Agents-as-services convergence (NATS native agent protocol 2026: discovery + typed status chunks with **mandatory ack-first** + heartbeats/liveness; Kagent: k8s agents + Postgres task store decoupled from agent lifecycle; BeeAI Agent Stack: auto-expose any framework agent as A2A service; AGNTCY Directory v1.0: capability-based discovery with signed records). Everyone lands on the same ten requirements:

1. **Agent registry with capability metadata** (not a blind queue) — route by skill, not just name
2. **Task schemas / output contracts** (CrewAI `expected_output`, A2A skills)
3. **Full task lifecycle**: + cancel, timeout/lease-expiry, retry — not just inbox/outbox
4. **Durable state decoupled from agent lifecycle** (survive restarts, resume)
5. **Streaming progress + callbacks** (SSE status on claimed tasks, partial artifacts)
6. **Human-in-the-loop state** (A2A `INPUT_REQUIRED` + inject-input op)
7. **Result ack + delivery receipts** (franky-box's strongest existing feature)
8. **Transport-layer identity, scoped claims, audit trail** (IETF draft-klrc-aiagent-auth: OAuth2 client-cred/SPIFFE/mTLS; identity never in payload; guardrail on result acceptance)
9. **Liveness/heartbeats** (dead agents' tasks re-queue)
10. **Observability**: correlation ids (taskId/workstreamId) threaded through; OTel-friendly

---

## Part 3 — What franky-box should implement (prioritized)

The v0 philosophy (single table, nullability as state, no cron, piggybacked sweeps) is validated by this research — plandb ("tasks are the universal primitive") and A2A both confirm the model. Keep it. The gaps are almost all *additive*.

### P0 — Correctness & trust (before any new features)

1. **Implement grant-token verification** (`verifyGrantToken` + real `/v1/results/{id}` handler). Today any string in `?token=` returns "result_available". This is the single biggest security gap; AUTH.md already specifies the design (HMAC, expiry, revocation).
2. **Lease heartbeat/extension** — `POST /v1/agents/{id}/inbox/{task_id}/heartbeat` (or accept `lease_seconds` on claim) extending `locked_until`. Without it, any task >300 s gets double-executed. This is a known-broken invariant, not an enhancement.
3. **Persist the agent registry** — move agents to a `agents` table (secret hash, name, created_at, capabilities). Registration currently vanishes on restart. Also stop generating `agent-{count}` ids (collision after deletions).
4. **README.md** — document the API, the nullability model, retention, admin UI, module imports, env vars. (Add a LICENSE file too.)

### P1 — Interop (the ecosystem decision)

5. **Adopt A2A task-state vocabulary + Agent Card semantics.** Serve `/.well-known/agent-card.json` per box (skills, securitySchemes, capabilities); expose `GetTask`/`ListTasks`/`CancelTask`-shaped endpoints. Names align for free: workstream ↔ contextId. This is the highest-leverage interop decision — it makes franky-box pluggable by ADK/BeeAI/LangGraph `RemoteA2aAgent` ecosystems.
6. **Cancel** — `POST /v1/agents/{id}/inbox/{task_id}/cancel` (admin/producer). A2A has it; long-running agent work needs it.
7. **Webhook push notifications** (A2A `CreateTaskPushNotificationConfig` analog): a `subscriptions` table (task or agent → URL + secret); on complete/fail, POST the status event with HMAC + retries. Turns polling consumers into event-driven ones without giving up the poll fallback.

### P2 — Primitives that unlock the hard patterns

8. **Dependencies/DAG** — `blocked_by` (JSON array of task ids) + readiness as part of the claim WHERE clause (or a SQL VIEW). Unlocks fan-out/fan-in (MoA aggregation), pipelines with joins, and hierarchical workstreams **without a central orchestrator**. The single most valuable new primitive per the research.
9. **Priorities** — `priority INTEGER` + `ORDER BY priority, rowid` in claim. One-line schema change; real workloads need it.
10. **Human-in-the-loop state** — `POST …/input-required` parks the task (lease released, state visible to admin UI) + `POST …/{id}/input` to resume. Mirrors A2A `INPUT_REQUIRED`.
11. **Idempotency key** on dispatch (dedupe producer retries — at-least-once is already the delivery model).
12. **Scheduled tasks** — `available_at` column; claim only when `datetime(available_at) <= now`. Enables cron-style agent wake-ups (A2A scheduler extension analog).

### P3 — Larger (only if the product needs them)

13. Capability-based routing (route by skill instead of hardcoded `agent-0`) — completes the INBOX_OUTBOX.md §2 design.
14. SSE progress/status events on claimed tasks (streaming `status` updates).
15. Real multi-tenancy (`team_id` end-to-end) — currently hardcoded `"default-team"`.
16. Agent liveness/heartbeats + dead-worker requeue accounting.
17. Audit trail table (who dispatched/claimed/completed/acked, when) — cheap, and required by the enterprise-auth posture.

### Explicitly out of scope (documented boundary)

- **Durable execution / resume-from-checkpoint** — agents own their scratchpad; franky-box transfers ownership, it doesn't replay sessions.
- **Exactly-once** — impossible; provide at-least-once + idempotency support and document it.
- **MCP server surface** — optional later: wrap `dispatch`/`claim` as MCP tools so any MCP client can drive the mailbox. A2A-style task model is the right primary substrate; MCP is a convenience facade.

---

## Sources

- A2A spec v1.0: https://a2a-protocol.org/latest/specification/ · life of a task: https://a2a-protocol.org/latest/topics/life-of-a-task/ · enterprise: https://a2a-protocol.org/latest/topics/enterprise-ready/
- MCP 2026-07-28: https://blog.modelcontextprotocol.io/posts/2026-07-28/ · registry: https://modelcontextprotocol.io/registry/about
- Interop survey: https://arxiv.org/abs/2505.02279 · MoA: https://arxiv.org/abs/2406.04692 · AutoGen: https://arxiv.org/abs/2308.08155 · MetaGPT: https://arxiv.org/abs/2308.00352 · GPTSwarm: https://proceedings.mlr.press/v235/zhuge24a.html · MultiAgentBench: https://arxiv.org/abs/2503.01935 · More-agents: https://arxiv.org/abs/2402.05120 · CAMEL: https://arxiv.org/abs/2303.17760
- Queue semantics: https://aws.amazon.com/sqs/faqs/ · https://stackbook.io/patterns/competing-consumers · https://design.babushkai.com/05-messaging/01-message-queues
- Durable execution: https://kai-waehner.de/blog/2025/06/05/the-rise-of-the-durable-execution-engine-temporal-restate-in-an-event-driven-architecture-apache-kafka/ · https://docs.restate.dev/use-cases/ai-agents
- Mailbox architecture: https://baibylon.com/page/agent-mailbox-architecture · plandb: https://github.com/Agent-Field/plandb
- NATS native agent protocol: https://nats.io/blog/nats-native-protocol-for-ai-agents/ · AGNTCY Directory: https://blogs.agntcy.org/technical/2026/02/19/dir-v1.html · Kagent: https://github.com/kagent-dev/kagent · BeeAI: https://framework.beeai.dev/modules/serve
- Agent auth: https://www.ietf.org/archive/id/draft-klrc-aiagent-auth-02.html
- Frameworks: https://openai.github.io/openai-agents-python/sessions/ · https://docs.langchain.com/oss/python/langgraph/checkpointers · https://docs.crewai.com/edge/en/concepts/tasks · https://adk.dev/a2a/ · https://code.claude.com/docs/en/sub-agents · https://www.anthropic.com/research/multi-agent-research-system
