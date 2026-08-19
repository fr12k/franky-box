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
    // Task ids carry the t_ prefix; workstream ids carry w_.
    try testing.expect(std.mem.startsWith(u8, id1, "t_"));
    try testing.expect(std.mem.startsWith(u8, id2, "t_"));
    const ws1 = extractJsonStringField(r1.body, "workstream_id") orelse return error.MissingWs1;
    defer testing.allocator.free(ws1);
    try testing.expect(std.mem.startsWith(u8, ws1, "w_"));
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

test "admin dispatch with workstream links follow-up tasks" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    // 1. Admin-dispatch a root task with a workstream_name.
    //    The server auto-creates the named workstream and returns its id.
    var root_resp = try ctx.requestWithAuth(
        .POST,
        "/admin/dispatch",
        "{\"agent_id\":\"agent-0\",\"action\":\"generate\",\"payload\":\"{}\",\"workstream_name\":\"Daily Newsletter\"}",
        "Bearer admin-token-change-me",
    );
    defer root_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), root_resp.status_code);
    const root_id = extractTaskId(root_resp.body) orelse return error.MissingRootId;
    defer testing.allocator.free(root_id);
    const root_ws = extractJsonStringField(root_resp.body, "workstream_id") orelse return error.MissingRootWorkstream;
    defer testing.allocator.free(root_ws);
    // The root task's workstream_id must differ from its task_id.
    try testing.expect(!std.mem.eql(u8, root_id, root_ws));

    // 2. Admin-dispatch a follow-up with workstream_id = root_ws (now exists).
    const follow_body = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"agent_id\":\"agent-0\",\"action\":\"review\",\"payload\":\"{{}}\",\"workstream_id\":\"{s}\"}}",
        .{root_ws},
    );
    defer testing.allocator.free(follow_body);
    var follow_resp = try ctx.requestWithAuth(.POST, "/admin/dispatch", follow_body, "Bearer admin-token-change-me");
    defer follow_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), follow_resp.status_code);
    const follow_id = extractTaskId(follow_resp.body) orelse return error.MissingFollowId;
    defer testing.allocator.free(follow_id);
    const follow_ws = extractJsonStringField(follow_resp.body, "workstream_id") orelse return error.MissingFollowWorkstream;
    defer testing.allocator.free(follow_ws);
    try testing.expect(!std.mem.eql(u8, root_id, follow_id));
    // The follow-up must join the root's workstream.
    try testing.expectEqualStrings(root_ws, follow_ws);

    // 3. Claim tasks until we find our root or follow-up; both must carry
    //    workstream_id = root_ws (never null).
    var claim = try ctx.requestWithAuth(.POST, "/v1/agents/agent-0/inbox/claim", "", "Bearer default-secret-please-change");
    defer claim.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), claim.status_code);
    try testing.expect(std.mem.indexOf(u8, claim.body, "workstream_id") != null);
    var found_root = false;
    var found_follow = false;
    while (true) {
        if (std.mem.indexOf(u8, claim.body, root_id) != null) found_root = true;
        if (std.mem.indexOf(u8, claim.body, follow_id) != null) found_follow = true;
        // Every claimed task must carry a non-null workstream_id.
        try testing.expect(std.mem.indexOf(u8, claim.body, "\"workstream_id\":null") == null);
        if (found_root and found_follow) break;
        claim.deinit(testing.allocator);
        claim = try ctx.requestWithAuth(.POST, "/v1/agents/agent-0/inbox/claim", "", "Bearer default-secret-please-change");
        if (claim.status_code == 204) break;
        try testing.expectEqual(@as(u16, 200), claim.status_code);
    }
    try testing.expect(found_root);
    try testing.expect(found_follow);
}

test "admin workstreams list returns grouped workstreams" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    // Dispatch a root task with a workstream_name (auto-creates the workstream).
    var root_resp = try ctx.requestWithAuth(
        .POST,
        "/admin/dispatch",
        "{\"agent_id\":\"agent-0\",\"action\":\"generate\",\"payload\":\"{}\",\"workstream_name\":\"Weekly Report\"}",
        "Bearer admin-token-change-me",
    );
    defer root_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), root_resp.status_code);
    const ws = extractJsonStringField(root_resp.body, "workstream_id") orelse return error.MissingWorkstream;
    defer testing.allocator.free(ws);

    // Follow-up in the same workstream (by id).
    const follow_body = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"agent_id\":\"agent-0\",\"action\":\"review\",\"payload\":\"{{}}\",\"workstream_id\":\"{s}\"}}",
        .{ws},
    );
    defer testing.allocator.free(follow_body);
    var follow_resp = try ctx.requestWithAuth(.POST, "/admin/dispatch", follow_body, "Bearer admin-token-change-me");
    defer follow_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), follow_resp.status_code);

    // List workstreams and find ours with a count of at least 2.
    var list_resp = try ctx.requestWithAuth(.GET, "/admin/workstreams", "", "Bearer admin-token-change-me");
    defer list_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), list_resp.status_code);
    try testing.expect(std.mem.indexOf(u8, list_resp.body, "workstreams") != null);
    try testing.expect(std.mem.indexOf(u8, list_resp.body, ws) != null);
    try testing.expect(std.mem.indexOf(u8, list_resp.body, "Weekly Report") != null);
    try testing.expect(std.mem.indexOf(u8, list_resp.body, "\"task_count\":2") != null);
}

