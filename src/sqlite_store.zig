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
            \\  consumed_at TEXT DEFAULT NULL
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
        addColumnIfMissing(db, "tasks", "consumed_at", "TEXT DEFAULT NULL") catch {};
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
            \\  archived_at TEXT NOT NULL
            \\);
        );
        try db.exec("CREATE INDEX IF NOT EXISTS idx_tasks_routing ON tasks (tenant_id, agent_id, output, locked_until)");
        try db.exec("CREATE INDEX IF NOT EXISTS idx_tasks_workstream ON tasks (workstream_id)");
        try db.exec("CREATE INDEX IF NOT EXISTS idx_workstreams_name ON workstreams (name)");
        // Purge scans completed_at over completed rows only — a partial index
        // keeps it tiny and makes the piggybacked purge cheap forever.
        try db.exec("CREATE INDEX IF NOT EXISTS idx_tasks_completed ON tasks (completed_at) WHERE completed_at IS NOT NULL");
        try db.exec("CREATE INDEX IF NOT EXISTS idx_tasks_consumed ON tasks (consumed_at) WHERE consumed_at IS NOT NULL");
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

    pub fn claim(self: *SqliteStore, allocator: std.mem.Allocator, tenant_id: []const u8, agent_id: []const u8) !?types.ClaimResult {
        try self.purge();
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
            \\   ORDER BY rowid ASC
            \\   LIMIT 1
            \\)
            \\RETURNING task_id, action, payload, try_count, workstream_id;
        ;
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();
        try stmt.bindText(1, tenant_id);
        try stmt.bindText(2, agent_id);
        if (try stmt.step()) {
            const ws = stmt.columnText(4);
            return types.ClaimResult{
                .task_id = try allocator.dupe(u8, stmt.columnText(0)),
                .action = try allocator.dupe(u8, stmt.columnText(1)),
                .payload = try allocator.dupe(u8, stmt.columnText(2)),
                .try_count = @intCast(stmt.columnInt(3)),
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
            \\WHERE tenant_id = ? AND agent_id = ? AND task_id = ?;
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

    pub fn readOutbox(self: *SqliteStore, allocator: std.mem.Allocator, tenant_id: []const u8, agent_id: []const u8, since_timestamp: []const u8) ![]types.OutboxResult {
        const sql =
            \\SELECT task_id, action, payload, output, completed_at, workstream_id, consumed_at
            \\FROM tasks
            \\WHERE tenant_id = ? AND agent_id = ? AND output IS NOT NULL AND consumed_at IS NULL
            \\  AND datetime(completed_at) > datetime(?)
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
        // Step 2: remove the retired rows from the hot table.
        try self.db.exec(
            \\DELETE FROM tasks
            \\WHERE task_id IN (SELECT task_id FROM tasks_archive)
            \\  AND output IS NOT NULL
            \\  AND (
            \\       (consumed_at IS NOT NULL AND datetime(consumed_at) <= datetime('now', '-1 hours'))
            \\    OR (consumed_at IS NULL AND completed_at IS NOT NULL
            \\        AND datetime(completed_at) <= datetime('now', '-90 days'))
            \\  );
        );
    }

    /// Acknowledge (consume) a single outbox result. The row stays in the hot
    /// table until the next purge pass retires it to the archive.
    pub fn ack(self: *SqliteStore, tenant_id: []const u8, agent_id: []const u8, task_id: []const u8) !bool {
        const sql =
            \\UPDATE tasks
            \\SET consumed_at = strftime('%Y-%m-%d %H:%M:%f', 'now')
            \\WHERE tenant_id = ? AND agent_id = ? AND task_id = ?
            \\  AND output IS NOT NULL AND consumed_at IS NULL;
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
        {
            const sql =
                \\UPDATE tasks
                \\SET consumed_at = strftime('%Y-%m-%d %H:%M:%f', 'now')
                \\WHERE tenant_id = ? AND agent_id = ?
                \\  AND output IS NOT NULL AND consumed_at IS NULL
                \\  AND datetime(completed_at) <= datetime(?);
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
        // Count what just moved to the archive for this agent.
        var archived: i64 = 0;
        {
            const sql =
                \\SELECT COUNT(*) FROM tasks_archive WHERE agent_id = ?
                \\  AND datetime(archived_at) >= datetime('now', '-5 seconds');
            ;
            var stmt = try self.db.prepare(sql);
            defer stmt.finalize();
            try stmt.bindText(1, agent_id);
            if (try stmt.step()) archived = stmt.columnInt(0);
        }
        return .{ .acked = acked, .archived = archived };
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

    // Double-ack is a no-op (row already consumed → false, idempotent).
    try std.testing.expect(!(try ts.ack("team-1", "billing-agent", "task-301")));

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
