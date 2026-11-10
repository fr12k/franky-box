//! SQLite-based embedded task store for franky-box.

const std = @import("std");
const sqlite = @import("sqlite.zig");
const types = @import("types.zig");
const store = @import("store.zig");

pub const SqliteStore = struct {
    allocator: std.mem.Allocator,
    db: sqlite.Db,

    pub fn init(allocator: std.mem.Allocator, db_path: [:0]const u8) !SqliteStore {
        var db = try sqlite.Db.open(db_path);
        errdefer db.close();
        try db.exec("PRAGMA journal_mode = WAL");
        try db.exec("PRAGMA busy_timeout = 5000");
        try db.exec("PRAGMA cache_size = -65536");
        try db.exec("PRAGMA foreign_keys = ON");
        try createSchema(&db);
        return .{ .allocator = allocator, .db = db };
    }

    pub fn deinit(self: *SqliteStore) void { self.db.close(); }

    fn createSchema(db: *sqlite.Db) !void {
        try db.exec(
            \\CREATE TABLE IF NOT EXISTS tasks (
            \\  tenant_id TEXT NOT NULL,
            \\  agent_id TEXT NOT NULL,
            \\  task_id TEXT PRIMARY KEY,
            \\  action TEXT NOT NULL,
            \\  payload TEXT NOT NULL,
            \\  output TEXT DEFAULT NULL,
            \\  try_count INTEGER DEFAULT 0,
            \\  locked_until TEXT DEFAULT NULL,
            \\  completed_at TEXT DEFAULT NULL,
            \\  workstream_id TEXT DEFAULT NULL,
            \\  consumed_at TEXT DEFAULT NULL,
            \\  priority INTEGER NOT NULL DEFAULT 0,
            \\  available_at TEXT DEFAULT NULL,
            \\  blocked_by TEXT DEFAULT NULL,
            \\  idempotency_key TEXT DEFAULT NULL,
            \\  pending_input TEXT DEFAULT NULL,
            \\  cancel_requested INTEGER NOT NULL DEFAULT 0
            \\);
        );
        // Named workstreams — a workstream is a first-class entity with an id,
        // a human-readable name (unique, max 256), and a creation timestamp.
        try db.exec(
            \\CREATE TABLE IF NOT EXISTS workstreams (
            \\  workstream_id TEXT PRIMARY KEY,
            \\  name TEXT NOT NULL,
            \\  created_at TEXT NOT NULL,
            \\  UNIQUE(name)
            \\);
        );
        // Migrate pre-existing databases: add the workstream column if absent.
        // SQLite has no ADD COLUMN IF NOT EXISTS, so probe pragma_table_info.
        addColumnIfMissing(db, "tasks", "workstream_id", "TEXT DEFAULT NULL") catch {};
        // consumed_at marks an outbox result as picked up (consumed) by a
        // reader. NULL means the result is still waiting to be consumed.
        // Keeps with the v0 philosophy: nullability is the state.
        // consumed_at is load-bearing for the retention feature — propagate
        // a migration failure instead of swallowing it (every readOutbox/ack/
        // purge query would otherwise fail with a confusing SQL error later).
        try addColumnIfMissing(db, "tasks", "consumed_at", "TEXT DEFAULT NULL");
        try addColumnIfMissing(db, "tasks", "priority", "INTEGER NOT NULL DEFAULT 0");
        try addColumnIfMissing(db, "tasks", "available_at", "TEXT DEFAULT NULL");
        try addColumnIfMissing(db, "tasks", "blocked_by", "TEXT DEFAULT NULL");
        try addColumnIfMissing(db, "tasks", "idempotency_key", "TEXT DEFAULT NULL");
        try addColumnIfMissing(db, "tasks", "pending_input", "TEXT DEFAULT NULL");
        try addColumnIfMissing(db, "tasks", "cancel_requested", "INTEGER NOT NULL DEFAULT 0");
        // Archive table — retired rows (consumed, or aged-out unconsumed) are
        // moved here by purge(). Kept forever; queried by the admin archive view.
        // Same shape as tasks so INSERT ... SELECT ... moves rows verbatim,
        // plus archived_at recording when the row was retired.
        try db.exec(
            \\CREATE TABLE IF NOT EXISTS tasks_archive (
            \\  tenant_id TEXT NOT NULL,
            \\  agent_id TEXT NOT NULL,
            \\  task_id TEXT PRIMARY KEY,
            \\  action TEXT NOT NULL,
            \\  payload TEXT NOT NULL,
            \\  output TEXT DEFAULT NULL,
            \\  try_count INTEGER DEFAULT 0,
            \\  locked_until TEXT DEFAULT NULL,
            \\  completed_at TEXT DEFAULT NULL,
            \\  consumed_at TEXT DEFAULT NULL,
            \\  workstream_id TEXT DEFAULT NULL,
            \\  priority INTEGER NOT NULL DEFAULT 0,
            \\  available_at TEXT DEFAULT NULL,
            \\  blocked_by TEXT DEFAULT NULL,
            \\  idempotency_key TEXT DEFAULT NULL,
            \\  pending_input TEXT DEFAULT NULL,
            \\  cancel_requested INTEGER NOT NULL DEFAULT 0,
            \\  archived_at TEXT NOT NULL
            \\);
        );
        try addColumnIfMissing(db, "tasks_archive", "priority", "INTEGER NOT NULL DEFAULT 0");
        try addColumnIfMissing(db, "tasks_archive", "available_at", "TEXT DEFAULT NULL");
        try addColumnIfMissing(db, "tasks_archive", "blocked_by", "TEXT DEFAULT NULL");
        try addColumnIfMissing(db, "tasks_archive", "idempotency_key", "TEXT DEFAULT NULL");
        try addColumnIfMissing(db, "tasks_archive", "pending_input", "TEXT DEFAULT NULL");
        try addColumnIfMissing(db, "tasks_archive", "cancel_requested", "INTEGER NOT NULL DEFAULT 0");
        // The unique idempotency index must ALSO live on the archive: a task
        // whose key was retired to the archive must not be re-dispatched as new
        // — findByKey/getTask still find it. (Idempotency is forever.)
        try db.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_archive_idem ON tasks_archive (tenant_id, idempotency_key) WHERE idempotency_key IS NOT NULL");
        try db.exec("CREATE INDEX IF NOT EXISTS idx_tasks_routing ON tasks (tenant_id, agent_id, output, locked_until)");
        try db.exec("CREATE INDEX IF NOT EXISTS idx_tasks_workstream ON tasks (workstream_id)");
        try db.exec("CREATE INDEX IF NOT EXISTS idx_workstreams_name ON workstreams (name)");
        // Purge scans completed_at over completed rows only — a partial index
        // keeps it tiny and makes the piggybacked purge cheap forever.
        try db.exec("CREATE INDEX IF NOT EXISTS idx_tasks_completed ON tasks (completed_at) WHERE completed_at IS NOT NULL");
        try db.exec("CREATE INDEX IF NOT EXISTS idx_tasks_consumed ON tasks (consumed_at) WHERE consumed_at IS NOT NULL");
        // P2: idempotency dedupe (live + archive) and priority-ordered claim.
        try db.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_idem ON tasks (tenant_id, idempotency_key) WHERE idempotency_key IS NOT NULL");
        try db.exec("CREATE INDEX IF NOT EXISTS idx_tasks_claim ON tasks (tenant_id, agent_id, priority DESC) WHERE output IS NULL");

        // ── P0–P2 additions ─────────────────────────────────────────────

        // Persisted agent registry (P0). Agents registered via the API used to
        // live only in the Server's in-memory map and vanish on restart.
        try db.exec(
            \\CREATE TABLE IF NOT EXISTS agents (
            \\  agent_id TEXT PRIMARY KEY,
            \\  secret TEXT NOT NULL,
            \\  name TEXT,
            \\  skills TEXT,
            \\  card_url TEXT,
            \\  created_at TEXT NOT NULL
            \\)
        );

        // Webhook push subscriptions (P1). Scoped to a task (a consumer that
        // wants one result pushed) or to an agent (every result pushed).
        try db.exec(
            \\CREATE TABLE IF NOT EXISTS webhooks (
            \\  subscription_id TEXT PRIMARY KEY,
            \\  url TEXT NOT NULL,
            \\  secret TEXT NOT NULL,
            \\  task_id TEXT,
            \\  agent_id TEXT,
            \\  created_at TEXT NOT NULL
            \\)
        );
        try db.exec("CREATE INDEX IF NOT EXISTS idx_webhooks_task ON webhooks (task_id) WHERE task_id IS NOT NULL");
        try db.exec("CREATE INDEX IF NOT EXISTS idx_webhooks_agent ON webhooks (agent_id) WHERE agent_id IS NOT NULL");
    }

    /// Add a column to a table only if it does not already exist.
    fn addColumnIfMissing(db: *sqlite.Db, table: []const u8, column: []const u8, decl: []const u8) !void {
        // NUL-terminated so sqlite3_exec (which reads up to the NUL) cannot
        // run past the formatted string into stack garbage.
        var buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrintSentinel(&buf, "SELECT COUNT(*) FROM pragma_table_info('{s}') WHERE name='{s}'", .{ table, column }, 0);
        var stmt = try db.prepare(sql);
        defer stmt.finalize();
        if (try stmt.step()) {
            if (stmt.columnInt(0) > 0) return; // column already present
        }
        var buf2: [256]u8 = undefined;
        const alter = try std.fmt.bufPrintSentinel(&buf2, "ALTER TABLE {s} ADD COLUMN {s} {s}", .{ table, column, decl }, 0);
        try db.exec(alter);
    }

    /// Dispatch a new task.
    ///
    /// `workstream_id` controls workstream linking:
    ///   - when non-null, this task joins that existing workstream (follow-up /
    ///     continuation of another task in the same chain);
    ///   - when null, the task seeds a new workstream with its own `task_id`
    ///     (only happens for direct store callers; the HTTP server always
    ///     generates a `w_`-prefixed workstream id).
    ///
    /// Querying `WHERE workstream_id = ?` then returns the whole chain.
    pub fn dispatch(self: *SqliteStore, tenant_id: []const u8, agent_id: []const u8, task_id: []const u8, action: []const u8, payload: []const u8, workstream_id: ?[]const u8) !void {
        try self.purge();

        // Resolve the effective workstream id: use the given one, else seed
        // a new workstream with this task's own id.
        const ws: []const u8 = workstream_id orelse task_id;

        const sql =
            \\INSERT INTO tasks (tenant_id, agent_id, task_id, action, payload, workstream_id)
            \\VALUES (?, ?, ?, ?, ?, ?)
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindText(1, tenant_id);
        try stmt.bindText(2, agent_id);
        try stmt.bindText(3, task_id);
        try stmt.bindText(4, action);
        try stmt.bindText(5, payload);
        try stmt.bindText(6, ws);
        _ = try stmt.step();
    }

    /// Advanced dispatch (P2): priority, scheduling, dependencies, idempotency.
    ///
    /// Idempotency: when `options.idempotency_key` matches an existing
    /// unarchived task in this tenant, no new row is inserted and the id of
    /// the earlier task is returned (producers may retry safely). The unique
    /// partial index idx_tasks_idem enforces uniqueness under races.
    ///
    /// Dependencies: `options.blocked_by` is stored as a JSON array string.
    /// Claim only considers tasks whose every dependency has output (i.e. is
    /// completed OR failed — both are terminal and both unblock the waiter).
    pub fn dispatchAdvanced(self: *SqliteStore, allocator: std.mem.Allocator, tenant_id: []const u8, agent_id: []const u8, task_id: []const u8, action: []const u8, payload: []const u8, workstream_id: ?[]const u8, options: types.DispatchOptions) ![]const u8 {
        try self.purge();

        // Idempotency fast-path: same key → return the existing task id.
        if (options.idempotency_key) |key| {
            if (key.len > 0) {
                const existing = try self.findByKey(tenant_id, key);
                defer if (existing) |e| self.allocator.free(e);
                if (existing) |task_id_existing| return try allocator.dupe(u8, task_id_existing);
            }
        }

        // Serialize blocked_by into a JSON array ("[\"t_a\",\"t_b\"]").
        var blocked_json: ?[]const u8 = null;
        defer if (blocked_json) |b| self.allocator.free(b);
        if (options.blocked_by.len > 0) {
            blocked_json = try jsonEncodeStringArray(self.allocator, options.blocked_by);
        }

        const ws: []const u8 = workstream_id orelse task_id;
        const sql =
            \\INSERT INTO tasks (tenant_id, agent_id, task_id, action, payload, workstream_id,
            \\                   priority, available_at, blocked_by, idempotency_key)
            \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindText(1, tenant_id);
        try stmt.bindText(2, agent_id);
        try stmt.bindText(3, task_id);
        try stmt.bindText(4, action);
        try stmt.bindText(5, payload);
        try stmt.bindText(6, ws);
        try stmt.bindInt(7, options.priority);
        if (options.available_at) |at| try stmt.bindText(8, at) else try stmt.bindNull(8);
        if (blocked_json) |b| try stmt.bindText(9, b) else try stmt.bindNull(9);
        if (options.idempotency_key) |k| try stmt.bindText(10, k) else try stmt.bindNull(10);
        _ = try stmt.step();
        return try allocator.dupe(u8, task_id);
    }

    fn findByKey(self: *SqliteStore, tenant_id: []const u8, key: []const u8) !?[]const u8 {
        // Idempotency is forever: a task whose key was retired to the
        // archive must still be found so a re-dispatch returns the original
        // task instead of creating a duplicate.
        const sql =
            \\SELECT task_id FROM tasks WHERE tenant_id = ? AND idempotency_key = ?
            \\UNION ALL
            \\SELECT task_id FROM tasks_archive WHERE tenant_id = ? AND idempotency_key = ?
            \\LIMIT 1;
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindText(1, tenant_id);
        try stmt.bindText(2, key);
        try stmt.bindText(3, tenant_id);
        try stmt.bindText(4, key);
        if (try stmt.step()) {
            return try self.allocator.dupe(u8, stmt.columnText(0));
        }
        return null;
    }

    /// Encode a list of strings as a JSON array (for blocked_by storage).
    fn jsonEncodeStringArray(allocator: std.mem.Allocator, items: []const []const u8) ![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        try buf.appendSlice(allocator, "[");
        for (items, 0..) |item, i| {
            if (i > 0) try buf.appendSlice(allocator, ",");
            try buf.appendSlice(allocator, "\"");
            for (item) |c| {
                switch (c) {
                    '"' => try buf.appendSlice(allocator, "\\\""),
                    '\\' => try buf.appendSlice(allocator, "\\\\"),
                    else => try buf.append(allocator, c),
                }
            }
            try buf.appendSlice(allocator, "\"");
        }
        try buf.appendSlice(allocator, "]");
        return try buf.toOwnedSlice(allocator);
    }

    pub fn claim(self: *SqliteStore, allocator: std.mem.Allocator, tenant_id: []const u8, agent_id: []const u8) !?types.ClaimResult {
        try self.purge();
        // P1: finalize deferred-cancel rows first. A cancelled-
        // while-claimed task has cancel_requested=1; the main claim below skips it,
        // so without this step it would strand in the inbox forever. Here we
        // write the canceled output (terminal, like a poison pill) and let
        // the main claim pick the next real candidate.
        var finalize_stmt = try self.db.prepare(
            \\UPDATE tasks
            \\SET output = '{"canceled": true, "reason": "deferred cancel finalized"}',
            \\    completed_at = strftime('%Y-%m-%d %H:%M:%f', 'now'),
            \\    locked_until = NULL
            \\WHERE tenant_id = ? AND agent_id = ?
            \\  AND output IS NULL AND cancel_requested = 1
        );
        defer finalize_stmt.finalize();
        try finalize_stmt.bindText(1, tenant_id);
        try finalize_stmt.bindText(2, agent_id);
        _ = try finalize_stmt.step();

        const sql =
            \\UPDATE tasks
            \\SET
            \\   output = CASE WHEN try_count >= 3 THEN '{"error": "Max retries exceeded. Aborted."}' ELSE NULL END,
            \\   completed_at = CASE WHEN try_count >= 3 THEN strftime('%Y-%m-%d %H:%M:%f', 'now') ELSE NULL END,
            \\   try_count = try_count + 1,
            \\   locked_until = strftime('%Y-%m-%d %H:%M:%f', 'now', '+300 seconds')
            \\WHERE task_id = (
            \\   SELECT task_id FROM tasks
            \\   WHERE tenant_id = ?
            \\     AND agent_id = ?
            \\     AND output IS NULL
            \\     AND (locked_until IS NULL OR datetime(locked_until) <= datetime('now'))
            \\     AND cancel_requested = 0
            \\     AND pending_input IS NULL
            \\     AND (available_at IS NULL OR datetime(available_at) <= datetime('now'))
            \\     AND NOT EXISTS (
            \\       SELECT 1 FROM json_each(tasks.blocked_by) AS dep
            \\       WHERE NOT EXISTS (
            \\         SELECT 1 FROM tasks AS t2
            \\         WHERE t2.task_id = dep.value AND t2.output IS NOT NULL
            \\       )
            \\     )
            \\   ORDER BY priority DESC, rowid ASC
            \\   LIMIT 1
            \\)
            \\RETURNING task_id, action, payload, try_count, workstream_id;
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindText(1, tenant_id);
        try stmt.bindText(2, agent_id);
        if (try stmt.step()) {
            const try_count: i32 = @intCast(stmt.columnInt(3));
            // Just-poisoned (this claim drove try_count past 3): the row is
            // already terminal with a poison output — do not hand it out.
            if (try_count >= 4) return null;
            const ws = stmt.columnText(4);
            return types.ClaimResult{
                .task_id = try allocator.dupe(u8, stmt.columnText(0)),
                .action = try allocator.dupe(u8, stmt.columnText(1)),
                .payload = try allocator.dupe(u8, stmt.columnText(2)),
                .try_count = try_count,
                .workstream_id = if (ws.len > 0) try allocator.dupe(u8, ws) else null,
            };
        }
        return null;
    }

    pub fn complete(self: *SqliteStore, tenant_id: []const u8, agent_id: []const u8, task_id: []const u8, output: []const u8) !bool {
        const sql =
            \\UPDATE tasks
            \\SET output = ?, completed_at = strftime('%Y-%m-%d %H:%M:%f', 'now'), locked_until = NULL
            \\WHERE tenant_id = ? AND agent_id = ? AND task_id = ?;
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindText(1, output);
        try stmt.bindText(2, tenant_id);
        try stmt.bindText(3, agent_id);
        try stmt.bindText(4, task_id);
        _ = try stmt.step();
        return self.db.changes() > 0;
    }

    pub fn fail(self: *SqliteStore, tenant_id: []const u8, agent_id: []const u8, task_id: []const u8, error_json: []const u8) !bool {
        const sql =
            \\UPDATE tasks
            \\SET output = ?, completed_at = strftime('%Y-%m-%d %H:%M:%f', 'now'), locked_until = NULL
            \\WHERE tenant_id = ? AND agent_id = ? AND task_id = ?
            \\  AND cancel_requested = 0;
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindText(1, error_json);
        try stmt.bindText(2, tenant_id);
        try stmt.bindText(3, agent_id);
        try stmt.bindText(4, task_id);
        _ = try stmt.step();
        return self.db.changes() > 0;
    }

    /// Extend the claim lease on a working task (P0 heartbeat).
    /// A claim is a lease, not ownership: LLM tasks regularly run longer than
    /// the fixed 300 s visibility timeout, which would silently re-queue the
    /// task and cause duplicate execution. The worker calls heartbeat
    /// periodically (e.g. every 60 s) to keep the lease.
    /// Returns the new locked_until (caller-owned), or null when the task is
    /// not claimable/working (unknown, already completed/failed, or parked).
    pub fn heartbeat(self: *SqliteStore, allocator: std.mem.Allocator, tenant_id: []const u8, agent_id: []const u8, task_id: []const u8, extend_seconds: i64) !?[]const u8 {
        var buf: [64]u8 = undefined;
        const extend_sql = try std.fmt.bufPrintSentinel(&buf, "+{d} seconds", .{extend_seconds}, 0);
        const sql =
            \\UPDATE tasks
            \\SET locked_until = strftime('%Y-%m-%d %H:%M:%f', 'now', ?)
            \\WHERE tenant_id = ? AND agent_id = ? AND task_id = ?
            \\  AND output IS NULL
            \\  AND pending_input IS NULL
            \\RETURNING locked_until;
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindText(1, extend_sql);
        try stmt.bindText(2, tenant_id);
        try stmt.bindText(3, agent_id);
        try stmt.bindText(4, task_id);
        if (try stmt.step()) {
            return try allocator.dupe(u8, stmt.columnText(0));
        }
        return null;
    }

    /// Cancel a task (P1). Works in two situations:
    ///   - unclaimed or lease-expired: the row is finalized immediately with
    ///     a canceled output (terminal, like a failure);
    ///   - currently claimed (lease held): cancel_requested is set; the next
    ///     claim pass finalizes it, and the running worker's complete/fail is
    ///     rejected (terminal state wins — complete/fail check cancel first
    ///     via the same WHERE guard used here).
    /// Returns true for the immediate finalize (truly terminal now);
    /// returns false for the deferred mark (cancelled-while-claimed; the next
    /// claim pass finalizes it). The caller must not emit a terminal
    /// webhook notification on the false path.
    pub fn cancel(self: *SqliteStore, tenant_id: []const u8, agent_id: []const u8, task_id: []const u8, reason: []const u8) !bool {
        // 1. Immediate path: unclaimed or lease-expired.
        const sql_now =
            \\UPDATE tasks
            \\SET output = ?, completed_at = strftime('%Y-%m-%d %H:%M:%f', 'now'), locked_until = NULL, cancel_requested = 1
            \\WHERE tenant_id = ? AND agent_id = ? AND task_id = ?
            \\  AND output IS NULL
            \\  AND (locked_until IS NULL OR datetime(locked_until) <= datetime('now'));
        ;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{\"canceled\": true, \"reason\": ");
        try jsonStringAppend(&buf, self.allocator, reason);
        try buf.appendSlice(self.allocator, "}");
        {
            var stmt = try self.db.prepare(sql_now);
            defer stmt.finalize();
            try stmt.bindText(1, buf.items);
            try stmt.bindText(2, tenant_id);
            try stmt.bindText(3, agent_id);
            try stmt.bindText(4, task_id);
            _ = try stmt.step();
            if (self.db.changes() > 0) return true;
        }
        // 2. Deferred path: currently claimed — mark for the next pass.
        // Returns FALSE: the task is not terminal yet (output still NULL); the
        // caller must not emit a terminal webhook notification now —
        // `claim()` finalizes it on the next poll and the box emits the
        // webhook from there via the complete/fail path... except `claim`
        // finalizes with a canceled output directly, so we emit there.
        const sql_mark =
            \\UPDATE tasks SET cancel_requested = 1
            \\WHERE tenant_id = ? AND agent_id = ? AND task_id = ?
            \\  AND output IS NULL AND cancel_requested = 0;
        ;
        var stmt = try self.db.prepare(sql_mark);
        defer stmt.finalize();
        try stmt.bindText(1, tenant_id);
        try stmt.bindText(2, agent_id);
        try stmt.bindText(3, task_id);
        _ = try stmt.step();
        // Marked (not terminal yet) — return false (accepted-pending). The
        // caller returns 202; the terminal webhook is emitted lazily when
        // `claim` finalizes the row (the consumer's next getTask poll
        // shows the terminal `canceled` state). Documented trade-off.
        return false;
    }

    /// Get a single task by id (P1: GetTask). Returns the full row state
    /// regardless of lifecycle stage. Caller owns the result.
    pub fn getTask(self: *SqliteStore, allocator: std.mem.Allocator, tenant_id: []const u8, agent_id: []const u8, task_id: []const u8) !?types.Task {
        const sql =
            \\SELECT tenant_id, agent_id, task_id, action, payload, output, try_count,
            \\       locked_until, completed_at, workstream_id,
            \\       priority, available_at, blocked_by, idempotency_key, pending_input, cancel_requested
            \\FROM tasks
            \\WHERE tenant_id = ? AND agent_id = ? AND task_id = ?
            \\UNION ALL
            \\SELECT tenant_id, agent_id, task_id, action, payload, output, try_count,
            \\       locked_until, completed_at, workstream_id,
            \\       priority, available_at, blocked_by, idempotency_key, pending_input, cancel_requested
            \\FROM tasks_archive
            \\WHERE tenant_id = ? AND agent_id = ? AND task_id = ?
            \\LIMIT 1;
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindText(1, tenant_id);
        try stmt.bindText(2, agent_id);
        try stmt.bindText(3, task_id);
        try stmt.bindText(4, tenant_id);
        try stmt.bindText(5, agent_id);
        try stmt.bindText(6, task_id);
        if (try stmt.step()) {
            return types.Task{
                .tenant_id = try allocator.dupe(u8, stmt.columnText(0)),
                .agent_id = try allocator.dupe(u8, stmt.columnText(1)),
                .task_id = try allocator.dupe(u8, stmt.columnText(2)),
                .action = try allocator.dupe(u8, stmt.columnText(3)),
                .payload = try allocator.dupe(u8, stmt.columnText(4)),
                .output = if (stmt.columnIsNull(5)) null else try allocator.dupe(u8, stmt.columnText(5)),
                .try_count = @intCast(stmt.columnInt(6)),
                .locked_until = if (stmt.columnIsNull(7)) null else try allocator.dupe(u8, stmt.columnText(7)),
                .completed_at = if (stmt.columnIsNull(8)) null else try allocator.dupe(u8, stmt.columnText(8)),
                .workstream_id = if (stmt.columnIsNull(9)) null else try allocator.dupe(u8, stmt.columnText(9)),
                // P2 fields (fetched by the SELECT, now exposed via types.Task).
                .priority = @intCast(stmt.columnInt(10)),
                .available_at = if (stmt.columnIsNull(11)) null else try allocator.dupe(u8, stmt.columnText(11)),
                .blocked_by = if (stmt.columnIsNull(12)) null else try allocator.dupe(u8, stmt.columnText(12)),
                .idempotency_key = if (stmt.columnIsNull(13)) null else try allocator.dupe(u8, stmt.columnText(13)),
                .pending_input = if (stmt.columnIsNull(14)) null else try allocator.dupe(u8, stmt.columnText(14)),
                .cancel_requested = stmt.columnInt(15) != 0,
            };
        }
        return null;
    }

    /// Park a working task in the human-in-the-loop state (P2): release the
    /// lease, record the input query. The next claim pass will not hand the
    /// task out (pending_input IS NOT NULL blocks candidacy) until
    /// provideInput re-locks it for the same agent.
    pub fn requestInput(self: *SqliteStore, tenant_id: []const u8, agent_id: []const u8, task_id: []const u8, query: []const u8) !bool {
        const sql =
            \\UPDATE tasks
            \\SET pending_input = ?, locked_until = NULL
            \\WHERE tenant_id = ? AND agent_id = ? AND task_id = ?
            \\  AND output IS NULL AND pending_input IS NULL;
        ;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{\"query\": ");
        try jsonStringAppend(&buf, self.allocator, query);
        try buf.appendSlice(self.allocator, "}");
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindText(1, buf.items);
        try stmt.bindText(2, tenant_id);
        try stmt.bindText(3, agent_id);
        try stmt.bindText(4, task_id);
        _ = try stmt.step();
        return self.db.changes() > 0;
    }

    /// Deliver input to a parked task (P2): consume the pending query, re-lock
    /// the lease, and append the input to the task payload (delimited) so the
    /// worker sees it on its next look at the task. The task is re-locked for
    /// the SAME agent that parked it; a competing worker could also pick it
    /// up after the lease expires — by design, crash-recovery wins.
    /// Returns a caller-owned echo of the delivered input, or null when the
    /// task is not parked.
    pub fn provideInput(self: *SqliteStore, allocator: std.mem.Allocator, tenant_id: []const u8, agent_id: []const u8, task_id: []const u8, input: []const u8) !?[]const u8 {
        const sql =
            \\UPDATE tasks
            \\SET pending_input = NULL,
            \\    locked_until = strftime('%Y-%m-%d %H:%M:%f', 'now', '+300 seconds'),
            \\    payload = payload || '\n---human-input---\n' || ?
            \\WHERE tenant_id = ? AND agent_id = ? AND task_id = ?
            \\  AND output IS NULL AND pending_input IS NOT NULL
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindText(1, input);
        try stmt.bindText(2, tenant_id);
        try stmt.bindText(3, agent_id);
        try stmt.bindText(4, task_id);
        _ = try stmt.step();
        if (self.db.changes() > 0) {
            return try allocator.dupe(u8, input);
        }
        return null;
    }

    /// Append a string to buf as a JSON-escaped string value (no surrounding
    /// braces) — helper for building small JSON outputs in store code.
    fn jsonStringAppend(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
        try buf.appendSlice(allocator, "\"");
        for (value) |c| {
            switch (c) {
                '"' => try buf.appendSlice(allocator, "\\\""),
                '\\' => try buf.appendSlice(allocator, "\\\\"),
                '\n' => try buf.appendSlice(allocator, "\\n"),
                '\r' => try buf.appendSlice(allocator, "\\r"),
                '\t' => try buf.appendSlice(allocator, "\\t"),
                else => {
                    if (c < 0x20) {
                        try buf.print(allocator, "\\u{x:0>4}", .{c});
                    } else {
                        try buf.append(allocator, c);
                    }
                },
            }
        }
        try buf.appendSlice(allocator, "\"");
    }

    /// Read the agent's unconsumed results completed strictly after
    /// `since_timestamp`. The comparison is lexicographic on purpose: both
    /// stored `completed_at` and the cursor come from the same fixed-width
    /// `%Y-%m-%d %H:%M:%f` format, so text comparison is exact — including
    /// milliseconds. `datetime()` would truncate to whole seconds and lose
    /// same-second results published just after the cursor.
    pub fn readOutbox(self: *SqliteStore, allocator: std.mem.Allocator, tenant_id: []const u8, agent_id: []const u8, since_timestamp: []const u8) ![]types.OutboxResult {
        const sql =
            \\SELECT task_id, action, payload, output, completed_at, workstream_id, consumed_at
            \\FROM tasks
            \\WHERE tenant_id = ? AND agent_id = ? AND output IS NOT NULL AND consumed_at IS NULL
            \\  AND completed_at > ?
            \\ORDER BY completed_at ASC;
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindText(1, tenant_id);
        try stmt.bindText(2, agent_id);
        try stmt.bindText(3, since_timestamp);
        var results: std.ArrayList(types.OutboxResult) = .empty;
        defer results.deinit(allocator);
        while (try stmt.step()) {
            const ws = stmt.columnText(5);
            const cons = stmt.columnText(6);
            try results.append(allocator, .{
                .task_id = try allocator.dupe(u8, stmt.columnText(0)),
                .action = try allocator.dupe(u8, stmt.columnText(1)),
                .payload = try allocator.dupe(u8, stmt.columnText(2)),
                .output = try allocator.dupe(u8, stmt.columnText(3)),
                .completed_at = try allocator.dupe(u8, stmt.columnText(4)),
                .workstream_id = if (ws.len > 0) try allocator.dupe(u8, ws) else null,
                .consumed_at = if (cons.len > 0) try allocator.dupe(u8, cons) else null,
            });
        }
        return try results.toOwnedSlice(allocator);
    }

    /// Purge is now a retire-and-move, not a delete:
    ///   1. consumed results are retired after a grace window (`consumed_at` older
    ///      than CONSUMED_GRACE), because consumers may re-read right after acking;
    ///   2. unconsumed results are never deleted by age alone — they are kept
    ///      until acked, or moved to the archive after UNCONSUMED_RETENTION
    ///      (90 days) as a safety net so a dead consumer cannot leak rows forever.
    /// Retired rows are copied to tasks_archive and then deleted from tasks.
    /// Both statements are idempotent: if the process crashes between copy and
    /// delete, the next purge pass converges (the copy step is INSERT OR IGNORE,
    /// keyed on task_id). The two steps are not atomic across the two tables in
    /// one transaction, but each is atomic on its own and the end state is the
    /// same — matching the v0 "self-cleaning, no background worker" ethos.
    pub fn purge(self: *SqliteStore) !void {
        // Step 1: copy retiring rows into the archive (idempotent).
        try self.db.exec(
            \\INSERT OR IGNORE INTO tasks_archive (
            \\    tenant_id, agent_id, task_id, action, payload, output,
            \\    try_count, locked_until, completed_at, consumed_at, workstream_id, archived_at
            \\)
            \\SELECT tenant_id, agent_id, task_id, action, payload, output,
            \\       try_count, locked_until, completed_at, consumed_at, workstream_id,
            \\       strftime('%Y-%m-%d %H:%M:%f', 'now')
            \\FROM tasks
            \\WHERE output IS NOT NULL
            \\  AND (
            \\       (consumed_at IS NOT NULL AND datetime(consumed_at) <= datetime('now', '-1 hours'))
            \\    OR (consumed_at IS NULL AND completed_at IS NOT NULL
            \\        AND datetime(completed_at) <= datetime('now', '-90 days'))
            \\  );
        );
        // Step 2: remove the archived rows from the hot table. Archive
        // membership alone decides — anything already copied to tasks_archive
        // must leave tasks, no matter what happened to it since (a crash
        // between the two statements, or a late ack after the copy, must not
        // strand a row in the hot table until its grace window expires).
        try self.db.exec(
            \\DELETE FROM tasks WHERE task_id IN (SELECT task_id FROM tasks_archive);
        );
    }

    /// Acknowledge (consume) a single outbox result. The row stays in the hot
    /// table until the next purge pass retires it to the archive.
    /// Idempotent: re-acking an already-consumed result matches the row
    /// (COALESCE leaves consumed_at untouched) and returns true / HTTP 200,
    /// matching the documented client contract. A genuinely missing task or
    /// a pending inbox task (no output yet) matches nothing → false / 404.
    pub fn ack(self: *SqliteStore, tenant_id: []const u8, agent_id: []const u8, task_id: []const u8) !bool {
        const sql =
            \\UPDATE tasks
            \\SET consumed_at = COALESCE(consumed_at, strftime('%Y-%m-%d %H:%M:%f', 'now'))
            \\WHERE tenant_id = ? AND agent_id = ? AND task_id = ?
            \\  AND output IS NOT NULL;
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindText(1, tenant_id);
        try stmt.bindText(2, agent_id);
        try stmt.bindText(3, task_id);
        _ = try stmt.step();
        return self.db.changes() > 0;
    }

    /// Acknowledge every unconsumed result in this agent's outbox completed at
    /// or before `before_timestamp` (pass the epoch to ack everything pending).
    /// Also retires anything already retired-eligible immediately so consumers
    /// see the effect of their ack without waiting for the next purge pass.
    pub fn ackAll(self: *SqliteStore, tenant_id: []const u8, agent_id: []const u8, before_timestamp: []const u8) !types.AckResult {
        // Snapshot the agent's archive size before the sweep so the `archived`
        // count reports exactly what *this* call retired (no time-window
        // heuristics that concurrent dispatch/claim-triggered purges would skew).
        const before_count = try self.countArchive(agent_id);
        {
            const sql =
                \\UPDATE tasks
                \\SET consumed_at = strftime('%Y-%m-%d %H:%M:%f', 'now')
                \\WHERE tenant_id = ? AND agent_id = ?
                \\  AND output IS NOT NULL AND consumed_at IS NULL
                \\  AND completed_at <= ?;
            ;
            var stmt = try self.db.prepare(sql);
            defer stmt.finalize();
            try stmt.bindText(1, tenant_id);
            try stmt.bindText(2, agent_id);
            try stmt.bindText(3, before_timestamp);
            _ = try stmt.step();
        }
        const acked = self.db.changes();
        // Retire-eligible rows (consumed_at older than the grace window, or
        // unconsumed but past the safety-net retention) are archived right away.
        try self.purge();
        const archived = try self.countArchive(agent_id) - before_count;
        return .{ .acked = acked, .archived = archived };
    }

    /// Count this agent's archived rows.
    fn countArchive(self: *SqliteStore, agent_id: []const u8) !i64 {
        const sql = "SELECT COUNT(*) FROM tasks_archive WHERE agent_id = ?";
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindText(1, agent_id);
        if (try stmt.step()) return stmt.columnInt(0);
        return 0;
    }

    /// List archived (retired) outbox tasks, newest first (admin).
    pub fn fetchArchive(self: *SqliteStore, allocator: std.mem.Allocator) ![]types.OutboxResult {
        const sql =
            \\SELECT task_id, action, payload, output, completed_at, workstream_id, consumed_at
            \\FROM tasks_archive
            \\ORDER BY archived_at DESC
            \\LIMIT 500;
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        var results: std.ArrayList(types.OutboxResult) = .empty;
        defer results.deinit(allocator);
        while (try stmt.step()) {
            const ws = stmt.columnText(5);
            const cons = stmt.columnText(6);
            results.append(allocator, .{
                .task_id = try allocator.dupe(u8, stmt.columnText(0)),
                .action = try allocator.dupe(u8, stmt.columnText(1)),
                .payload = try allocator.dupe(u8, stmt.columnText(2)),
                .output = try allocator.dupe(u8, stmt.columnText(3)),
                .completed_at = try allocator.dupe(u8, stmt.columnText(4)),
                .workstream_id = if (ws.len > 0) try allocator.dupe(u8, ws) else null,
                .consumed_at = if (cons.len > 0) try allocator.dupe(u8, cons) else null,
            }) catch unreachable;
        }
        return try results.toOwnedSlice(allocator);
    }

    /// List all pending inbox tasks across all agents (admin).
    pub fn fetchInbox(self: *SqliteStore, allocator: std.mem.Allocator) ![]types.InboxEntry {
        const sql =
            \\SELECT tenant_id, agent_id, task_id, action, payload, try_count, locked_until, workstream_id
            \\FROM tasks
            \\WHERE output IS NULL
            \\ORDER BY rowid ASC;
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        var results: std.ArrayList(types.InboxEntry) = .empty;
        defer results.deinit(allocator);
        while (try stmt.step()) {
            const locked = stmt.columnText(6);
            const ws = stmt.columnText(7);
            results.append(allocator, .{
                .tenant_id = try allocator.dupe(u8, stmt.columnText(0)),
                .agent_id = try allocator.dupe(u8, stmt.columnText(1)),
                .task_id = try allocator.dupe(u8, stmt.columnText(2)),
                .action = try allocator.dupe(u8, stmt.columnText(3)),
                .payload = try allocator.dupe(u8, stmt.columnText(4)),
                .try_count = @intCast(stmt.columnInt(5)),
                .locked_until = if (locked.len > 0) try allocator.dupe(u8, locked) else null,
                .workstream_id = if (ws.len > 0) try allocator.dupe(u8, ws) else null,
            }) catch unreachable;
        }
        return try results.toOwnedSlice(allocator);
    }

    /// List all completed outbox tasks across all agents (admin).
    pub fn fetchOutboxAll(self: *SqliteStore, allocator: std.mem.Allocator) ![]types.OutboxResult {
        const sql =
            \\SELECT task_id, action, payload, output, completed_at, workstream_id, consumed_at
            \\FROM tasks
            \\WHERE output IS NOT NULL
            \\ORDER BY completed_at DESC
            \\LIMIT 500;
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        var results: std.ArrayList(types.OutboxResult) = .empty;
        defer results.deinit(allocator);
        while (try stmt.step()) {
            const ws = stmt.columnText(5);
            const cons = stmt.columnText(6);
            results.append(allocator, .{
                .task_id = try allocator.dupe(u8, stmt.columnText(0)),
                .action = try allocator.dupe(u8, stmt.columnText(1)),
                .payload = try allocator.dupe(u8, stmt.columnText(2)),
                .output = try allocator.dupe(u8, stmt.columnText(3)),
                .completed_at = try allocator.dupe(u8, stmt.columnText(4)),
                .workstream_id = if (ws.len > 0) try allocator.dupe(u8, ws) else null,
                .consumed_at = if (cons.len > 0) try allocator.dupe(u8, cons) else null,
            }) catch unreachable;
        }
        return try results.toOwnedSlice(allocator);
    }

    /// List all known workstreams with task counts, names, and last activity.
    /// Left-joins tasks to workstreams so named workstreams (even with zero tasks)
    /// and legacy workstream ids (no matching workstreams row) both appear.
    /// Ordered by most recently active first.
    pub fn fetchWorkstreams(self: *SqliteStore, allocator: std.mem.Allocator) ![]types.WorkstreamInfo {
        // UNION of two sources so both named workstreams and task-only workstream ids show up:
        //  1. workstream ids present in the tasks table (LEFT JOIN workstreams for name)
        //  2. workstreams with no tasks yet (so a freshly-created empty workstream is visible)
        const sql =
            \\SELECT t.workstream_id AS ws_id,
            \\       COALESCE(w.name, '') AS ws_name,
            \\       COALESCE(t.cnt, 0) AS task_count,
            \\       COALESCE(t.last_seen, '') AS last_seen,
            \\       COALESCE(w.created_at, '') AS created_at
            \\FROM (
            \\   SELECT workstream_id, COUNT(*) AS cnt,
            \\          COALESCE(MAX(COALESCE(completed_at, locked_until)), '') AS last_seen
            \\   FROM tasks
            \\   WHERE workstream_id IS NOT NULL AND workstream_id <> ''
            \\   GROUP BY workstream_id
            \\) AS t
            \\LEFT JOIN workstreams w ON w.workstream_id = t.workstream_id
            \\UNION ALL
            \\SELECT workstream_id AS ws_id, name AS ws_name, 0 AS task_count, '' AS last_seen, created_at AS created_at
            \\FROM workstreams
            \\WHERE workstream_id NOT IN (SELECT workstream_id FROM tasks WHERE workstream_id IS NOT NULL AND workstream_id <> '')
            \\ORDER BY last_seen DESC, created_at DESC
            \\LIMIT 500;
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        var results: std.ArrayList(types.WorkstreamInfo) = .empty;
        defer results.deinit(allocator);
        while (try stmt.step()) {
            const last = stmt.columnText(3);
            const created = stmt.columnText(4);
            results.append(allocator, .{
                .workstream_id = try allocator.dupe(u8, stmt.columnText(0)),
                .name = try allocator.dupe(u8, stmt.columnText(1)),
                .task_count = stmt.columnInt(2),
                .last_seen = try allocator.dupe(u8, if (last.len > 0) last else ""),
                .created_at = try allocator.dupe(u8, if (created.len > 0) created else ""),
            }) catch unreachable;
        }
        return try results.toOwnedSlice(allocator);
    }

    /// Create a new named workstream. The workstream_id is provided by the
    /// caller (a freshly-generated UUID). Returns error.DuplicateWorkstreamName
    /// when the name is already taken (UNIQUE constraint).
    pub fn createWorkstream(self: *SqliteStore, workstream_id: []const u8, name: []const u8) !void {
        const created_at = try self.now(self.allocator);
        defer self.allocator.free(created_at);
        const sql = "INSERT INTO workstreams (workstream_id, name, created_at) VALUES (?, ?, ?)";
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindText(1, workstream_id);
        try stmt.bindText(2, name);
        try stmt.bindText(3, created_at);
        _ = stmt.step() catch |err| {
            // Distinguish a UNIQUE-constraint violation (duplicate name) from
            // other SQLite errors (busy/disk-full/IO) by inspecting errmsg.
            const msg = sqlite.errmsgStr(self.db.handle);
            if (std.mem.indexOf(u8, msg, "UNIQUE") != null) return error.DuplicateWorkstreamName;
            return err;
        };
    }

    /// Look up a workstream by id. Returns the workstream_id (caller-owned) or
    /// null when not found. Falls back to checking tasks.workstream_id so that
    /// anonymous workstreams (no workstreams row) are still joinable by id.
    pub fn lookupWorkstreamById(self: *SqliteStore, allocator: std.mem.Allocator, workstream_id: []const u8) !?[]u8 {
        var stmt = try self.db.prepare("SELECT 1 FROM workstreams WHERE workstream_id = ?");
        defer stmt.finalize();
        try stmt.bindText(1, workstream_id);
        if (try stmt.step()) return try allocator.dupe(u8, workstream_id);
        // Fallback: an anonymous workstream exists if any task references it.
        var tstmt = try self.db.prepare("SELECT 1 FROM tasks WHERE workstream_id = ? LIMIT 1");
        defer tstmt.finalize();
        try tstmt.bindText(1, workstream_id);
        if (try tstmt.step()) return try allocator.dupe(u8, workstream_id);
        return null;
    }

    /// Look up a workstream by its (unique) name. Returns the workstream_id
    /// (caller-owned) or null when not found.
    pub fn lookupWorkstreamByName(self: *SqliteStore, allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
        var stmt = try self.db.prepare("SELECT workstream_id FROM workstreams WHERE name = ?");
        defer stmt.finalize();
        try stmt.bindText(1, name);
        if (try stmt.step()) return try allocator.dupe(u8, stmt.columnText(0));
        return null;
    }

    // ── Agent registry (P0: persisted) ────────────────────────────────────────────

    /// Create or update an agent registration.
    pub fn upsertAgent(self: *SqliteStore, agent_id: []const u8, secret: []const u8, name: ?[]const u8, skills: ?[]const u8, card_url: ?[]const u8) !void {
        const created_at = try self.now(self.allocator);
        defer self.allocator.free(created_at);
        const sql =
            \\INSERT INTO agents (agent_id, secret, name, skills, card_url, created_at)
            \\VALUES (?, ?, ?, ?, ?, ?)
            \\ON CONFLICT(agent_id) DO UPDATE SET
            \\  secret = excluded.secret,
            \\  name = COALESCE(excluded.name, agents.name),
            \\  skills = COALESCE(excluded.skills, agents.skills),
            \\  card_url = COALESCE(excluded.card_url, agents.card_url)
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindText(1, agent_id);
        try stmt.bindText(2, secret);
        if (name) |n| try stmt.bindText(3, n) else try stmt.bindNull(3);
        if (skills) |sk| try stmt.bindText(4, sk) else try stmt.bindNull(4);
        if (card_url) |cu| try stmt.bindText(5, cu) else try stmt.bindNull(5);
        try stmt.bindText(6, created_at);
        _ = try stmt.step();
    }

    /// Look up an agent's secret. Returns null when not registered.
    pub fn getAgentSecret(self: *SqliteStore, allocator: std.mem.Allocator, agent_id: []const u8) !?[]u8 {
        var stmt = try self.db.prepare("SELECT secret FROM agents WHERE agent_id = ?");
        defer stmt.finalize();
        try stmt.bindText(1, agent_id);
        if (try stmt.step()) return try allocator.dupe(u8, stmt.columnText(0));
        return null;
    }

    /// List all registered agents (admin). Caller owns the slice + records.
    pub fn listAgents(self: *SqliteStore, allocator: std.mem.Allocator) ![]types.AgentRecord {
        const sql = "SELECT agent_id, secret, name, skills, card_url, created_at FROM agents ORDER BY created_at ASC, agent_id ASC";
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        var results: std.ArrayList(types.AgentRecord) = .empty;
        defer results.deinit(allocator);
        while (try stmt.step()) {
            try results.append(allocator, .{
                .agent_id = try allocator.dupe(u8, stmt.columnText(0)),
                .secret = try allocator.dupe(u8, stmt.columnText(1)),
                .name = if (stmt.columnIsNull(2)) null else try allocator.dupe(u8, stmt.columnText(2)),
                .skills = if (stmt.columnIsNull(3)) null else try allocator.dupe(u8, stmt.columnText(3)),
                .card_url = if (stmt.columnIsNull(4)) null else try allocator.dupe(u8, stmt.columnText(4)),
                .created_at = try allocator.dupe(u8, stmt.columnText(5)),
            });
        }
        return try results.toOwnedSlice(allocator);
    }

    // ── Webhook subscriptions (P1: push) ───────────────────────────────────────────

    /// Register a webhook subscription (task- or agent-scoped).
    pub fn addWebhook(self: *SqliteStore, subscription_id: []const u8, url: []const u8, secret: []const u8, task_id: ?[]const u8, agent_id: ?[]const u8) !void {
        const created_at = try self.now(self.allocator);
        defer self.allocator.free(created_at);
        const sql =
            \\INSERT INTO webhooks (subscription_id, url, secret, task_id, agent_id, created_at)
            \\VALUES (?, ?, ?, ?, ?, ?)
            \\ON CONFLICT(subscription_id) DO UPDATE SET
            \\  url = excluded.url, secret = excluded.secret,
            \\  task_id = excluded.task_id, agent_id = excluded.agent_id
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindText(1, subscription_id);
        try stmt.bindText(2, url);
        try stmt.bindText(3, secret);
        if (task_id) |t| try stmt.bindText(4, t) else try stmt.bindNull(4);
        if (agent_id) |a| try stmt.bindText(5, a) else try stmt.bindNull(5);
        try stmt.bindText(6, created_at);
        _ = try stmt.step();
    }

    /// List webhook subscriptions matching a task and/or agent.
    pub fn listWebhooks(self: *SqliteStore, allocator: std.mem.Allocator, task_id: ?[]const u8, agent_id: ?[]const u8) ![]types.WebhookSubscription {
        const sql =
            \\SELECT subscription_id, url, secret, task_id, agent_id, created_at
            \\FROM webhooks
            \\WHERE (? IS NULL OR task_id = ?)
            \\  AND (? IS NULL OR agent_id = ?)
            \\ORDER BY created_at ASC
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        if (task_id) |t| try stmt.bindText(1, t) else try stmt.bindNull(1);
        if (task_id) |t| try stmt.bindText(2, t) else try stmt.bindNull(2);
        if (agent_id) |a| try stmt.bindText(3, a) else try stmt.bindNull(3);
        if (agent_id) |a| try stmt.bindText(4, a) else try stmt.bindNull(4);
        var results: std.ArrayList(types.WebhookSubscription) = .empty;
        defer results.deinit(allocator);
        while (try stmt.step()) {
            try results.append(allocator, .{
                .subscription_id = try allocator.dupe(u8, stmt.columnText(0)),
                .url = try allocator.dupe(u8, stmt.columnText(1)),
                .secret = try allocator.dupe(u8, stmt.columnText(2)),
                .task_id = if (stmt.columnIsNull(3)) null else try allocator.dupe(u8, stmt.columnText(3)),
                .agent_id = if (stmt.columnIsNull(4)) null else try allocator.dupe(u8, stmt.columnText(4)),
                .created_at = try allocator.dupe(u8, stmt.columnText(5)),
            });
        }
        return try results.toOwnedSlice(allocator);
    }

    /// Delete a webhook subscription. Returns false when unknown.
    pub fn deleteWebhook(self: *SqliteStore, subscription_id: []const u8) !bool {
        var stmt = try self.db.prepare("DELETE FROM webhooks WHERE subscription_id = ?");
        defer stmt.finalize();
        try stmt.bindText(1, subscription_id);
        _ = try stmt.step();
        return self.db.changes() > 0;
    }

    /// Current UTC timestamp as an ISO8601 string (caller-owned).
    fn now(self: *SqliteStore, allocator: std.mem.Allocator) ![]u8 {
        var stmt = try self.db.prepare("SELECT strftime('%Y-%m-%d %H:%M:%S', 'now')");
        defer stmt.finalize();
        if (try stmt.step()) {
            return allocator.dupe(u8, stmt.columnText(0));
        }
        return allocator.dupe(u8, "");
    }

    pub fn storeInterface(self: *SqliteStore) store.TaskStore {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = store.TaskStore.VTable{
        .deinit = struct { fn f(ctx: *anyopaque) void { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); s.deinit(); } }.f,
        .dispatch = struct { fn f(ctx: *anyopaque, t: []const u8, a: []const u8, i: []const u8, c: []const u8, p: []const u8, ws: ?[]const u8) anyerror!void { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.dispatch(t, a, i, c, p, ws); } }.f,
        .claim = struct { fn f(ctx: *anyopaque, a: std.mem.Allocator, t: []const u8, ag: []const u8) anyerror!?types.ClaimResult { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.claim(a, t, ag); } }.f,
        .complete = struct { fn f(ctx: *anyopaque, t: []const u8, a: []const u8, i: []const u8, o: []const u8) anyerror!bool { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.complete(t, a, i, o); } }.f,
        .readOutbox = struct { fn f(ctx: *anyopaque, a: std.mem.Allocator, t: []const u8, ag: []const u8, s: []const u8) anyerror![]types.OutboxResult { var slf: *SqliteStore = @ptrCast(@alignCast(ctx)); return slf.readOutbox(a, t, ag, s); } }.f,
        .fail = struct { fn f(ctx: *anyopaque, t: []const u8, a: []const u8, i: []const u8, e: []const u8) anyerror!bool { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.fail(t, a, i, e); } }.f,
        .ack = struct { fn f(ctx: *anyopaque, t: []const u8, a: []const u8, i: []const u8) anyerror!bool { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.ack(t, a, i); } }.f,
        .ackAll = struct { fn f(ctx: *anyopaque, t: []const u8, a: []const u8, before: []const u8) anyerror!types.AckResult { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.ackAll(t, a, before); } }.f,
        .purge = struct { fn f(ctx: *anyopaque) anyerror!void { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.purge(); } }.f,
        .fetchInbox = struct { fn f(ctx: *anyopaque, a: std.mem.Allocator) anyerror![]types.InboxEntry { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.fetchInbox(a); } }.f,
        .fetchOutboxAll = struct { fn f(ctx: *anyopaque, a: std.mem.Allocator) anyerror![]types.OutboxResult { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.fetchOutboxAll(a); } }.f,
        .fetchArchive = struct { fn f(ctx: *anyopaque, a: std.mem.Allocator) anyerror![]types.OutboxResult { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.fetchArchive(a); } }.f,
        .fetchWorkstreams = struct { fn f(ctx: *anyopaque, a: std.mem.Allocator) anyerror![]types.WorkstreamInfo { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.fetchWorkstreams(a); } }.f,
        .createWorkstream = struct { fn f(ctx: *anyopaque, id: []const u8, n: []const u8) anyerror!void { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.createWorkstream(id, n); } }.f,
        .lookupWorkstreamById = struct { fn f(ctx: *anyopaque, a: std.mem.Allocator, id: []const u8) anyerror!?[]u8 { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.lookupWorkstreamById(a, id); } }.f,
        .lookupWorkstreamByName = struct { fn f(ctx: *anyopaque, a: std.mem.Allocator, n: []const u8) anyerror!?[]u8 { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.lookupWorkstreamByName(a, n); } }.f,
        .dispatchAdvanced = struct { fn f(ctx: *anyopaque, a: std.mem.Allocator, t: []const u8, ag: []const u8, i: []const u8, c: []const u8, p: []const u8, ws: ?[]const u8, o: types.DispatchOptions) anyerror![]const u8 { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.dispatchAdvanced(a, t, ag, i, c, p, ws, o); } }.f,
        .heartbeat = struct { fn f(ctx: *anyopaque, a: std.mem.Allocator, t: []const u8, ag: []const u8, i: []const u8, e: i64) anyerror!?[]const u8 { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.heartbeat(a, t, ag, i, e); } }.f,
        .cancel = struct { fn f(ctx: *anyopaque, t: []const u8, ag: []const u8, i: []const u8, r: []const u8) anyerror!bool { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.cancel(t, ag, i, r); } }.f,
        .getTask = struct { fn f(ctx: *anyopaque, a: std.mem.Allocator, t: []const u8, ag: []const u8, i: []const u8) anyerror!?types.Task { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.getTask(a, t, ag, i); } }.f,
        .requestInput = struct { fn f(ctx: *anyopaque, t: []const u8, ag: []const u8, i: []const u8, q: []const u8) anyerror!bool { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.requestInput(t, ag, i, q); } }.f,
        .provideInput = struct { fn f(ctx: *anyopaque, a: std.mem.Allocator, t: []const u8, ag: []const u8, i: []const u8, inp: []const u8) anyerror!?[]const u8 { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.provideInput(a, t, ag, i, inp); } }.f,
        .upsertAgent = struct { fn f(ctx: *anyopaque, id: []const u8, sec: []const u8, n: ?[]const u8, sk: ?[]const u8, cu: ?[]const u8) anyerror!void { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.upsertAgent(id, sec, n, sk, cu); } }.f,
        .getAgentSecret = struct { fn f(ctx: *anyopaque, a: std.mem.Allocator, id: []const u8) anyerror!?[]u8 { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.getAgentSecret(a, id); } }.f,
        .listAgents = struct { fn f(ctx: *anyopaque, a: std.mem.Allocator) anyerror![]types.AgentRecord { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.listAgents(a); } }.f,
        .addWebhook = struct { fn f(ctx: *anyopaque, id: []const u8, u: []const u8, sec: []const u8, t: ?[]const u8, ag: ?[]const u8) anyerror!void { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.addWebhook(id, u, sec, t, ag); } }.f,
        .listWebhooks = struct { fn f(ctx: *anyopaque, a: std.mem.Allocator, t: ?[]const u8, ag: ?[]const u8) anyerror![]types.WebhookSubscription { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.listWebhooks(a, t, ag); } }.f,
        .deleteWebhook = struct { fn f(ctx: *anyopaque, id: []const u8) anyerror!bool { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.deleteWebhook(id); } }.f,
    };
};

