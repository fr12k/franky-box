//! Integration tests for franky-box HTTP API.
//!
//! These tests exercise the full handler stack by building raw HTTP requests
//! in-memory and passing them through the server's handle function.

const std = @import("std");
const http = std.http;
const testing = std.testing;

const franky = @import("franky_box");

var test_db_counter: u64 = 0;

const TestContext = struct {
    allocator: std.mem.Allocator,
    store_backend: *franky.SqliteStore,
    ts: *franky.TaskStore,
    server: franky.Server,

    fn init(allocator: std.mem.Allocator) !TestContext {
        const db_id = @atomicRmw(u64, &test_db_counter, .Add, 1, .monotonic);

        // Build null-terminated path on the stack.
        var db_buf: [128]u8 = undefined;
        const db_path_noz = try std.fmt.bufPrint(&db_buf, "/tmp/franky-box-test-{d}.db", .{db_id});
        db_buf[db_path_noz.len] = 0;
        const db_path: [:0]const u8 = db_buf[0..db_path_noz.len :0];

        var store_backend = try allocator.create(franky.SqliteStore);
        errdefer allocator.destroy(store_backend);
        store_backend.* = try franky.SqliteStore.init(allocator, db_path);
        errdefer store_backend.deinit();

        const ts = try allocator.create(franky.TaskStore);
        errdefer allocator.destroy(ts);
        ts.* = store_backend.storeInterface();

        // The Server needs Io for random bytes in registerDefaultAgent.
        // Use the testing Io instance which is initialized by the test runner.
        var server = franky.Server.init(allocator, std.testing.io, ts);
        errdefer server.deinit();
        try server.registerDefaultAgent();

        return .{
            .allocator = allocator,
            .store_backend = store_backend,
            .ts = ts,
            .server = server,
        };
    }

    fn deinit(self: *TestContext) void {
        self.server.deinit();
        self.allocator.destroy(self.ts);
        self.store_backend.deinit();
        self.allocator.destroy(self.store_backend);
    }

    /// Build raw HTTP bytes, feed through handleWithPath, return parsed response.
    fn request(
        self: *TestContext,
        method: http.Method,
        path: []const u8,
        body_str: []const u8,
    ) !TestResponse {
        return self.requestWithAuth(method, path, body_str, "");
    }

    fn requestWithAuth(
        self: *TestContext,
        method: http.Method,
        path: []const u8,
        body_str: []const u8,
        auth_header: []const u8,
    ) !TestResponse {
        const a = self.allocator;

        // Build raw HTTP request bytes
        var req_buf = std.ArrayList(u8).empty;
        defer req_buf.deinit(a);

        try req_buf.appendSlice(a, @tagName(method));
        try req_buf.append(a, ' ');
        try req_buf.appendSlice(a, path);
        try req_buf.appendSlice(a, " HTTP/1.1\r\n");
        try req_buf.appendSlice(a, "Host: test\r\n");
        if (auth_header.len > 0) {
            try req_buf.appendSlice(a, "Authorization: ");
            try req_buf.appendSlice(a, auth_header);
            try req_buf.appendSlice(a, "\r\n");
        }
        if (body_str.len > 0) {
            try req_buf.appendSlice(a, "Content-Length: ");
            const cl_str = try std.fmt.allocPrint(a, "{d}\r\n", .{body_str.len});
            defer a.free(cl_str);
            try req_buf.appendSlice(a, cl_str);
        }
        try req_buf.appendSlice(a, "\r\n");
        if (body_str.len > 0) {
            try req_buf.appendSlice(a, body_str);
        }

        const request_bytes = req_buf.items;

        // Build a fixed reader with the request
        var write_buf: [4096]u8 = undefined;

        var io_reader = std.Io.Reader.fixed(request_bytes);
        var io_writer = std.Io.Writer.fixed(&write_buf);

        var http_server = http.Server.init(&io_reader, &io_writer);
        var req = try http_server.receiveHead();

        // Read the body if present
        const body = if (req.head.content_length) |cl| blk: {
            if (cl > 0) {
                var buf: [4096]u8 = undefined;
                var body_reader = req.readerExpectNone(&buf);
                const body_bytes = try body_reader.allocRemaining(a, .unlimited);
                break :blk body_bytes;
            }
            break :blk "";
        } else blk: {
            // For bodyless POST, still transition the state
            if (req.head.method.requestHasBody()) {
                var buf: [1]u8 = undefined;
                _ = req.readerExpectNone(&buf);
            }
            break :blk "";
        };
        defer if (body.len > 0) a.free(body);

        // Call the handler with a pre-saved path (since readerExpectNone
        // invalidates head strings).
        const saved_path = try a.dupe(u8, path);
        defer a.free(saved_path);

        self.server.handleWithPath(&req, saved_path, body) catch {};

        // Read the response from the writer buffer
        const resp_bytes = io_writer.buffered();
        const status_code = parseStatusCode(resp_bytes) orelse 0;

        // Extract body after "\r\n\r\n"
        const body_start = std.mem.indexOfPos(u8, resp_bytes, 0, "\r\n\r\n") orelse resp_bytes.len;
        const resp_body_start = body_start + 4;
        const resp_body = if (resp_body_start < resp_bytes.len) resp_bytes[resp_body_start..] else "";

        return .{
            .status_code = status_code,
            .body = try a.dupe(u8, resp_body),
        };
    }
};

