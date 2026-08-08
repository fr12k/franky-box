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
        try db.exec("PRAGMA cache_size = -65536"); // 64 MB
        try db.exec("PRAGMA foreign_keys = ON");

        try createSchema(&db);

        return .{
            .allocator = allocator,
            .db = db,
        };
    }

    pub fn deinit(self: *SqliteStore) void {
        self.db.close();
    }

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
            \\  completed_at TEXT DEFAULT NULL
            \\);
        );
        try db.exec("CREATE INDEX IF NOT EXISTS idx_tasks_routing ON tasks (tenant_id, agent_id, output, locked_until)");
    }

    pub fn dispatch(
        self: *SqliteStore,
        tenant_id: []const u8,
        agent_id: []const u8,
        task_id: []const u8,
        action: []const u8,
        payload: []const u8,
    ) !void {
        try self.purge();

        const sql =
            "INSERT INTO tasks (tenant_id, agent_id, task_id, action, payload) " ++
            "VALUES (?, ?, ?, ?, ?)";
        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();

        try stmt.bindText(1, tenant_id);
        try stmt.bindText(2, agent_id);
        try stmt.bindText(3, task_id);
        try stmt.bindText(4, action);
        try stmt.bindText(5, payload);

        _ = try stmt.step();
    }

    pub fn claim(
        self: *SqliteStore,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
        agent_id: []const u8,
    ) !?types.ClaimResult {
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
            \\RETURNING task_id, action, payload, try_count;
        ;

        var stmt = try self.db.prepare(sql);
        defer stmt.finalize();

        try stmt.bindText(1, tenant_id);
        try stmt.bindText(2, agent_id);

        if (try stmt.step()) {
            return types.ClaimResult{
                .task_id = try allocator.dupe(u8, stmt.columnText(0)),
                .action = try allocator.dupe(u8, stmt.columnText(1)),
                .payload = try allocator.dupe(u8, stmt.columnText(2)),
                .try_count = @intCast(stmt.columnInt(3)),
            };
        }

        return null;
    }

    pub fn complete(
        self: *SqliteStore,
        tenant_id: []const u8,
        agent_id: []const u8,
        task_id: []const u8,
        output: []const u8,
    ) !bool {
        const sql =
            \\UPDATE tasks
            \\SET
            \\   output = ?,
            \\   completed_at = strftime('%Y-%m-%d %H:%M:%f', 'now'),
            \\   locked_until = NULL
            \\WHERE tenant_id = ?
            \\  AND agent_id = ?
            \\  AND task_id = ?;
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

    pub fn readOutbox(
        self: *SqliteStore,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
        agent_id: []const u8,
        since_timestamp: []const u8,
    ) ![]types.OutboxResult {
        const sql =
            \\SELECT task_id, action, payload, output, completed_at
            \\FROM tasks
            \\WHERE tenant_id = ?
            \\  AND agent_id = ?
            \\  AND output IS NOT NULL
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
        errdefer {
            for (results.items) |r| r.deinit(allocator);
        }

        while (try stmt.step()) {
            try results.append(allocator, .{
                .task_id = try allocator.dupe(u8, stmt.columnText(0)),
                .action = try allocator.dupe(u8, stmt.columnText(1)),
                .payload = try allocator.dupe(u8, stmt.columnText(2)),
                .output = try allocator.dupe(u8, stmt.columnText(3)),
                .completed_at = try allocator.dupe(u8, stmt.columnText(4)),
            });
        }

        return try results.toOwnedSlice(allocator);
    }

    pub fn purge(self: *SqliteStore) !void {
        const sql =
            \\DELETE FROM tasks
            \\WHERE completed_at IS NOT NULL
            \\  AND datetime(completed_at) <= datetime('now', '-7 days');
        ;
        try self.db.exec(sql);
    }

    // ── VTable mapping ────────────────────────────────────────────────
    
    pub fn storeInterface(self: *SqliteStore) store.TaskStore {
        return .{
            .ctx = self,
            .vtable = &vtable,
        };
    }

    const vtable = store.TaskStore.VTable{
        .deinit = struct {
            fn f(ctx: *anyopaque) void {
                var self: *SqliteStore = @ptrCast(@alignCast(ctx));
                self.deinit();
            }
        }.f,
        .dispatch = struct {
            fn f(ctx: *anyopaque, tenant_id: []const u8, agent_id: []const u8, task_id: []const u8, action: []const u8, payload: []const u8) anyerror!void {
                var self: *SqliteStore = @ptrCast(@alignCast(ctx));
                return self.dispatch(tenant_id, agent_id, task_id, action, payload);
            }
        }.f,
        .claim = struct {
            fn f(ctx: *anyopaque, allocator: std.mem.Allocator, tenant_id: []const u8, agent_id: []const u8) anyerror!?types.ClaimResult {
                var self: *SqliteStore = @ptrCast(@alignCast(ctx));
                return self.claim(allocator, tenant_id, agent_id);
            }
        }.f,
        .complete = struct {
            fn f(ctx: *anyopaque, tenant_id: []const u8, agent_id: []const u8, task_id: []const u8, output: []const u8) anyerror!bool {
                var self: *SqliteStore = @ptrCast(@alignCast(ctx));
                return self.complete(tenant_id, agent_id, task_id, output);
            }
        }.f,
        .readOutbox = struct {
            fn f(ctx: *anyopaque, allocator: std.mem.Allocator, tenant_id: []const u8, agent_id: []const u8, since_timestamp: []const u8) anyerror![]types.OutboxResult {
                var self: *SqliteStore = @ptrCast(@alignCast(ctx));
                return self.readOutbox(allocator, tenant_id, agent_id, since_timestamp);
            }
        }.f,
        .purge = struct {
            fn f(ctx: *anyopaque) anyerror!void {
                var self: *SqliteStore = @ptrCast(@alignCast(ctx));
                return self.purge();
            }
        }.f,
    };
};

test "sqlite store inbox outbox workflow" {
    const allocator = std.testing.allocator;
    const db_path = ":memory:";

    var sql_store = try SqliteStore.init(allocator, db_path);
    defer sql_store.deinit();

    const ts = sql_store.storeInterface();

    try ts.dispatch("team-1", "billing-agent", "task-101", "generate_invoice", "{\"amount\": 100}");

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
    defer {
        for (outbox) |o| o.deinit(allocator);
        allocator.free(outbox);
    }

    try std.testing.expectEqual(1, outbox.len);
    try std.testing.expectEqualStrings("task-101", outbox[0].task_id);
    try std.testing.expectEqualStrings("{\"status\": \"success\"}", outbox[0].output);
}