test "sqlite store inbox outbox workflow" {
    const allocator = std.testing.allocator;
    const db_path = ":memory:";
    var sql_store = try SqliteStore.init(allocator, db_path);
    defer sql_store.deinit();
    const ts = sql_store.storeInterface();

    try ts.dispatch("team-1", "billing-agent", "task-101", "generate_invoice", "{\"amount\": 100}", null);

    const claim_opt = try ts.claim(allocator, "team-1", "billing-agent");
    try std.testing.expect(claim_opt != null);
    const claim = claim_opt.?;
    defer claim.deinit(allocator);
    try std.testing.expectEqualStrings("task-101", claim.task_id);
    try std.testing.expectEqualStrings("generate_invoice", claim.action);
    try std.testing.expectEqual(1, claim.try_count);

    const completed = try ts.complete("team-1", "billing-agent", "task-101", "{\"status\": \"success\"}");
    try std.testing.expect(completed);

    const outbox = try ts.readOutbox(allocator, "team-1", "billing-agent", "1970-01-01 00:00:00");
    defer { for (outbox) |o| o.deinit(allocator); allocator.free(outbox); }
    try std.testing.expectEqual(1, outbox.len);
    try std.testing.expectEqualStrings("task-101", outbox[0].task_id);
    try std.testing.expectEqualStrings("{\"status\": \"success\"}", outbox[0].output);
}