const TestResponse = struct {
    status_code: u16,
    body: []const u8,

    fn deinit(self: *const TestResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

test "register agent — POST /v1/agents without body" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    var resp = try ctx.request(.POST, "/v1/agents", "");
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), resp.status_code);
    try testing.expect(resp.body.len > 0);
    try testing.expect(std.mem.indexOf(u8, resp.body, "agent_id") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "agent_secret") != null);
}

test "dispatch task — POST /v1/tasks/dispatch with JSON body" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    var resp = try ctx.request(.POST, "/v1/tasks/dispatch", "{\"text\": \"hello\"}");
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), resp.status_code);
    try testing.expect(std.mem.indexOf(u8, resp.body, "task_id") != null);
    try testing.expect(std.mem.indexOf(u8, resp.body, "dispatched") != null);
}

test "dispatch multiple tasks — each gets a unique task_id" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    var r1 = try ctx.request(.POST, "/v1/tasks/dispatch", "{\"n\": 1}");
    defer r1.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), r1.status_code);

    var r2 = try ctx.request(.POST, "/v1/tasks/dispatch", "{\"n\": 2}");
    defer r2.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), r2.status_code);

    // Task IDs should be different
    try testing.expect(std.mem.indexOf(u8, r1.body, "task-0") != null);
    try testing.expect(std.mem.indexOf(u8, r2.body, "task-1") != null);
}

test "dispatch with plain text body (no Content-Type)" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    var resp = try ctx.request(.POST, "/v1/tasks/dispatch", "What is the capital of Germany");
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), resp.status_code);
    try testing.expect(std.mem.indexOf(u8, resp.body, "task_id") != null);
}

test "claim and complete a task — full workflow" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    // 1. Dispatch a task
    var dispatch_resp = try ctx.request(.POST, "/v1/tasks/dispatch", "{\"work\": \"do_something\"}");
    defer dispatch_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), dispatch_resp.status_code);

    // 2. Claim the task
    var claim_resp = try ctx.requestWithAuth(
        .POST,
        "/v1/agents/agent-0/inbox/claim",
        "",
        "Bearer default-secret-please-change",
    );
    defer claim_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), claim_resp.status_code);
    try testing.expect(std.mem.indexOf(u8, claim_resp.body, "task-0") != null);
    try testing.expect(std.mem.indexOf(u8, claim_resp.body, "do_something") != null);

    // 3. Complete the task
    var complete_resp = try ctx.requestWithAuth(
        .POST,
        "/v1/agents/agent-0/outbox/task-0/complete",
        "{\"result\": \"done\"}",
        "Bearer default-secret-please-change",
    );
    defer complete_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), complete_resp.status_code);
    try testing.expect(std.mem.indexOf(u8, complete_resp.body, "completed") != null);
}

test "claim returns 204 No Content when no tasks available" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    var resp = try ctx.requestWithAuth(
        .POST,
        "/v1/agents/agent-0/inbox/claim",
        "",
        "Bearer default-secret-please-change",
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 204), resp.status_code);
}

test "unauthorized request returns 401" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    var resp = try ctx.requestWithAuth(
        .POST,
        "/v1/agents/agent-0/inbox/claim",
        "",
        "Bearer wrong-token",
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 401), resp.status_code);
}

test "method not allowed returns 405" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    var resp = try ctx.request(.GET, "/v1/tasks/dispatch", "");
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 405), resp.status_code);
}

test "unknown route returns 404" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    var resp = try ctx.request(.GET, "/v1/unknown", "");
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 404), resp.status_code);
}

test "read outbox after completing a task" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    // Dispatch and complete a task
    var dispatch_resp = try ctx.request(.POST, "/v1/tasks/dispatch", "\"test payload\"");
    defer dispatch_resp.deinit(testing.allocator);

    var claim = try ctx.requestWithAuth(.POST, "/v1/agents/agent-0/inbox/claim", "", "Bearer default-secret-please-change");
    defer claim.deinit(testing.allocator);

    var complete_resp = try ctx.requestWithAuth(.POST, "/v1/agents/agent-0/outbox/task-0/complete", "{\"result\": \"ok\"}", "Bearer default-secret-please-change");
    defer complete_resp.deinit(testing.allocator);

    // Read outbox
    var outbox = try ctx.requestWithAuth(.GET, "/v1/agents/agent-0/outbox", "", "Bearer default-secret-please-change");
    defer outbox.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), outbox.status_code);
    try testing.expect(std.mem.indexOf(u8, outbox.body, "task-0") != null);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn parseStatusCode(bytes: []const u8) ?u16 {
    // Format: "HTTP/1.1 200 OK\r\n..."
    var it = std.mem.splitScalar(u8, bytes, ' ');
    _ = it.next() orelse return null; // "HTTP/1.1"
    const code_str = it.next() orelse return null;
    return std.fmt.parseUnsigned(u16, code_str, 10) catch null;
}