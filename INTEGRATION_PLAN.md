# Integration Plan: franky-box → franky Agent Workflow

**Author:** franky-agent  
**Date:** 2026-08-08  
**Status:** Draft  

---

## 1. Goal

Integrate `franky-box` (the single-table SQLite task inbox/outbox queue) into the `fr12k/franky` agent workflow so that agents can **dispatch tasks, claim work, complete/fail tasks, and stream results** through a shared persistent queue, enabling multi-agent orchestration.

---

## 2. Current Architecture (franky)

- **`agent_memory`** is already a dependency (`build.zig.zon`) — provides L1 memory storage backed by SQLite + FTS5.
- `fr12k/franky` uses JSON-RPC 2.0 over stdio (LSP-style framing) via `src/coding/rpc.zig`.
- Agents run a stateful `Agent` loop (`src/agent/agent.zig`) that drives LLM calls, tool execution, and turn management.
- Tools are registered in `src/coding/tools/` (e.g., `memory_save.zig`, `memory_search.zig`).
- Orchestrator (`src/coding/orchestrator.zig`) handles out-of-band registration with a remote server.

---

## 3. What franky-box Provides

| Capability | Endpoint / API | Storage |
|---|---|---|
| Dispatch task | `store.dispatch(...)` | SQLite `tasks` table |
| Claim task (atomic) | `store.claim(...)` | SQLite with visibility timeout, max retries |
| Complete task | `store.complete(...)` | Sets `output`, moves to outbox |
| Fail task | `store.fail(...)` | Sets error output, moves to outbox |
| Read outbox | `store.readOutbox(...)` | Returns completed tasks since timestamp |
| Passive purge | `store.purge()` | Deletes tasks >7 days old |
| HTTP API | `POST /v1/agents/{name}/inbox/claim`, etc. | Bearer auth + grant tokens |

---

## 4. Integration Approach

### Option A: Embed `franky-box` as a Library (Recommended)

Replace the current `agent_memory` dependency with `franky-box` (which already bundles SQLite + the tasks schema + the inbox/outbox vtable).

**Changes required:**

1. **`build.zig.zon`** — Replace `.agent_memory` dep with `.franky_box` pointing to `franky-agent/franky-box` (or `fr12k/franky-box` after PR merges).

2. **`src/coding/memory.zig`** — Refactor `MemoryState`:
   - Instead of a separate `agent_memory.SqliteStore`, create a shared `franky_box.SqliteStore` that holds **both** the `tasks` table (inbox/outbox) and the L1 memory tables (`l1_records`, `l1_fts`, etc.).
   - Both schemas can coexist in the same SQLite database file.
   - The `SqliteStore.init` in franky-box already creates the `tasks` table; we'd add schema creation for L1 memory tables alongside it (or keep the agent_memory schema creation but route it through the same `Db` handle).

3. **New module: `src/coding/task_queue.zig`** — Thin wrapper around `franky_box.Store`:
   ```zig
   pub const TaskQueue = struct {
       store: *franky_box.Store,
       agent_id: []const u8,
       tenant_id: []const u8,
       
       pub fn dispatch(...) !void
       pub fn claim(...) !?ClaimResult
       pub fn complete(...) !bool
       pub fn fail(...) !bool
       pub fn readOutbox(...) ![]OutboxResult
   };
   ```

4. **Tool registration: `src/coding/tools/task_*.zig`** — Add new agent tools:
   - `task_dispatch` — `dispatch(agent_id, action, payload)` — let an agent push work to another agent's inbox.
   - `task_claim` — `claim()` — claim the next available task for this agent.
   - `task_complete` — `complete(task_id, output)` — mark a task as completed.
   - `task_fail` — `fail(task_id, error_json)` — mark a task as failed.
   - `task_read_outbox` — `read_outbox(since)` — stream completed tasks.

5. **Guardrail: `src/agent/guardrails/task_guardrail.zig`** (optional) — Remind the agent to claim tasks or complete pending ones before finishing a session.

6. **HTTP API mode** (separate binary or optional feature) — The existing HTTP server in `franky-box` can be compiled as a standalone binary (`zig build`) or linked into franky as a mode (`--mode http-server`).

### Option B: Use franky-box as a Sidecar Process

Run `franky-box` as a separate service (e.g., listening on `localhost:8080`). Agents communicate with it via HTTP calls from tool implementations.

**Pros:** Loose coupling, independent scaling, no library compatibility risk.  
**Cons:** Network latency, additional deployment complexity, port management.