test "sqlite store fail workflow" {
    const allocator = std.testing.allocator;
    const db_path = ":memory:";
    var sql_store = try SqliteStore.init(allocator, db_path);
    defer sql_store.deinit();
    const ts = sql_store.storeInterface();

    try ts.dispatch("team-1", "billing-agent", "task-201", "process", "{}", null);
    const claim_opt = try ts.claim(allocator, "team-1", "billing-agent");
    try std.testing.expect(claim_opt != null);
    const claim = claim_opt.?;
    defer claim.deinit(allocator);

    const failed = try ts.fail("team-1", "billing-agent", "task-201", "{\"error\": \"processing failed\"}");
    try std.testing.expect(failed);

    const outbox = try ts.readOutbox(allocator, "team-1", "billing-agent", "1970-01-01 00:00:00");
    defer { for (outbox) |o| o.deinit(allocator); allocator.free(outbox); }
    try std.testing.expectEqual(1, outbox.len);
    try std.testing.expectEqualStrings("task-201", outbox[0].task_id);
    try std.testing.expectEqualStrings("{\"error\": \"processing failed\"}", outbox[0].output);
}

test "sqlite store workstream linking" {
    const allocator = std.testing.allocator;
    const db_path = ":memory:";
    var sql_store = try SqliteStore.init(allocator, db_path);
    defer sql_store.deinit();
    const ts = sql_store.storeInterface();

    // Root task: no workstream given → seeds its own workstream with its task_id.
    try ts.dispatch("team-1", "billing-agent", "root-1", "generate", "{}", null);
    // Follow-up: explicit workstream_id links it to the root's workstream.
    try ts.dispatch("team-1", "billing-agent", "follow-1", "review", "{}", "root-1");
    // Another follow-up in the same workstream.
    try ts.dispatch("team-1", "billing-agent", "follow-2", "publish", "{}", "root-1");
    // An unrelated root task seeds its own workstream.
    try ts.dispatch("team-1", "billing-agent", "root-2", "generate", "{}", null);

    // Claim the root-1 task and verify its workstream_id is itself.
    const claim1 = try ts.claim(allocator, "team-1", "billing-agent");
    try std.testing.expect(claim1 != null);
    if (claim1) |c| {
        defer c.deinit(allocator);
        try std.testing.expectEqualStrings("root-1", c.task_id);
        try std.testing.expect(c.workstream_id != null);
        if (c.workstream_id) |w| try std.testing.expectEqualStrings("root-1", w);
    }

    // Inbox listing shows workstream ids. All 4 dispatched tasks are still
    // pending (claiming root-1 only locks it; it remains in the inbox).
    const inbox = try ts.fetchInbox(allocator);
    defer { for (inbox) |t| t.deinit(allocator); allocator.free(inbox); }
    try std.testing.expectEqual(@as(usize, 4), inbox.len);
    // Each pending task carries a non-null workstream_id.
    for (inbox) |t| try std.testing.expect(t.workstream_id != null);
    // root-1 seeds its own workstream; follow-1/follow-2 share root-1's workstream;
    // root-2 has its own workstream.
    for (inbox) |t| {
        if (std.mem.eql(u8, t.task_id, "root-1")) {
            if (t.workstream_id) |w| try std.testing.expectEqualStrings("root-1", w);
        }
        if (std.mem.eql(u8, t.task_id, "follow-1")) {
            if (t.workstream_id) |w| try std.testing.expectEqualStrings("root-1", w);
        }
        if (std.mem.eql(u8, t.task_id, "follow-2")) {
            if (t.workstream_id) |w| try std.testing.expectEqualStrings("root-1", w);
        }
        if (std.mem.eql(u8, t.task_id, "root-2")) {
            if (t.workstream_id) |w| try std.testing.expectEqualStrings("root-2", w);
        }
    }
}

