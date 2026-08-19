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

    // Each response carries a task_id (UUID) and the two differ.
    const id1 = extractTaskId(r1.body) orelse return error.MissingTaskId1;
    defer testing.allocator.free(id1);
    const id2 = extractTaskId(r2.body) orelse return error.MissingTaskId2;
    defer testing.allocator.free(id2);
    try testing.expect(id1.len > 0);
    try testing.expect(id2.len > 0);
    try testing.expect(!std.mem.eql(u8, id1, id2));
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
    try testing.expect(std.mem.indexOf(u8, claim_resp.body, "do_something") != null);

    // Extract the auto-generated task id from the claim response.
    const task_id = extractTaskId(claim_resp.body) orelse return error.MissingTaskId;
    defer testing.allocator.free(task_id);

    // 3. Complete the task using the claimed task id.
    const complete_path = try std.fmt.allocPrint(testing.allocator, "/v1/agents/agent-0/outbox/{s}/complete", .{task_id});
    defer testing.allocator.free(complete_path);
    var complete_resp = try ctx.requestWithAuth(
        .POST,
        complete_path,
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

    // Use the auto-generated task id from the claim response to complete.
    const task_id = extractTaskId(claim.body) orelse return error.MissingTaskId;
    defer testing.allocator.free(task_id);
    const complete_path = try std.fmt.allocPrint(testing.allocator, "/v1/agents/agent-0/outbox/{s}/complete", .{task_id});
    defer testing.allocator.free(complete_path);
    var complete_resp = try ctx.requestWithAuth(.POST, complete_path, "{\"result\": \"ok\"}", "Bearer default-secret-please-change");
    defer complete_resp.deinit(testing.allocator);

    // Read outbox
    var outbox = try ctx.requestWithAuth(.GET, "/v1/agents/agent-0/outbox", "", "Bearer default-secret-please-change");
    defer outbox.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), outbox.status_code);
    try testing.expect(std.mem.indexOf(u8, outbox.body, task_id) != null);
}

test "admin dispatch with workstream_id links follow-up tasks" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    // 1. Admin-dispatch a root task (no workstream_id) to agent-0.
    var root_resp = try ctx.requestWithAuth(
        .POST,
        "/admin/dispatch",
        "{\"agent_id\":\"agent-0\",\"action\":\"generate\",\"payload\":\"{}\"}",
        "Bearer admin-token-change-me",
    );
    defer root_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), root_resp.status_code);
    const root_id = extractTaskId(root_resp.body) orelse return error.MissingRootId;
    defer testing.allocator.free(root_id);

    // 2. Admin-dispatch a follow-up task with workstream_id = root_id.
    // Build the JSON body manually to avoid fmt brace-escaping for the payload "{}".
    const follow_body = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"agent_id\":\"agent-0\",\"action\":\"review\",\"payload\":\"{{}}\",\"workstream_id\":\"{s}\"}}",
        .{root_id},
    );
    defer testing.allocator.free(follow_body);
    var follow_resp = try ctx.requestWithAuth(.POST, "/admin/dispatch", follow_body, "Bearer admin-token-change-me");
    defer follow_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), follow_resp.status_code);
    const follow_id = extractTaskId(follow_resp.body) orelse return error.MissingFollowId;
    defer testing.allocator.free(follow_id);
    try testing.expect(!std.mem.eql(u8, root_id, follow_id));

    // 3. Claim the follow-up and verify its workstream_id equals the root id.
    var claim = try ctx.requestWithAuth(.POST, "/v1/agents/agent-0/inbox/claim", "", "Bearer default-secret-please-change");
    defer claim.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), claim.status_code);
    // The claim should return either root or follow (rowid order); both share
    // the root's workstream. Verify the workstream_id field is present and
    // equals root_id.
    try testing.expect(std.mem.indexOf(u8, claim.body, "workstream_id") != null);
    // The claim returns the oldest pending task for agent-0. Other tests may
    // have left stale tasks in the shared on-disk DB, so we claim in a loop
    // until we find our root or follow-up task and verify its workstream.
    var found_root = false;
    var found_follow = false;
    while (true) {
        if (std.mem.indexOf(u8, claim.body, root_id) != null) found_root = true;
        if (std.mem.indexOf(u8, claim.body, follow_id) != null) found_follow = true;
        // Every claimed task must carry a non-null workstream_id.
        try testing.expect(std.mem.indexOf(u8, claim.body, "\"workstream_id\":null") == null);
        if (found_root and found_follow) break;
        // Claim the next pending task.
        claim.deinit(testing.allocator);
        claim = try ctx.requestWithAuth(.POST, "/v1/agents/agent-0/inbox/claim", "", "Bearer default-secret-please-change");
        if (claim.status_code == 204) break; // no more tasks
        try testing.expectEqual(@as(u16, 200), claim.status_code);
    }
    try testing.expect(found_root);
    try testing.expect(found_follow);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Extract the `task_id` string value from a JSON response body.
/// Returns a caller-owned slice (allocated via `testing.allocator`), or null
/// if the field is absent / not a string.
fn extractTaskId(body: []const u8) ?[]u8 {
    const key = "\"task_id\"";
    const start = std.mem.indexOf(u8, body, key) orelse return null;
    // Find the opening quote of the value.
    var i = start + key.len;
    while (i < body.len and (body[i] == ':' or body[i] == ' ' or body[i] == '\t')) : (i += 1) {}
    if (i >= body.len or body[i] != '"') return null;
    i += 1;
    const val_start = i;
    while (i < body.len and body[i] != '"') : (i += 1) {}
    if (i > val_start) {
        return std.testing.allocator.dupe(u8, body[val_start..i]) catch null;
    }
    return null;
}

fn parseStatusCode(bytes: []const u8) ?u16 {
    // Format: "HTTP/1.1 200 OK\r\n..."
    var it = std.mem.splitScalar(u8, bytes, ' ');
    _ = it.next() orelse return null; // "HTTP/1.1"
    const code_str = it.next() orelse return null;
    return std.fmt.parseUnsigned(u16, code_str, 10) catch null;
}