**Recommendation:** Start with **Option A** (embed as library) for simplicity and zero network overhead.

---

## 5. Schema Coexistence

The `franky-box` tasks table and the `agent_memory` L1 tables need to live in the same database:

```sql
-- From franky-box (tasks table)
CREATE TABLE IF NOT EXISTS tasks (
    tenant_id TEXT NOT NULL,
    agent_id TEXT NOT NULL,
    task_id TEXT PRIMARY KEY,
    action TEXT NOT NULL,
    payload TEXT NOT NULL,
    output TEXT DEFAULT NULL,
    try_count INTEGER DEFAULT 0,
    locked_until TEXT DEFAULT NULL,
    completed_at TEXT DEFAULT NULL
);

-- From agent_memory (L1 records)
CREATE TABLE IF NOT EXISTS l1_records (
    record_id TEXT PRIMARY KEY,
    content TEXT NOT NULL,
    type TEXT NOT NULL,
    priority REAL DEFAULT 0.5,
    scene_name TEXT DEFAULT '',
    session_key TEXT DEFAULT '',
    session_id TEXT DEFAULT '',
    team_id TEXT DEFAULT '',
    task_id TEXT DEFAULT '',
    user_id TEXT DEFAULT '',
    agent_id TEXT DEFAULT '',
    version INTEGER DEFAULT 1,
    timestamp_str TEXT DEFAULT '',
    timestamp_start TEXT DEFAULT '',
    timestamp_end TEXT DEFAULT '',
    created_time TEXT DEFAULT '',
    updated_time TEXT DEFAULT '',
    metadata_json TEXT DEFAULT '{}'
);
```

Both schemas are additive and do not conflict.

---

## 6. Dependency Flow

```
franky binary
├── franky-box library
│   ├── src/sqlite.zig (C bindings to vendored sqlite3.c)
│   ├── src/sqlite_store.zig (tasks table + inbox/outbox operations)
│   ├── src/auth.zig (Bearer token validation, grant tokens)
│   └── src/server.zig (optional HTTP API — not needed for library mode)
├── agent_memory (can be removed; L1 schema moved into franky-box)
└── agent task tools (task_dispatch, task_claim, etc.)
```

---

## 7. Implementation Steps

1. **Fork `fr12k/franky`** into `franky-agent/franky` (done).
2. **Create `franky-box` library release** — tag v1.0.0 and update `build.zig.zon` hash.
3. **Add `franky_box` dependency** to `fr12k/franky` `build.zig.zon`, replacing `agent_memory`.
4. **Merge SQLite stores** — unify db_path in `MemoryState` so both schemas share one connection.
5. **Implement `TaskQueue` wrapper** in `src/coding/task_queue.zig`.
6. **Implement task tools** (`task_dispatch`, `task_claim`, `task_complete`, `task_fail`, `task_read_outbox`).
7. **Register tools** in the agent tool registry.
8. **Add task guardrail** (optional) — nudge agents to claim/complete tasks.
9. **Test end-to-end** — two agents in the same process exchanging tasks.
10. **Document** — update AGENTS.md and README.md with the new capabilities.

---

## 8. Open Questions

- Should `franky-box` absorb the L1 schema from `agent_memory` entirely (true unified store), or keep both as separate modules sharing a `Db` handle?
- Should the HTTP API server be a separate binary (`franky-box-server`) or an optional `--mode http` in `franky`?
- Grant token verification: should the franky agent framework validate grant tokens internally, or delegate to the HTTP API?
- Multi-tenant routing: the current `franky-box` dispatch targets a single `agent_id`. Should franky's orchestrator manage queue balancing?

---

## 9. Risks

- **Breaking change** — removing `agent_memory` dep affects any downstream consumer of `franky` that already uses it.
- **Schema migration** — existing SQLite databases with only L1 tables need schema upgrade for the `tasks` table (adding it is safe, but test coverage needed).
- **Performance** — WAL mode handles concurrent reads/writes well, but the atomic claim query uses `RETURNING` which requires SQLite 3.35.0+ (already vendored: 3.53.4).

---

## 10. Conclusion

Embedding `franky-box` as a library into `fr12k/franky` is the recommended integration path. It adds multi-agent task orchestration with minimal overhead, reuses the existing SQLite infrastructure, and follows the existing pattern of `agent_memory` integration. Estimated effort: **3–5 days** for a single developer familiar with both codebases.