test "sqlite store fetchWorkstreams groups by workstream_id" {
    const allocator = std.testing.allocator;
    const db_path = ":memory:";
    var sql_store = try SqliteStore.init(allocator, db_path);
    defer sql_store.deinit();
    const ts = sql_store.storeInterface();

    // Workstream A: 3 tasks (1 root + 2 follow-ups).
    try ts.dispatch("team-1", "billing-agent", "a-root", "generate", "{}", null);
    try ts.dispatch("team-1", "billing-agent", "a-follow-1", "review", "{}", "a-root");
    try ts.dispatch("team-1", "billing-agent", "a-follow-2", "publish", "{}", "a-root");
    // Workstream B: 1 task.
    try ts.dispatch("team-1", "billing-agent", "b-root", "generate", "{}", null);

    const streams = try ts.fetchWorkstreams(allocator);
    defer { for (streams) |s| s.deinit(allocator); allocator.free(streams); }
    try std.testing.expectEqual(@as(usize, 2), streams.len);

    // Find workstream A (seeded with "a-root") and verify its count.
    var found_a = false;
    var found_b = false;
    for (streams) |s| {
        if (std.mem.eql(u8, s.workstream_id, "a-root")) {
            found_a = true;
            try std.testing.expectEqual(@as(i64, 3), s.task_count);
        }
        if (std.mem.eql(u8, s.workstream_id, "b-root")) {
            found_b = true;
            try std.testing.expectEqual(@as(i64, 1), s.task_count);
        }
    }
    try std.testing.expect(found_a);
    try std.testing.expect(found_b);
}


