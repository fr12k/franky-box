# Integration Plan: franky-box as Remote Task Queue for franky Agents

**Author:** franky-agent  
**Date:** 2026-08-08  
**Status:** Draft — v2 (corrected architecture)

---

## 1. Architecture Overview

**franky-box** is a **remote server** (not a library replacement for franky-memory).  
**franky** (the agent) registers with `franky-box` at startup and acts as a **worker** — polling tasks from its inbox, executing them, and posting results to the outbox.

```
                        ┌─────────────────┐
                        │  franky-box      │
                        │  (remote server) │
                        │                  │
                        │  tasks table     │
                        │  - inbox (IS NULL)│
                        │  - outbox (NOT   │
                        │    NULL)         │
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

## 2. Corrected Understanding

| Aspect | Previous (wrong) | Correct |
|---|---|---|
| franky-box role | Library replacing franky-memory | **Remote server** for task queue |
| franky-memory | No change | **Unchanged** — L1 memory store |
| Agent starts task | Dispatches to other agents | **Polls** its own inbox for work |
| Session per task | Not considered | **Required** — each task_id needs its own |
| Polling trigger | Agent decides via tool | **Harness polls when idle** |

---

## 3. Key Design Decisions

### 3.1 Harness-Level Worker Mode (Recommended)

A new **`--mode worker`** in franky, not just tool additions. Rationale:

| Aspect | Harness-level (worker mode) | Tool-level only |
|---|---|---|
| Autonomy | Agent runs unattended through queue | Agent must think about when to poll |
| Session isolation | Harness creates fresh session per task | Agent context bleeds between tasks |
| Error handling | Harness posts fail to outbox on crash | Agent must handle errors itself |
| Idle behavior | Harness polls with backoff when idle | Agent loops forever asking "what now?" |
| Complexity | Moderate (new mode) | Low (just tools) but incomplete |

**Decision: Harness-level worker mode with complementary tools.**

### 3.2 When Should the Harness Poll?

**Poll when idle** — not just on demand. The worker mode should:

1. Start up and register with `franky-box` (`POST /v1/agents` if new, then poll)
2. Enter an **idle loop**:
   ```
   while (true) {
       task = claim(tenant_id, agent_id)
       if (task) {
           session = create_session(task.task_id)
           result = run_agent(session, task.payload)
           if (result.ok) complete(tenant_id, agent_id, task.task_id, result.output)
                       else fail(tenant_id, agent_id, task.task_id, result.error)
       } else {
           sleep(backoff) // exponential: 1s → 2s → 4s → max 30s
       }
   }
   ```

### 3.3 Session Per Task

**Each `task_id` gets its own session.** This is critical because:

- Agent context (transcript, memory) must not leak between unrelated tasks
- Sessions are stored under `<FRANKY_HOME>/sessions/<task_id>/`
- The task payload becomes the **first user prompt** in that session
- When the agent calls `finish_task`, the harness captures the result and posts to the outbox
- If the agent gets stuck (max turns exceeded, error), the harness posts a failure to the outbox

### 3.4 Complementary Tools

Even with harness-level polling, agents benefit from awareness tools:

| Tool | Purpose | When called |
|---|---|---|
| `task_poll` | **Explicit** poll for next task (bypasses idle polling) | Agent wants to check for priority work |
| `task_status` | Show current task metadata (task_id, action, try_count) | Agent asks "what am I working on?" |
| `task_post_result` | Post a result to outbox without calling finish_task | Agent wants to send intermediate results |

---

## 4. Recommended Implementation: `--mode worker`

### 4.1 Startup Flow

```
franky --mode worker \
  --inbox-server https://franky-box.example.com \
  --agent-id billing-agent \
  --agent-secret <secret> \
  --team-id acme-corp \
  --model claude-sonnet-4-6 \
  --max-consecutive-failures 3