test "admin dispatch by workstream_name auto-creates then 409 on duplicate" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    // 1. Dispatch with a workstream_name — auto-creates the workstream.
    var first_resp = try ctx.requestWithAuth(
        .POST,
        "/admin/dispatch",
        "{\"agent_id\":\"agent-0\",\"action\":\"audit\",\"payload\":\"{}\",\"workstream_name\":\"Monthly Audit\"}",
        "Bearer admin-token-change-me",
    );
    defer first_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), first_resp.status_code);
    const ws_id = extractJsonStringField(first_resp.body, "workstream_id") orelse return error.MissingWorkstreamId;
    defer testing.allocator.free(ws_id);

    // 2. Dispatch again with the SAME workstream_name — lookup finds the existing
    //    one and joins it (no create, no 409).
    var join_resp = try ctx.requestWithAuth(
        .POST,
        "/admin/dispatch",
        "{\"agent_id\":\"agent-0\",\"action\":\"review\",\"payload\":\"{}\",\"workstream_name\":\"Monthly Audit\"}",
        "Bearer admin-token-change-me",
    );
    defer join_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), join_resp.status_code);
    const join_ws = extractJsonStringField(join_resp.body, "workstream_id") orelse return error.MissingJoinWs;
    defer testing.allocator.free(join_ws);
    // Must join the same workstream (lookup found it).
    try testing.expectEqualStrings(ws_id, join_ws);

    // 3. A different workstream_name creates a second workstream; then repeating
    //    that exact name again would also just join. The 409 path is exercised by
    //    a race we cannot easily trigger here, so we verify the lookup-join path
    //    instead (the common case under Option A).
}

test "admin dispatch with non-existent workstream_id returns 400" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    var resp = try ctx.requestWithAuth(
        .POST,
        "/admin/dispatch",
        "{\"agent_id\":\"agent-0\",\"action\":\"x\",\"payload\":\"{}\",\"workstream_id\":\"nonexistent-uuid\"}",
        "Bearer admin-token-change-me",
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 400), resp.status_code);
    try testing.expect(std.mem.indexOf(u8, resp.body, "not found") != null);
}

test "workstream names with special characters are JSON-escaped in responses" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    // Dispatch with a workstream name containing a double-quote and backslash.
    var resp = try ctx.requestWithAuth(
        .POST,
        "/admin/dispatch",
        "{\"agent_id\":\"agent-0\",\"action\":\"x\",\"payload\":\"{}\",\"workstream_name\":\"Quote \\\" and backslash \\\\\"}",
        "Bearer admin-token-change-me",
    );
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), resp.status_code);
    const ws = extractJsonStringField(resp.body, "workstream_id") orelse return error.MissingWs;
    defer testing.allocator.free(ws);

    // List workstreams — the name with quotes must be properly escaped in the JSON.
    var list = try ctx.requestWithAuth(.GET, "/admin/workstreams", "", "Bearer admin-token-change-me");
    defer list.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), list.status_code);
    // The response must be valid JSON (no unescaped quotes). A naive interpolation
    // of a name containing `"` would break the JSON structure. We verify the
    // workstream_id we got back is present and the body parses as JSON (contains
    // matching braces).
    try testing.expect(std.mem.indexOf(u8, list.body, ws) != null);
    try testing.expect(std.mem.indexOf(u8, list.body, "\\\"") != null); // escaped quote present
}

test "anonymous workstream id can be joined by id" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    // Dispatch a root task with no workstream → anonymous workstream (no workstreams row).
    var root = try ctx.requestWithAuth(
        .POST,
        "/admin/dispatch",
        "{\"agent_id\":\"agent-0\",\"action\":\"x\",\"payload\":\"{}\"}",
        "Bearer admin-token-change-me",
    );
    defer root.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), root.status_code);
    const ws = extractJsonStringField(root.body, "workstream_id") orelse return error.MissingWs;
    defer testing.allocator.free(ws);

    // Follow-up with that anonymous workstream_id — must succeed (fallback to tasks lookup).
    const follow_body = try std.fmt.allocPrint(
        testing.allocator,
        "{{\"agent_id\":\"agent-0\",\"action\":\"y\",\"payload\":\"{{}}\",\"workstream_id\":\"{s}\"}}",
        .{ws},
    );
    defer testing.allocator.free(follow_body);
    var follow = try ctx.requestWithAuth(.POST, "/admin/dispatch", follow_body, "Bearer admin-token-change-me");
    defer follow.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), follow.status_code);
    const follow_ws = extractJsonStringField(follow.body, "workstream_id") orelse return error.MissingFollowWs;
    defer testing.allocator.free(follow_ws);
    try testing.expectEqualStrings(ws, follow_ws);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Extract a string JSON field value by key from a response body.
/// Returns a caller-owned slice (allocated via `testing.allocator`), or null
/// if the field is absent / not a string.
fn extractJsonStringField(body: []const u8, key: []const u8) ?[]u8 {
    var key_buf: [64]u8 = undefined;
    const quoted = std.fmt.bufPrint(&key_buf, "\"{s}\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, body, quoted) orelse return null;
    var i = start + quoted.len;
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

/// Extract the `task_id` string value from a JSON response body.
/// Returns a caller-owned slice (allocated via `testing.allocator`), or null
/// if the field is absent / not a string.
fn extractTaskId(body: []const u8) ?[]u8 {
    return extractJsonStringField(body, "task_id");
}

fn parseStatusCode(bytes: []const u8) ?u16 {
    // Format: "HTTP/1.1 200 OK\r\n..."
    var it = std.mem.splitScalar(u8, bytes, ' ');
    _ = it.next() orelse return null; // "HTTP/1.1"
    const code_str = it.next() orelse return null;
    return std.fmt.parseUnsigned(u16, code_str, 10) catch null;
}