test "ack lifecycle: result stays in outbox until acked, then leaves reads" {
    const allocator = std.testing.allocator;
    var s = try SqliteStore.init(allocator, ":memory:");
    defer s.deinit();
    const ts = s.storeInterface();

    try ts.dispatch("team-1", "billing-agent", "task-301", "process", "{}", null);
    {
        const c = (try ts.claim(allocator, "team-1", "billing-agent")) orelse return error.ClaimFailed;
        defer c.deinit(allocator);
    }
    try std.testing.expect(try ts.complete("team-1", "billing-agent", "task-301", "{\"ok\":true}"));

    // Unconsumed result is visible in the outbox (kept as long as not consumed).
    {
        const outbox = try ts.readOutbox(allocator, "team-1", "billing-agent", "1970-01-01 00:00:00");
        defer { for (outbox) |o| o.deinit(allocator); allocator.free(outbox); }
        try std.testing.expectEqual(@as(usize, 1), outbox.len);
    }

    // Acking marks the row consumed; it disappears from readOutbox.
    try std.testing.expect(try ts.ack("team-1", "billing-agent", "task-301"));
    {
        const outbox = try ts.readOutbox(allocator, "team-1", "billing-agent", "1970-01-01 00:00:00");
        defer { for (outbox) |o| o.deinit(allocator); allocator.free(outbox); }
        try std.testing.expectEqual(@as(usize, 0), outbox.len);
    }

    // Re-acking an already-consumed result is idempotent: 200, consumed_at
    // unchanged (COALESCE), per the documented client contract.
    try std.testing.expect(try ts.ack("team-1", "billing-agent", "task-301"));

    // A pending inbox task cannot be acked (no output yet).
    try ts.dispatch("team-1", "billing-agent", "task-302", "process", "{}", null);
    try std.testing.expect(!(try ts.ack("team-1", "billing-agent", "task-302")));

    // The consumed row is still in the hot table (grace window), visible to admin.
    {
        const all = try ts.fetchOutboxAll(allocator);
        defer { for (all) |t| t.deinit(allocator); allocator.free(all); }
        // fetchOutboxAll lists completed results (pending task-302 has no output).
        try std.testing.expectEqual(@as(usize, 1), all.len);
        try std.testing.expect(all[0].consumed_at != null);
    }
}