```

1. Register agent with `franky-box` (or re-use stored credentials)
2. Enter the worker loop

### 4.2 Worker Loop Pseudocode

```zig
pub fn run(allocator, io, config) !void {
    var store = franky_box.Client.init(allocator, config.server_url);
    try store.authenticate(config.agent_id, config.agent_secret);

    var consecutive_failures: u32 = 0;
    var backoff_ms: u64 = 1000;

    while (consecutive_failures < config.max_consecutive_failures) {
        // Claim next task
        const task = store.claim(config.team_id, config.agent_id) catch |err| {
            log.err("claim failed: {}", .{err});
            consecutive_failures += 1;
            std.time.sleep(backoff_ms * std.time.ns_per_ms);
            backoff_ms = @min(backoff_ms * 2, 30_000);
            continue;
        };
        consecutive_failures = 0;
        backoff_ms = 1000;

        if (task) |t| {
            defer task.deinit(allocator);

            // Create fresh session for this task
            var session = try createSession(allocator, io, config, t.task_id, t.payload);
            defer session.deinit();
            
            // Run agent loop (same as print mode, but session-scoped)
            const result = try runAgentForTask(allocator, io, &session, config);

            // Post result to outbox
            if (result.ok) {
                try store.complete(config.team_id, config.agent_id, t.task_id, result.output);
            } else {
                try store.fail(config.team_id, config.agent_id, t.task_id, result.error_json);
            }
        } else {
            // No tasks available — sleep with backoff
            std.time.sleep(backoff_ms * std.time.ns_per_ms);
            backoff_ms = @min(backoff_ms * 2, 30_000);
        }
    }

    log.err("too many consecutive failures, exiting", .{});
}
```

### 4.3 Session Creation per Task

Each task gets:
- Session ID = `task_id` (e.g., `task-abc123`)
- First user message = the task's `payload` (JSON config/instruction)
- Tools available = standard coding tools + task awareness tools
- Memory context = loaded from the agent's L1 store, scoped by `task_id`

```
sessions/
└── task-abc123/
    ├── session.json    # header: task_id, agent_id, model, started_at
    └── transcript.json # the agent's conversation for this task
```

### 4.4 Idle Polling Behavior

| State | Action | Backoff |
|---|---|---|
| No tasks available | Sleep, then retry | Exponential: 1s → 2s → 4s → ... → 30s max |
| Task completed | Reset backoff to 1s, poll immediately | — |
| Task failed (agent error) | Reset backoff to 1s, poll immediately | — |
| Consecutive claims failing | Exponential backoff | Same as idle |
| Max consecutive failures | Exit with error code | — |

---

## 5. Implementation Steps

### Phase 1: franky-box Client Library (in franky repo)

1. **Create `src/coding/box_client.zig`** — HTTP client wrapping franky-box REST API:
   - `GET /v1/agents/{name}/inbox/claim` — poll for next task
   - `POST /v1/agents/{name}/outbox/{task_id}/complete` — post success
   - `POST /v1/agents/{name}/outbox/{task_id}/fail` — post failure
   - `GET /v1/agents/{name}/outbox?since=<ts>` — read outbox
   - Bearer token auth via agent_secret

2. **Box types: `src/coding/box_types.zig`** — Lightweight JSON deserialization for:
   - `ClaimedTask { task_id, action, payload, try_count }`
   - No new dependencies — use `std.json` which franky already uses

### Phase 2: Worker Mode

3. **Create `src/coding/modes/worker.zig`** — The worker loop:
   - CLI flags: `--inbox-server`, `--agent-id`, `--agent-secret`, `--team-id`, `--max-consecutive-failures`
   - Reuses `session.create` from existing session infrastructure
   - Reuses `print.zig` agent loop but scoped per-task
   - Idle polling with exponential backoff

4. **Register `worker` mode** in CLI argument parser and dispatcher

### Phase 3: Task Awareness Tools

5. **Create `src/coding/tools/task_status.zig`** — Agent reads current task metadata
6. **Create `src/coding/tools/task_post_result.zig`** — Agent posts intermediate results

### Phase 4: Integration & Testing

7. **Integration test**: Start `franky-box` server, start `franky --mode worker`, dispatch tasks, verify execution
8. **Error handling**: Network failures, auth failures, agent loop crashes, max turn limits
9. **Documentation**: Update README.md, AGENTS.md with worker mode docs

---

## 6. Sequence Diagram

```
franky-box                    franky worker                  LLM
    │                             │                          │
    │   ── claim ───────────────► │                          │
    │◄── { task_id, payload } ─── │                          │
    │                             │                          │
    │                             ├── create session         │
    │                             │   for task_id             │
    │                             │                          │
    │                             ├── send prompt ──────────► │
    │                             │   (task payload)          │
    │                             │◄── stream response ────── │
    │                             │   ...tools, thinking...   │
    │                             │◄── finish_task ────────── │
    │                             │                          │
    │   ── complete(task_id,     │                          │
    │      result) ─────────────► │                          │
    │                             │                          │
    │                             ├── poll next task...      │
    │                             │                          │
