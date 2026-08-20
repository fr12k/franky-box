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
            \\  workstream_id TEXT DEFAULT NULL
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
        try db.exec("CREATE INDEX IF NOT EXISTS idx_tasks_routing ON tasks (tenant_id, agent_id, output, locked_until)");
        try db.exec("CREATE INDEX IF NOT EXISTS idx_tasks_workstream ON tasks (workstream_id)");
        try db.exec("CREATE INDEX IF NOT EXISTS idx_workstreams_name ON workstreams (name)");
    }

    /// Add a column to a table only if it does not already exist.
    fn addColumnIfMissing(db: *sqlite.Db, table: []const u8, column: []const u8, decl: []const u8) !void {
        var buf: [256]u8 = undefined;
        const sql = try std.fmt.bufPrint(&buf, "SELECT COUNT(*) FROM pragma_table_info('{s}') WHERE name='{s}'", .{ table, column });
        var stmt = try db.prepare(sql);
        defer stmt.finalize();
        if (try stmt.step()) {
            if (stmt.columnInt(0) > 0) return; // column already present
        }
        var buf2: [256]u8 = undefined;
        const alter = try std.fmt.bufPrint(&buf2, "ALTER TABLE {s} ADD COLUMN {s} {s}", .{ table, column, decl });
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
            \\SELECT task_id, action, payload, output, completed_at, workstream_id
            \\FROM tasks
            \\WHERE tenant_id = ? AND agent_id = ? AND output IS NOT NULL AND datetime(completed_at) > datetime(?)
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
            try results.append(allocator, .{
                .task_id = try allocator.dupe(u8, stmt.columnText(0)),
                .action = try allocator.dupe(u8, stmt.columnText(1)),
                .payload = try allocator.dupe(u8, stmt.columnText(2)),
                .output = try allocator.dupe(u8, stmt.columnText(3)),
                .completed_at = try allocator.dupe(u8, stmt.columnText(4)),
                .workstream_id = if (ws.len > 0) try allocator.dupe(u8, ws) else null,
            });
        }
        return try results.toOwnedSlice(allocator);
    }

    pub fn purge(self: *SqliteStore) !void {
        try self.db.exec(
            \\DELETE FROM tasks WHERE completed_at IS NOT NULL AND datetime(completed_at) <= datetime('now', '-7 days');
        );
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
            \\SELECT task_id, action, payload, output, completed_at, workstream_id
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
            results.append(allocator, .{
                .task_id = try allocator.dupe(u8, stmt.columnText(0)),
                .action = try allocator.dupe(u8, stmt.columnText(1)),
                .payload = try allocator.dupe(u8, stmt.columnText(2)),
                .output = try allocator.dupe(u8, stmt.columnText(3)),
                .completed_at = try allocator.dupe(u8, stmt.columnText(4)),
                .workstream_id = if (ws.len > 0) try allocator.dupe(u8, ws) else null,
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
        .purge = struct { fn f(ctx: *anyopaque) anyerror!void { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.purge(); } }.f,
        .fetchInbox = struct { fn f(ctx: *anyopaque, a: std.mem.Allocator) anyerror![]types.InboxEntry { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.fetchInbox(a); } }.f,
        .fetchOutboxAll = struct { fn f(ctx: *anyopaque, a: std.mem.Allocator) anyerror![]types.OutboxResult { var s: *SqliteStore = @ptrCast(@alignCast(ctx)); return s.fetchOutboxAll(a); } }.f,
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