test "ackAll consumes a bounded set and reports counts" {
    const allocator = std.testing.allocator;
    var s = try SqliteStore.init(allocator, ":memory:");
    defer s.deinit();
    const ts = s.storeInterface();

    // Two completed results.
    try ts.dispatch("team-1", "billing-agent", "task-401", "process", "{}", null);
    {
        const c = (try ts.claim(allocator, "team-1", "billing-agent")) orelse return error.ClaimFailed;
        defer c.deinit(allocator);
    }
    try std.testing.expect(try ts.complete("team-1", "billing-agent", "task-401", "{\"n\":1}"));
    try ts.dispatch("team-1", "billing-agent", "task-402", "process", "{}", null);
    {
        const c = (try ts.claim(allocator, "team-1", "billing-agent")) orelse return error.ClaimFailed;
        defer c.deinit(allocator);
    }
    try std.testing.expect(try ts.complete("team-1", "billing-agent", "task-402", "{\"n\":2}"));

    // A pending (incomplete) task must NOT be acked by ackAll.
    try ts.dispatch("team-1", "billing-agent", "task-403", "process", "{}", null);

    // ackAll with the far-future bound: consumes both results, leaves the pending task.
    const res = try ts.ackAll("team-1", "billing-agent", "9999-12-31 23:59:59");
    try std.testing.expectEqual(@as(i64, 2), res.acked);
    {
        const outbox = try ts.readOutbox(allocator, "team-1", "billing-agent", "1970-01-01 00:00:00");
        defer { for (outbox) |o| o.deinit(allocator); allocator.free(outbox); }
        try std.testing.expectEqual(@as(usize, 0), outbox.len);
    }
    {
        const inbox = try ts.fetchInbox(allocator);
        defer { for (inbox) |t| t.deinit(allocator); allocator.free(inbox); }
        try std.testing.expectEqual(@as(usize, 1), inbox.len);
        try std.testing.expectEqualStrings("task-403", inbox[0].task_id);
    }

    // Repeated ackAll acks nothing new.
    const res2 = try ts.ackAll("team-1", "billing-agent", "9999-12-31 23:59:59");
    try std.testing.expectEqual(@as(i64, 0), res2.acked);
}

