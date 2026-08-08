# Integration Plan: franky-box as Remote Task Queue for franky Agents

**Author:** franky-agent  
**Date:** 2026-08-08  
**Status:** Draft — v4 (cleaned, no complementary tools, no memory scoping)

---

## 1. Architecture Overview

**franky-box** is a **remote HTTP server** providing a shared task inbox/outbox queue (SQLite-backed).
**franky** (the agent) registers with `franky-box` at startup and acts as a **worker** — polling tasks from its inbox, executing them, and posting results to the outbox.

```
                        ┌─────────────────┐
                        │  franky-box      │
                        │  (remote server) │
                        │  tasks table     │
                        │  - inbox (op IS  │
                        │    NULL)         │
                        │  - outbox (op IS │
                        │    NOT NULL)     │
                        └────────┬────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              │ claim/comple     │                  │
              │ te/fail          │ dispatch          │
              ▼                  ▼                  ▼
        ┌───────────┐    ┌───────────┐    ┌───────────┐
        │ franky    │    │ franky    │    │ Human/CI  │
        │ (worker)  │    │ (worker)  │    │ (dispatcher)│
        │ agent-0   │    │ agent-1   │    │           │
        └───────────┘    └───────────┘    └───────────┘
```

---

## 2. Key Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Deployment | franky-box = **remote HTTP server** (standalone binary) | Shared queue for many workers; loose coupling |
| Worker level | **Harness-level** (`--mode worker`) | Session isolation per task, lifecycle, error recovery |
| Poll when? | **When idle** with exponential backoff (1s → 2s → max 30s) | Unattended autonomous operation |
| Session per task | **Yes** — fresh session per `task_id` | No context bleeding between unrelated tasks |
| Loop to reuse | **Proxy mode** loop (SSE + web UI) | User can watch agent work and intervene |
| User visibility | **Full** via web UI (`http://localhost:8081/`) | Abort stuck tasks, send follow-up prompts |
| Memory scoping per task | **Not needed** — use `memory_save` as-is | Agent already persists facts globally via existing tool |
| Complementary tools | **None** in this phase | Only harness-level polling; agent works on the task payload as its prompt |
| Event stream | **SSE /events** per task, plus heartbeats while idle | Web UI stays connected between tasks |

---

## 3. What franky-box Provides

| Capability | Endpoint / API |
|---|---|
| Register agent | `POST /v1/agents` → returns `agent_id` + `agent_secret` |
| Dispatch task | `POST /v1/tasks/dispatch` → inserts into agent's inbox |
| Claim task (atomic) | `POST /v1/agents/{name}/inbox/claim` → locks with 5min timeout |
| Complete task | `POST /v1/agents/{name}/outbox/{id}/complete` → moves to outbox |
| Fail task | `POST /v1/agents/{name}/outbox/{id}/fail` → sets error output |
| Read outbox | `GET /v1/agents/{name}/outbox` → stream completed tasks |
| Result via grant | `GET /v1/results/{id}?token=<grant>` → downstream consumers |
| Passive purge | Included in every claim/dispatch → removes tasks >7 days old |

---

## 4. Worker Mode: `--mode worker`

### 4.1 Startup

```
franky --mode worker \
  --inbox-server https://franky-box.example.com \
  --agent-id billing-agent \
  --agent-secret <secret> \
  --team-id acme-corp \
  --web-port 8081 \
  --model claude-sonnet-4-6 \
  --max-consecutive-failures 3
```

1. Authenticate with franky-box using `agent_id` + `agent_secret`
2. Bind a local HTTP/SSE listener on `127.0.0.1:8081` (identical to `--mode proxy`)
3. Enter the worker loop

### 4.2 Worker Loop

```
┌────────────────────────────────────────────────────────────────┐
│  Start proxy listener (port 8081)                              │
│  Open SSE /events stream                                       │
│                                                                │
│  while (true):                                                 │
│    task = claim(team_id, agent_id)                             │
│    if task:                                                    │
│      emit task_started on SSE                                 │
│      session = create_session(task.task_id)                    │
│      result = run_agent(session, task.payload, proxy loop)     │
│      if result.ok → complete(task.task_id, result.output)      │
│      else         → fail(task.task_id, result.error_json)      │
│      emit task_completed on SSE                                │
│    else:                                                       │
│      sleep(backoff)   # 1s → 2s → 4s → ... → 30s max         │
│      emit heartbeat on SSE                                     │
└────────────────────────────────────────────────────────────────┘
```

### 4.3 Session Per Task

Each `task_id` gets its own session (stored under `<FRANKY_HOME>/sessions/<task_id>/`):

```
sessions/
└── task-abc123/
    ├── session.json     # header: task_id, agent_id, model, started_at
    └── transcript.json   # agent conversation for this task
```