```

---

## 7. franky-box Server Deployment

For this integration, `franky-box` runs as a standalone HTTP server:

```bash
# Start the franky-box server on port 8080
./franky-box 8080 /path/to/tasks.db
```

Default agent is pre-registered for initial testing. Production deployments add:
- TLS termination (behind nginx/caddy)
- Persistent SQLite storage with backups
- Multiple agent registrations via `POST /v1/agents`

---

## 8. Open Questions

| Question | Consideration | Status |
|---|---|---|
| Should worker mode use `print.zig` loop or proxy mode loop? | Print mode is non-interactive (good for workers). Proxy adds HTTP/SSe listener overhead. | **Use print mode** loop |
| How to handle task-specific memory scoping? | L1 memory should be scoped by `task_id` so each task recalls its own context. | Needs memory store update |
| What if a task takes hours? | Worker needs keepalive / heartbeat to prevent other workers from claiming the same task (visibility timeout). | Already handled by `locked_until` in franky-box |
| Should multiple workers share the same agent_id? | No — each worker is a unique `agent_id`. franky-box's claim query ensures one worker gets each task. | Already handled by atomic claim |
| How does the agent know its task_id for context? | Inject `task_id`, `action`, `try_count` into the system prompt or as an environment variable. | In system prompt |
| What about task cancellation? | Agent can detect `stop_requested` mid-task. The worker can `POST /v1/agents/{name}/outbox/{task_id}/fail` with a cancellation reason. | Add to v2 |

---

## 9. Risks

| Risk | Mitigation |
|---|---|
| Agent context bleeding between tasks | Strict session-per-task; fresh agent state per claim |
| Worker crashes mid-task | Visibility timeout releases task after 5 min; `try_count` tracks retries; max 3 retries before poison pill |
| Network failures to franky-box | Exponential backoff, max consecutive failures exit |
| Long-running tasks monopolize queue | Single-task-per-worker; multiple workers scale horizontally |
| Memory/session directory bloat | Add cleanup of old task sessions (analogous to 7-day purge in franky-box) |

---

## 10. Estimated Effort

| Phase | Description | Days |
|---|---|---|
| 1 | `box_client.zig` + `box_types.zig` (HTTP client) | 1 |
| 2 | `worker.zig` mode (loop, session-per-task, polling) | 2 |
| 3 | Task awareness tools (`task_status`, `task_post_result`) | 1 |
| 4 | Integration testing, error handling, edge cases | 1 |
| **Total** | | **5 days** |

---

## 11. Conclusion

The correct architecture is **franky-box as a remote task queue server**. Franky agents connect as **workers** via a new `--mode worker` that:

1. **Registers** with franky-box at startup
2. **Polls** for tasks when idle (exponential backoff when empty)
3. **Creates a fresh session** per `task_id` (no context mixing)
4. **Runs the agent** with the task payload as the prompt
5. **Posts results** to the outbox when done or stuck

This is **harness-level** with complementary tools — not just tools. The harness handles lifecycle, session isolation, error recovery, and backoff; tools give the agent awareness. Estimated effort: **5 days**.