test "purge archives consumed rows but never deletes inbox rows" {
    const allocator = std.testing.allocator;
    var s = try SqliteStore.init(allocator, ":memory:");
    defer s.deinit();

    // Simulate a consumed row that is past the grace window: complete + ack,
    // then backdate consumed_at so it is eligible for retirement.
    try s.dispatch("team-1", "billing-agent", "task-501", "process", "{}", null);
    {
        const c = (try s.claim(allocator, "team-1", "billing-agent")) orelse return error.ClaimFailed;
        defer c.deinit(allocator);
    }
    _ = try s.complete("team-1", "billing-agent", "task-501", "{\"ok\":true}");
    _ = try s.ack("team-1", "billing-agent", "task-501");
    {
        var stmt = try s.db.prepare(
            "UPDATE tasks SET consumed_at = datetime('now', '-2 hours') WHERE task_id = 'task-501'",
        );
        defer stmt.finalize();
        _ = try stmt.step();
    }

    // An unconsumed but old result: complete then backdate completed_at past
    // the 90-day safety net.
    try s.dispatch("team-1", "billing-agent", "task-502", "process", "{}", null);
    {
        const c = (try s.claim(allocator, "team-1", "billing-agent")) orelse return error.ClaimFailed;
        defer c.deinit(allocator);
    }
    _ = try s.complete("team-1", "billing-agent", "task-502", "{\"ok\":true}");
    {
        var stmt = try s.db.prepare(
            "UPDATE tasks SET completed_at = datetime('now', '-91 days') WHERE task_id = 'task-502'",
        );
        defer stmt.finalize();
        _ = try stmt.step();
    }

    // A pending inbox row: must survive every purge forever.
    try s.dispatch("team-1", "billing-agent", "task-503", "process", "{}", null);

    try s.purge();

    // All three rows are accounted for: 2 archived, 1 still pending.
    const archive = try s.fetchArchive(allocator);
    defer { for (archive) |t| t.deinit(allocator); allocator.free(archive); }
    try std.testing.expectEqual(@as(usize, 2), archive.len);
    const inbox = try s.fetchInbox(allocator);
    defer { for (inbox) |t| t.deinit(allocator); allocator.free(inbox); }
    try std.testing.expectEqual(@as(usize, 1), inbox.len);
    try std.testing.expectEqualStrings("task-503", inbox[0].task_id);

    // Purge is idempotent: running it again moves nothing new.
    try s.purge();
    const archive2 = try s.fetchArchive(allocator);
    defer { for (archive2) |t| t.deinit(allocator); allocator.free(archive2); }
    try std.testing.expectEqual(@as(usize, 2), archive2.len);

    // Fresh unconsumed results are NOT archived (kept until consumed).
    try s.dispatch("team-1", "billing-agent", "task-504", "process", "{}", null);
    {
        const c = (try s.claim(allocator, "team-1", "billing-agent")) orelse return error.ClaimFailed;
        defer c.deinit(allocator);
    }
    _ = try s.complete("team-1", "billing-agent", "task-504", "{\"ok\":true}");
    try s.purge();
    const archive3 = try s.fetchArchive(allocator);
    defer { for (archive3) |t| t.deinit(allocator); allocator.free(archive3); }
    try std.testing.expectEqual(@as(usize, 2), archive3.len);
}

