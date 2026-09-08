# Retention & Consumption Model (v1)

**Status:** Implemented
**Date:** 2026-09-08
**Supersedes:** the 7-day hard purge described in `INBOX_OUTBOX.md` §D (kept in this doc)

---

## 1. Problem

The v0 model deleted every completed task 7 days after completion — whether
anyone had ever read the result or not. There was no way to say "I consumed
this result", no cursor for polling consumers, and every outbox read returned
the full history. Two failure modes:

- **Silent data loss:** a result nobody picked up vanished after 7 days.
- **Inefficient polling:** consumers re-downloaded the entire outbox every poll.

## 2. Model

Keep the v0 philosophy — *no state machine; nullability is the state* — and add
one more nullable timestamp, exactly like `completed_at`:

| Column | Meaning |
|---|---|
| `output IS NULL` | inbox item (pending) — **never purged** |
| `output IS NOT NULL` | outbox result |
| `consumed_at IS NULL` | result **not yet consumed** — kept indefinitely (up to the 90-day safety net) |
| `consumed_at IS NOT NULL` | result consumed; retires to the archive after a 1-hour grace window |

### Consumption protocol (ack)

```
POST /v1/agents/:agent_id/outbox/:task_id/ack      ack a single result
POST /v1/agents/:agent_id/outbox/ack-all?before=ts ack everything ≤ ts
GET  /v1/agents/:agent_id/outbox?since=<ts>        cursor-based poll
```

- `readOutbox` only returns **unconsumed** results and honors the `?since=`
  cursor (percent-encoded timestamps work, e.g. `since=2026-09-08%2000:00:00`).
- Acking is idempotent: acking an already-consumed result is a no-op.
- Failed results (poison pills, explicit `fail()`) follow the same lifecycle.
- The admin UI (`/admin/outbox`) shows the consumed state; `/admin/archive`
  lists retired tasks.

### Retention (two triggers)

A piggybacked sweep on `dispatch`/`claim`/`ackAll` retires rows:

1. **Consumed + grace elapsed** → archive. The grace window (1 hour) lets a
   consumer re-read right after acking (at-least-once delivery).
2. **Unconsumed + 90-day safety net** → archive. A dead consumer cannot leak
   rows forever; the row is never lost, just retired.

Inbox items are never touched by the sweep.

### Archive

`tasks_archive` is the same shape as `tasks` plus `archived_at`, in the **same
SQLite file**. Why same-file:

- The move (`INSERT … SELECT` + `DELETE`) is a single atomic transaction.
- Cross-file (`ATTACH`) transactions are **not atomic under WAL mode** —
  SQLite only guarantees multi-file atomicity with the rollback journal
  (and giving up WAL costs concurrent readers, the main reason WAL is used).
- The vtable store interface (`store.zig`) lets a future two-file `TieredStore`
  slot in behind the same interface if independent archive lifecycle (separate
  backup, rotation, moving to slow storage) is ever needed — the WAL-safe
  converging two-step (`INSERT OR IGNORE` then `DELETE … IN (SELECT …)`) is the
  pattern to use there.

Nothing is ever hard-deleted; the archive is kept forever and is queryable via
`GET /admin/archive` (newest 500).

## 3. Schema

```sql
CREATE TABLE tasks (
  …v0 columns…,
  workstream_id TEXT DEFAULT NULL,
  consumed_at   TEXT DEFAULT NULL     -- NULL = not yet consumed
);

CREATE TABLE tasks_archive (
  …same columns as tasks…,
  archived_at TEXT NOT NULL
);

CREATE INDEX idx_tasks_completed ON tasks (completed_at) WHERE completed_at IS NOT NULL;
CREATE INDEX idx_tasks_consumed  ON tasks (consumed_at)  WHERE consumed_at IS NOT NULL;
```

The partial indexes keep the piggybacked sweep cheap (it scans `completed_at` /
`consumed_at` only over completed/consumed rows).

Existing databases migrate in place: `addColumnIfMissing` adds `consumed_at`,
and `tasks_archive` is created if absent.

## 4. Found bugs fixed along the way

- **`sqlite3_exec` memory-corruption bug (pre-existing):** `Db.exec` passed
  `sql.ptr` to `sqlite3_exec`, which reads until a NUL byte — but
  `addColumnIfMissing` formatted the ALTER statement with `bufPrint`, which
  does **not** NUL-terminate. Result: uninitialized stack garbage was executed
  as SQL and stored in the schema (seen as garbage bytes in `sqlite_master`).
  `exec` now takes a `[:0]const u8` so the compiler enforces NUL-termination;
  the migration uses `bufPrintSentinel`.
- **Stale test databases:** integration tests reused `/tmp/franky-box-test-N.db`
  files across runs (the counter resets each run), leaking tasks between runs
  and causing flaky failures (including a pre-existing one). `TestContext`
  now deletes the db + WAL/SHM siblings before opening.
- **`readOutbox` ignored its `since` cursor:** the store signature accepted
  `since_timestamp` but the HTTP handler hardcoded the epoch, returning the
  full outbox every poll. Routing also didn't strip query strings, so
  `GET …/outbox?since=…` 404'd.

## 5. Open questions

1. Should the admin UI expose a "consume" button for individual results
   (ack-by-human), or is ack strictly for programmatic consumers?
2. Are the retention numbers right? (1-hour grace, 90-day safety net,
   500-row admin archive window.)
3. When should the archive grow its own retention/rotation policy (e.g.
   move to a separate file per year, or export to JSONL for audit)?