- The task `payload` becomes the **first user prompt** in that session
- When `finish_task` is called, the harness captures the final transcript state and posts to the outbox
- When the agent exceeds `max_turns` or errors, the harness posts a failure to the outbox

### 4.4 Memory Scoping

**Not needed.** The existing `memory_save` / `memory_search` tools already persist facts globally (L1 store). An agent working on a task can recall relevant context from memory regardless of which task created it.

### 4.5 Idle State

When no tasks are available, the web UI shows:

- Agent identity (`agent-id`, `team-id`)
- Connection status to franky-box
- Last completed task summary
- Number of tasks completed this session
- Current backoff interval
- Manual **Poll Now** button

SSE heartbeats every 15 seconds keep the UI connected:

```json
event: heartbeat
data: {"status":"idle","backoff_ms":4000,"tasks_completed":5}
```

### 4.6 User Intervention (via Web UI)

| Action | Endpoint | Effect |
|---|---|---|
| Abort | `POST /abort` | Cancels current task; harness posts `fail` to outbox |
| Send prompt | `POST /prompt` | Sends follow-up message to agent mid-task |
| Slash commands | `POST /command` | `/help`, `/clear`, `/model`, `/quit` etc. |

### 4.7 Complementary Tools

**None in this phase.** The agent receives the task payload as its initial prompt and works on it with the standard toolset (read, write, edit, bash, ls, find, grep, memory_save, memory_search). No `task_poll`, `task_status`, or `task_post_result` tools — the harness handles all task lifecycle transparently.

---

## 5. Implementation Steps (6 days)

### Phase 1: franky-box Client Library (1 day)

Create `src/coding/box_client.zig` — HTTP client wrapping franky-box REST API:
- `POST /v1/agents/{name}/inbox/claim` — poll for next task
- `POST /v1/agents/{name}/outbox/{task_id}/complete` — post success
- `POST /v1/agents/{name}/outbox/{task_id}/fail` — post failure
- Bearer token auth via `agent_secret`

Box types in `src/coding/box_types.zig` — lightweight JSON deserialization using existing `std.json`.

### Phase 2: Worker Mode (3 days)

Create `src/coding/modes/worker.zig`:
- CLI flags: `--inbox-server`, `--agent-id`, `--agent-secret`, `--team-id`, `--web-port`, `--max-consecutive-failures`
- Reuses `session.create` from existing session infrastructure
- **Reuses the proxy mode loop** (not print mode) — SSE event stream + web UI
- Idle polling with exponential backoff
- SSE heartbeat events while idle
- Accepts `/abort`, `/prompt`, `/command` for user intervention

Register `worker` mode in CLI argument parser and dispatcher.

### Phase 3: Integration & Testing (2 days)

- Start franky-box server, start `franky --mode worker`, dispatch tasks, open web UI
- Verify: task execution, outbox results, web UI streaming, abort intervention, reconnection
- Error handling: network failures, auth failures, agent loop crashes, max turn limits, consecutive failures exit
- Documentation: update README.md, AGENTS.md

---

## 6. franky-box Server Deployment

Franky-box runs as a standalone binary:

```bash
# Start server on port 8080 with persistent DB
franky-box 8080 /path/to/tasks.db
```

Production:
- TLS termination behind nginx/caddy
- Regular SQLite backups
- Agent registration via API or pre-seeded credentials

---

## 7. Open Questions

| Question | Decision |
|---|---|
| Should `--mode worker` support multiple concurrent task sessions? | **No** — one task at a time per worker. Scale horizontally with more workers. |
| What if franky-box is unreachable? | Exponential backoff; exit after `--max-consecutive-failures` |
| Task cancellation from franky-box side? | Future phase — v2 could add a `cancelled` state |
| Where is `--inbox-server` URL stored? | CLI flag or `FRANKY_INBOX_SERVER` env var |

---

## 8. Risks

| Risk | Mitigation |
|---|---|
| Agent context bleeding between tasks | Strict session-per-task; fresh agent state per claim |
| Worker crashes mid-task | Visibility timeout (5 min) releases task; `try_count` tracks retries; max 3 before poison pill |
| Network failures to franky-box | Exponential backoff; max consecutive failures exit |
| Long-running tasks block queue | One-task-per-worker; multiple workers scale horizontally |

---

## 9. Conclusion

The correct architecture is **franky-box as a remote task queue server**. Franky agents connect as **workers** via `--mode worker` that:

1. **Registers** with franky-box at startup
2. **Polls** for tasks when idle (exponential backoff when empty)
3. **Creates a fresh session** per `task_id` (no context mixing)
4. **Runs the agent** via the proxy mode loop (SSE stream + web UI)
5. **Posts results** to the outbox when done or stuck

**Memory scoping is handled by the existing `memory_save` tool — no changes needed.**  
**No complementary task tools in this phase** — the harness handles all lifecycle transparently.

Estimated effort: **6 days**.