test "readOutbox since-cursor filters by completed_at" {
    const allocator = std.testing.allocator;
    var s = try SqliteStore.init(allocator, ":memory:");
    defer s.deinit();
    const ts = s.storeInterface();

    // An old result, backdated to a fixed past timestamp — the consumer has
    // already seen everything up to `cursor`.
    try ts.dispatch("team-1", "billing-agent", "task-601", "process", "{}", null);
    {
        const c = (try ts.claim(allocator, "team-1", "billing-agent")) orelse return error.ClaimFailed;
        defer c.deinit(allocator);
    }
    try std.testing.expect(try ts.complete("team-1", "billing-agent", "task-601", "{\"n\":1}"));
    {
        var stmt = try s.db.prepare(
            "UPDATE tasks SET completed_at = '2020-01-01 00:00:00' WHERE task_id = 'task-601'",
        );
        defer stmt.finalize();
        _ = try stmt.step();
    }
    const cursor = "2020-06-01 00:00:00";

    // A fresh result completing after the cursor.
    try ts.dispatch("team-1", "billing-agent", "task-602", "process", "{}", null);
    {
        const c = (try ts.claim(allocator, "team-1", "billing-agent")) orelse return error.ClaimFailed;
        defer c.deinit(allocator);
    }
    try std.testing.expect(try ts.complete("team-1", "billing-agent", "task-602", "{\"n\":2}"));

    // Polling with since=<cursor> returns only the newer result.
    {
        const outbox = try ts.readOutbox(allocator, "team-1", "billing-agent", cursor);
        defer { for (outbox) |o| o.deinit(allocator); allocator.free(outbox); }
        try std.testing.expectEqual(@as(usize, 1), outbox.len);
        try std.testing.expectEqualStrings("task-602", outbox[0].task_id);
    }
    // Polling from the epoch returns only the fresh result: task-601 was
    // unconsumed and older than the 90-day safety net, so the piggybacked
    // purge (on task-602's dispatch) retired it to the archive. It is not
    // lost — it is queryable via the archive view.
    {
        const outbox = try ts.readOutbox(allocator, "team-1", "billing-agent", "1970-01-01 00:00:00");
        defer { for (outbox) |o| o.deinit(allocator); allocator.free(outbox); }
        try std.testing.expectEqual(@as(usize, 1), outbox.len);
        try std.testing.expectEqualStrings("task-602", outbox[0].task_id);
    }
    {
        const archive = try ts.fetchArchive(allocator);
        defer { for (archive) |t| t.deinit(allocator); allocator.free(archive); }
        try std.testing.expectEqual(@as(usize, 1), archive.len);
        try std.testing.expectEqualStrings("task-601", archive[0].task_id);
    }
}

test "ack preserves the original consumed_at on re-ack" {
    const allocator = std.testing.allocator;
    var s = try SqliteStore.init(allocator, ":memory:");
    defer s.deinit();
    const ts = s.storeInterface();

    try ts.dispatch("team-1", "billing-agent", "task-701", "process", "{}", null);
    {
        const c = (try ts.claim(allocator, "team-1", "billing-agent")) orelse return error.ClaimFailed;
        defer c.deinit(allocator);
    }
    try std.testing.expect(try ts.complete("team-1", "billing-agent", "task-701", "{\"ok\":true}"));
    try std.testing.expect(try ts.ack("team-1", "billing-agent", "task-701"));

    // Capture the consumed_at from the first ack.
    var first: []u8 = "";
    defer if (first.len > 0) allocator.free(first);
    {
        var stmt = try s.db.prepare("SELECT consumed_at FROM tasks WHERE task_id = 'task-701'");
        defer stmt.finalize();
        if (try stmt.step()) first = try allocator.dupe(u8, stmt.columnText(0));
    }

    // Re-ack returns true and must NOT bump consumed_at (COALESCE keeps it).
    try std.testing.expect(try ts.ack("team-1", "billing-agent", "task-701"));
    {
        var stmt = try s.db.prepare("SELECT consumed_at FROM tasks WHERE task_id = 'task-701'");
        defer stmt.finalize();
        if (try stmt.step()) try std.testing.expectEqualStrings(first, stmt.columnText(0));
    }
}

test "since-cursor is millisecond-exact (same-second results)" {
    const allocator = std.testing.allocator;
    var s = try SqliteStore.init(allocator, ":memory:");
    defer s.deinit();
    const ts = s.storeInterface();

    // Two results completed within the SAME second, with distinct millis.
    inline for (.{ "task-801", "task-802" }) |tid| {
        try ts.dispatch("team-1", "billing-agent", tid, "process", "{}", null);
        const c = (try ts.claim(allocator, "team-1", "billing-agent")) orelse return error.ClaimFailed;
        defer c.deinit(allocator);
        try std.testing.expect(try ts.complete("team-1", "billing-agent", tid, "{\"ok\":true}"));
    }
    // Force identical whole seconds with different fractional parts.
    {
        var stmt = try s.db.prepare(
            "UPDATE tasks SET completed_at = CASE task_id WHEN 'task-801' THEN '2020-01-01 10:00:00.123' ELSE '2020-01-01 10:00:00.456' END WHERE task_id IN ('task-801','task-802')",
        );
        defer stmt.finalize();
        _ = try stmt.step();
    }

    // A consumer holding the cursor 10:00:00.123 must still see the .456 result.
    // (datetime() truncation would make both sides equal → the row would be lost.)
    const outbox = try ts.readOutbox(allocator, "team-1", "billing-agent", "2020-01-01 10:00:00.123");
    defer { for (outbox) |o| o.deinit(allocator); allocator.free(outbox); }
    try std.testing.expectEqual(@as(usize, 1), outbox.len);
    try std.testing.expectEqualStrings("task-802", outbox[0].task_id);
}
