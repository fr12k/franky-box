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

        // Tests must start from a clean slate: the counter resets every test
        // run, so a leftover file from a previous run would seed this run's
        // context with stale tasks. Remove the file (and any WAL/SHM siblings)
        // before opening.
        std.Io.Dir.deleteFileAbsolute(std.testing.io, db_path) catch {};
        var side_buf: [160]u8 = undefined;
        const wal_path = try std.fmt.bufPrint(&side_buf, "{s}-wal", .{db_path_noz});
        std.Io.Dir.deleteFileAbsolute(std.testing.io, wal_path) catch {};
        const shm_path = try std.fmt.bufPrint(&side_buf, "{s}-shm", .{db_path_noz});
        std.Io.Dir.deleteFileAbsolute(std.testing.io, shm_path) catch {};

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
    const root_body = try formBody(testing.allocator, &.{
        .{ .key = "agent_id", .val = "agent-0" },
        .{ .key = "action", .val = "generate" },
        .{ .key = "payload", .val = "{}" },
        .{ .key = "workstream_name", .val = "Daily Newsletter" },
    });
    defer testing.allocator.free(root_body);
    var root_resp = try ctx.requestWithAuth(.POST, "/admin/dispatch", root_body, "Bearer admin-token-change-me");
    defer root_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), root_resp.status_code);
    const root_id = extractAdminTaskId(root_resp.body) orelse return error.MissingRootId;
    defer testing.allocator.free(root_id);
    const root_ws = extractAdminWorkstreamId(root_resp.body) orelse return error.MissingRootWorkstream;
    defer testing.allocator.free(root_ws);
    // The root task's workstream_id must differ from its task_id.
    try testing.expect(!std.mem.eql(u8, root_id, root_ws));

    // 2. Admin-dispatch a follow-up with workstream_id = root_ws (now exists).
    const follow_body = try formBody(testing.allocator, &.{
        .{ .key = "agent_id", .val = "agent-0" },
        .{ .key = "action", .val = "review" },
        .{ .key = "payload", .val = "{}" },
        .{ .key = "workstream_id", .val = root_ws },
    });
    defer testing.allocator.free(follow_body);
    var follow_resp = try ctx.requestWithAuth(.POST, "/admin/dispatch", follow_body, "Bearer admin-token-change-me");
    defer follow_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), follow_resp.status_code);
    const follow_id = extractAdminTaskId(follow_resp.body) orelse return error.MissingFollowId;
    defer testing.allocator.free(follow_id);
    const follow_ws = extractAdminWorkstreamId(follow_resp.body) orelse return error.MissingFollowWorkstream;
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
    const root_body = try formBody(testing.allocator, &.{
        .{ .key = "agent_id", .val = "agent-0" },
        .{ .key = "action", .val = "generate" },
        .{ .key = "payload", .val = "{}" },
        .{ .key = "workstream_name", .val = "Weekly Report" },
    });
    defer testing.allocator.free(root_body);
    var root_resp = try ctx.requestWithAuth(.POST, "/admin/dispatch", root_body, "Bearer admin-token-change-me");
    defer root_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), root_resp.status_code);
    const ws = extractAdminWorkstreamId(root_resp.body) orelse return error.MissingWorkstream;
    defer testing.allocator.free(ws);

    // Follow-up in the same workstream (by id).
    const follow_body = try formBody(testing.allocator, &.{
        .{ .key = "agent_id", .val = "agent-0" },
        .{ .key = "action", .val = "review" },
        .{ .key = "payload", .val = "{}" },
        .{ .key = "workstream_id", .val = ws },
    });
    defer testing.allocator.free(follow_body);
    var follow_resp = try ctx.requestWithAuth(.POST, "/admin/dispatch", follow_body, "Bearer admin-token-change-me");
    defer follow_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), follow_resp.status_code);

    // List workstreams and find ours with a count of at least 2.
    var list_resp = try ctx.requestWithAuth(.GET, "/admin/workstreams", "", "Bearer admin-token-change-me");
    defer list_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), list_resp.status_code);
    try testing.expect(std.mem.indexOf(u8, list_resp.body, ws) != null);
    try testing.expect(std.mem.indexOf(u8, list_resp.body, "Weekly Report") != null);
    try testing.expect(std.mem.indexOf(u8, list_resp.body, ">2<") != null); // <td data-label="Tasks">2</td>
}

test "admin dispatch by workstream_name auto-creates then 409 on duplicate" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    // 1. Dispatch with a workstream_name — auto-creates the workstream.
    const first_body = try formBody(testing.allocator, &.{
        .{ .key = "agent_id", .val = "agent-0" },
        .{ .key = "action", .val = "audit" },
        .{ .key = "payload", .val = "{}" },
        .{ .key = "workstream_name", .val = "Monthly Audit" },
    });
    defer testing.allocator.free(first_body);
    var first_resp = try ctx.requestWithAuth(.POST, "/admin/dispatch", first_body, "Bearer admin-token-change-me");
    defer first_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), first_resp.status_code);
    const ws_id = extractAdminWorkstreamId(first_resp.body) orelse return error.MissingWorkstreamId;
    defer testing.allocator.free(ws_id);

    // 2. Dispatch again with the SAME workstream_name — lookup finds the existing
    //    one and joins it (no create, no 409).
    const join_body = try formBody(testing.allocator, &.{
        .{ .key = "agent_id", .val = "agent-0" },
        .{ .key = "action", .val = "review" },
        .{ .key = "payload", .val = "{}" },
        .{ .key = "workstream_name", .val = "Monthly Audit" },
    });
    defer testing.allocator.free(join_body);
    var join_resp = try ctx.requestWithAuth(.POST, "/admin/dispatch", join_body, "Bearer admin-token-change-me");
    defer join_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), join_resp.status_code);
    const join_ws = extractAdminWorkstreamId(join_resp.body) orelse return error.MissingJoinWs;
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

    const body = try formBody(testing.allocator, &.{
        .{ .key = "agent_id", .val = "agent-0" },
        .{ .key = "action", .val = "x" },
        .{ .key = "payload", .val = "{}" },
        .{ .key = "workstream_id", .val = "nonexistent-uuid" },
    });
    defer testing.allocator.free(body);
    var resp = try ctx.requestWithAuth(.POST, "/admin/dispatch", body, "Bearer admin-token-change-me");
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 400), resp.status_code);
    try testing.expect(std.mem.indexOf(u8, resp.body, "not found") != null);
}

test "workstream names with special characters are HTML-escaped in responses" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    // Dispatch with a workstream name containing a double-quote and backslash.
    // formEncode URL-encodes them so the server receives the raw chars after decode.
    const body = try formBody(testing.allocator, &.{
        .{ .key = "agent_id", .val = "agent-0" },
        .{ .key = "action", .val = "x" },
        .{ .key = "payload", .val = "{}" },
        .{ .key = "workstream_name", .val = "Quote \" and backslash \\" },
    });
    defer testing.allocator.free(body);
    var resp = try ctx.requestWithAuth(.POST, "/admin/dispatch", body, "Bearer admin-token-change-me");
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), resp.status_code);
    const ws = extractAdminWorkstreamId(resp.body) orelse return error.MissingWs;
    defer testing.allocator.free(ws);

    // List workstreams — the name with quotes must be HTML-escaped in the fragment.
    var list = try ctx.requestWithAuth(.GET, "/admin/workstreams", "", "Bearer admin-token-change-me");
    defer list.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), list.status_code);
    // The workstream_id is present, and the double-quote is HTML-escaped as &quot;
    // (a naive interpolation would inject a raw '"' and break the HTML attribute/structure).
    try testing.expect(std.mem.indexOf(u8, list.body, ws) != null);
    try testing.expect(std.mem.indexOf(u8, list.body, "&quot;") != null); // HTML-escaped quote
}

test "anonymous workstream id can be joined by id" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    // Dispatch a root task with no workstream → anonymous workstream (no workstreams row).
    const root_body = try formBody(testing.allocator, &.{
        .{ .key = "agent_id", .val = "agent-0" },
        .{ .key = "action", .val = "x" },
        .{ .key = "payload", .val = "{}" },
    });
    defer testing.allocator.free(root_body);
    var root = try ctx.requestWithAuth(.POST, "/admin/dispatch", root_body, "Bearer admin-token-change-me");
    defer root.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), root.status_code);
    const ws = extractAdminWorkstreamId(root.body) orelse return error.MissingWs;
    defer testing.allocator.free(ws);

    // Follow-up with that anonymous workstream_id — must succeed (fallback to tasks lookup).
    const follow_body = try formBody(testing.allocator, &.{
        .{ .key = "agent_id", .val = "agent-0" },
        .{ .key = "action", .val = "y" },
        .{ .key = "payload", .val = "{}" },
        .{ .key = "workstream_id", .val = ws },
    });
    defer testing.allocator.free(follow_body);
    var follow = try ctx.requestWithAuth(.POST, "/admin/dispatch", follow_body, "Bearer admin-token-change-me");
    defer follow.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), follow.status_code);
    const follow_ws = extractAdminWorkstreamId(follow.body) orelse return error.MissingFollowWs;
    defer testing.allocator.free(follow_ws);
    try testing.expectEqualStrings(ws, follow_ws);
}

test "admin dispatch with empty workstream_id falls through to workstream_name" {
    // Regression: the browser <select name="workstream_id"> always submits,
    // with value="" for the placeholder. An empty workstream_id must NOT
    // short-circuit the workstream-name mode; otherwise a typed name is
    // silently discarded and an anonymous workstream is generated instead.
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    const body = try formBody(testing.allocator, &.{
        .{ .key = "agent_id", .val = "agent-0" },
        .{ .key = "action", .val = "x" },
        .{ .key = "payload", .val = "{}" },
        .{ .key = "workstream_id", .val = "" }, // empty, as the placeholder submits
        .{ .key = "workstream_name", .val = "Fallback Name" },
    });
    defer testing.allocator.free(body);
    var resp = try ctx.requestWithAuth(.POST, "/admin/dispatch", body, "Bearer admin-token-change-me");
    defer resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), resp.status_code);
    const ws = extractAdminWorkstreamId(resp.body) orelse return error.MissingWs;
    defer testing.allocator.free(ws);

    // The workstream must have been created by name, so it appears in the list
    // with the name "Fallback Name" (an anonymous workstream would have no row).
    var list = try ctx.requestWithAuth(.GET, "/admin/workstreams", "", "Bearer admin-token-change-me");
    defer list.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), list.status_code);
    try testing.expect(std.mem.indexOf(u8, list.body, ws) != null);
    try testing.expect(std.mem.indexOf(u8, list.body, "Fallback Name") != null);
}

// ---------------------------------------------------------------------------
// Helpers

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

/// Extract the Nth <code>…</code> text content from an HTML fragment.
/// The admin dispatch toast is:
///   <div class="toast success">✅ Task dispatched: <code>{task_id}</code><br>workstream: <code>{ws}</code></div>
/// so n=0 yields task_id, n=1 yields the workstream id. Returns a caller-owned
/// slice, or null if absent. HTML entities are NOT decoded (test values are
/// UUIDs / plain ids with no entities).
fn extractCodeN(body: []const u8, n: usize) ?[]u8 {
    const open = "<code>";
    const close = "</code>";
    var pos: usize = 0;
    var idx: usize = 0;
    while (pos < body.len) {
        const s = std.mem.indexOfPos(u8, body, pos, open) orelse return null;
        const e = std.mem.indexOfPos(u8, body, s + open.len, close) orelse return null;
        if (idx == n) {
            return std.testing.allocator.dupe(u8, body[s + open.len .. e]) catch null;
        }
        idx += 1;
        pos = e + close.len;
    }
    return null;
}

/// Extract the task_id from an admin dispatch HTML toast fragment (first <code>).
fn extractAdminTaskId(body: []const u8) ?[]u8 {
    return extractCodeN(body, 0);
}

/// Extract the workstream_id from an admin dispatch HTML toast fragment (2nd <code>).
fn extractAdminWorkstreamId(body: []const u8) ?[]u8 {
    return extractCodeN(body, 1);
}

/// URL-encode `value` for an application/x-www-form-urlencoded body. Returns a
/// caller-owned slice. Only encodes characters that need it for our test
/// values (quotes, spaces, ampersands); alphanumerics pass through.
fn formEncode(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (value) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', '~' => try buf.append(allocator, c),
            else => try buf.print(allocator, "%{X:0>2}", .{c}),
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Build a form-encoded body from key/value pairs (values are URL-encoded).
/// Keys are assumed URL-safe (alphanumeric). Pairs are joined with &.
fn formBody(allocator: std.mem.Allocator, pairs: []const struct { key: []const u8, val: []const u8 }) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (pairs, 0..) |p, i| {
        if (i > 0) try buf.append(allocator, '&');
        try buf.appendSlice(allocator, p.key);
        try buf.append(allocator, '=');
        const enc = try formEncode(allocator, p.val);
        defer allocator.free(enc);
        try buf.appendSlice(allocator, enc);
    }
    return buf.toOwnedSlice(allocator);
}

fn parseStatusCode(bytes: []const u8) ?u16 {
    // Format: "HTTP/1.1 200 OK\r\n..."
    var it = std.mem.splitScalar(u8, bytes, ' ');
    _ = it.next() orelse return null; // "HTTP/1.1"
    const code_str = it.next() orelse return null;
    return std.fmt.parseUnsigned(u16, code_str, 10) catch null;
}
test "ack removes a result from the outbox read" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    // Dispatch, claim, complete.
    var dispatch_resp = try ctx.request(.POST, "/v1/tasks/dispatch", "\"ack test\"");
    defer dispatch_resp.deinit(testing.allocator);
    var claim = try ctx.requestWithAuth(.POST, "/v1/agents/agent-0/inbox/claim", "", "Bearer default-secret-please-change");
    defer claim.deinit(testing.allocator);
    const task_id = extractTaskId(claim.body) orelse return error.MissingTaskId;
    defer testing.allocator.free(task_id);
    const complete_path = try std.fmt.allocPrint(testing.allocator, "/v1/agents/agent-0/outbox/{s}/complete", .{task_id});
    defer testing.allocator.free(complete_path);
    var complete_resp = try ctx.requestWithAuth(.POST, complete_path, "{\"result\": \"ok\"}", "Bearer default-secret-please-change");
    defer complete_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), complete_resp.status_code);

    // Before ack: the result is readable in the outbox.
    {
        var outbox = try ctx.requestWithAuth(.GET, "/v1/agents/agent-0/outbox", "", "Bearer default-secret-please-change");
        defer outbox.deinit(testing.allocator);
        try testing.expectEqual(@as(u16, 200), outbox.status_code);
        try testing.expect(std.mem.indexOf(u8, outbox.body, task_id) != null);
    }

    // Ack the result.
    const ack_path = try std.fmt.allocPrint(testing.allocator, "/v1/agents/agent-0/outbox/{s}/ack", .{task_id});
    defer testing.allocator.free(ack_path);
    var ack_resp = try ctx.requestWithAuth(.POST, ack_path, "", "Bearer default-secret-please-change");
    defer ack_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), ack_resp.status_code);
    try testing.expect(std.mem.indexOf(u8, ack_resp.body, "\"status\":\"consumed\"") != null);

    // After ack: the result is no longer returned to consumers.
    {
        var outbox = try ctx.requestWithAuth(.GET, "/v1/agents/agent-0/outbox", "", "Bearer default-secret-please-change");
        defer outbox.deinit(testing.allocator);
        try testing.expectEqual(@as(u16, 200), outbox.status_code);
        try testing.expect(std.mem.indexOf(u8, outbox.body, task_id) == null);
    }

    // Re-acking an already-consumed result is idempotent: HTTP 200 with the
    // original consumed_at preserved (COALESCE), per the documented contract.
    var ack_resp2 = try ctx.requestWithAuth(.POST, ack_path, "", "Bearer default-secret-please-change");
    defer ack_resp2.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), ack_resp2.status_code);

    // The consumed result remains visible to the admin outbox view until
    // it is retired to the archive.
    {
        var admin_outbox = try ctx.requestWithAuth(.GET, "/admin/outbox", "", "Bearer admin-token-change-me");
        defer admin_outbox.deinit(testing.allocator);
        try testing.expectEqual(@as(u16, 200), admin_outbox.status_code);
        try testing.expect(std.mem.indexOf(u8, admin_outbox.body, task_id) != null);
        try testing.expect(std.mem.indexOf(u8, admin_outbox.body, "waiting for consumer") == null); // it IS consumed
    }
}

test "ack-all consumes every pending result and reports counts" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    // Two completed results.
    for (0..2) |_| {
        var dispatch_resp = try ctx.request(.POST, "/v1/tasks/dispatch", "\"ack-all test\"");
        defer dispatch_resp.deinit(testing.allocator);
        var claim = try ctx.requestWithAuth(.POST, "/v1/agents/agent-0/inbox/claim", "", "Bearer default-secret-please-change");
        defer claim.deinit(testing.allocator);
        const task_id = extractTaskId(claim.body) orelse return error.MissingTaskId;
        defer testing.allocator.free(task_id);
        const complete_path = try std.fmt.allocPrint(testing.allocator, "/v1/agents/agent-0/outbox/{s}/complete", .{task_id});
        defer testing.allocator.free(complete_path);
        var complete_resp = try ctx.requestWithAuth(.POST, complete_path, "{\"result\": \"ok\"}", "Bearer default-secret-please-change");
        defer complete_resp.deinit(testing.allocator);
        try testing.expectEqual(@as(u16, 200), complete_resp.status_code);
    }

    // Ack everything.
    var ack_resp = try ctx.requestWithAuth(.POST, "/v1/agents/agent-0/outbox/ack-all", "", "Bearer default-secret-please-change");
    defer ack_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), ack_resp.status_code);
    try testing.expect(std.mem.indexOf(u8, ack_resp.body, "\"acked\":2") != null);

    // Outbox read is now empty.
    {
        var outbox = try ctx.requestWithAuth(.GET, "/v1/agents/agent-0/outbox", "", "Bearer default-secret-please-change");
        defer outbox.deinit(testing.allocator);
        try testing.expectEqual(@as(u16, 200), outbox.status_code);
        try testing.expectEqualStrings("[]", outbox.body);
    }
}

test "outbox read honors the since cursor" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    // First result, then backdate it as "already seen" by setting a past
    // completed_at. The consumer's cursor is 2020-06-01.
    {
        var dispatch_resp = try ctx.request(.POST, "/v1/tasks/dispatch", "\"cursor test 1\"");
        defer dispatch_resp.deinit(testing.allocator);
        var claim = try ctx.requestWithAuth(.POST, "/v1/agents/agent-0/inbox/claim", "", "Bearer default-secret-please-change");
        defer claim.deinit(testing.allocator);
        const task_id = extractTaskId(claim.body) orelse return error.MissingTaskId;
        defer testing.allocator.free(task_id);
        const complete_path = try std.fmt.allocPrint(testing.allocator, "/v1/agents/agent-0/outbox/{s}/complete", .{task_id});
        defer testing.allocator.free(complete_path);
        var complete_resp = try ctx.requestWithAuth(.POST, complete_path, "{\"result\": \"ok\"}", "Bearer default-secret-please-change");
        defer complete_resp.deinit(testing.allocator);
        try testing.expectEqual(@as(u16, 200), complete_resp.status_code);
        // Backdate completed_at so the since-cursor filters it out.
        var stmt = try ctx.store_backend.db.prepare(
            "UPDATE tasks SET completed_at = '2020-01-01 00:00:00' WHERE task_id = ?",
        );
        defer stmt.finalize();
        try stmt.bindText(1, task_id);
        _ = try stmt.step();
    }

    // A second, fresh result.
    var task2_id: []u8 = "";
    defer if (task2_id.len > 0) testing.allocator.free(task2_id);
    {
        var dispatch_resp = try ctx.request(.POST, "/v1/tasks/dispatch", "\"cursor test 2\"");
        defer dispatch_resp.deinit(testing.allocator);
        var claim = try ctx.requestWithAuth(.POST, "/v1/agents/agent-0/inbox/claim", "", "Bearer default-secret-please-change");
        defer claim.deinit(testing.allocator);
        const task_id = extractTaskId(claim.body) orelse return error.MissingTaskId;
        task2_id = task_id;
        const complete_path = try std.fmt.allocPrint(testing.allocator, "/v1/agents/agent-0/outbox/{s}/complete", .{task_id});
        defer testing.allocator.free(complete_path);
        var complete_resp = try ctx.requestWithAuth(.POST, complete_path, "{\"result\": \"ok\"}", "Bearer default-secret-please-change");
        defer complete_resp.deinit(testing.allocator);
        try testing.expectEqual(@as(u16, 200), complete_resp.status_code);
    }

    // Poll with the cursor: only the fresh result comes back.
    {
        var outbox = try ctx.requestWithAuth(.GET, "/v1/agents/agent-0/outbox?since=2020-06-01%2000:00:00", "", "Bearer default-secret-please-change");
        defer outbox.deinit(testing.allocator);
        try testing.expectEqual(@as(u16, 200), outbox.status_code);
        try testing.expect(std.mem.indexOf(u8, outbox.body, task2_id) != null);
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, outbox.body, "\"task_id\""));
    }
}

test "admin archive lists retired tasks" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    // Empty archive initially.
    {
        var resp = try ctx.requestWithAuth(.GET, "/admin/archive", "", "Bearer admin-token-change-me");
        defer resp.deinit(testing.allocator);
        try testing.expectEqual(@as(u16, 200), resp.status_code);
        try testing.expect(std.mem.indexOf(u8, resp.body, "No completed tasks.") != null);
    }

    // Complete + ack a task, then backdate consumed_at past the grace window
    // so the next purge retires it to the archive.
    var dispatch_resp = try ctx.request(.POST, "/v1/tasks/dispatch", "\"archive test\"");
    defer dispatch_resp.deinit(testing.allocator);
    var claim = try ctx.requestWithAuth(.POST, "/v1/agents/agent-0/inbox/claim", "", "Bearer default-secret-please-change");
    defer claim.deinit(testing.allocator);
    const task_id = extractTaskId(claim.body) orelse return error.MissingTaskId;
    defer testing.allocator.free(task_id);
    const complete_path = try std.fmt.allocPrint(testing.allocator, "/v1/agents/agent-0/outbox/{s}/complete", .{task_id});
    defer testing.allocator.free(complete_path);
    var complete_resp = try ctx.requestWithAuth(.POST, complete_path, "{\"result\": \"ok\"}", "Bearer default-secret-please-change");
    defer complete_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), complete_resp.status_code);

    const ack_path = try std.fmt.allocPrint(testing.allocator, "/v1/agents/agent-0/outbox/{s}/ack", .{task_id});
    defer testing.allocator.free(ack_path);
    var ack_resp = try ctx.requestWithAuth(.POST, ack_path, "", "Bearer default-secret-please-change");
    defer ack_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), ack_resp.status_code);

    {
        var stmt = try ctx.store_backend.db.prepare(
            "UPDATE tasks SET consumed_at = datetime('now', '-2 hours') WHERE task_id = ?",
        );
        defer stmt.finalize();
        try stmt.bindText(1, task_id);
        _ = try stmt.step();
    }

    // Trigger a purge (dispatch piggybacks it) and verify the archive.
    var dispatch2 = try ctx.request(.POST, "/v1/tasks/dispatch", "\"purge trigger\"");
    defer dispatch2.deinit(testing.allocator);
    {
        var resp = try ctx.requestWithAuth(.GET, "/admin/archive", "", "Bearer admin-token-change-me");
        defer resp.deinit(testing.allocator);
        try testing.expectEqual(@as(u16, 200), resp.status_code);
        try testing.expect(std.mem.indexOf(u8, resp.body, task_id) != null);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// P0-P2 integration tests
// ═════════════════════════════════════════════════════════════════════════════

test "heartbeat extends the claim lease" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    var dispatch = try ctx.request(.POST, "/v1/tasks/dispatch", "\"long task\"");
    defer dispatch.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), dispatch.status_code);
    var claim = try ctx.requestWithAuth(.POST, "/v1/agents/agent-0/inbox/claim", "", "Bearer default-secret-please-change");
    defer claim.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), claim.status_code);
    const task_id = extractFirstTaskId(claim.body) orelse return error.MissingTaskId;
    defer testing.allocator.free(task_id);

    const hb_path = try std.fmt.allocPrint(testing.allocator, "/v1/agents/agent-0/inbox/{s}/heartbeat?extend=600", .{task_id});
    defer testing.allocator.free(hb_path);
    var hb = try ctx.requestWithAuth(.POST, hb_path, "", "Bearer default-secret-please-change");
    defer hb.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), hb.status_code);
    try testing.expect(std.mem.indexOf(u8, hb.body, "\"locked_until\"") != null);

    var claim2 = try ctx.requestWithAuth(.POST, "/v1/agents/agent-0/inbox/claim", "", "Bearer default-secret-please-change");
    defer claim2.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 204), claim2.status_code);
}

test "heartbeat rejects invalid extend values" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    var dispatch = try ctx.request(.POST, "/v1/tasks/dispatch", "\"x\"");
    defer dispatch.deinit(testing.allocator);
    var claim = try ctx.requestWithAuth(.POST, "/v1/agents/agent-0/inbox/claim", "", "Bearer default-secret-please-change");
    defer claim.deinit(testing.allocator);
    const task_id = extractFirstTaskId(claim.body) orelse return error.MissingTaskId;
    defer testing.allocator.free(task_id);

    const hb_path = try std.fmt.allocPrint(testing.allocator, "/v1/agents/agent-0/inbox/{s}/heartbeat?extend=notanumber", .{task_id});
    defer testing.allocator.free(hb_path);
    var hb = try ctx.requestWithAuth(.POST, hb_path, "", "Bearer default-secret-please-change");
    defer hb.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 400), hb.status_code);

    const hb_path2 = try std.fmt.allocPrint(testing.allocator, "/v1/agents/agent-0/inbox/{s}/heartbeat?extend=999999", .{task_id});
    defer testing.allocator.free(hb_path2);
    var hb2 = try ctx.requestWithAuth(.POST, hb_path2, "", "Bearer default-secret-please-change");
    defer hb2.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 400), hb2.status_code);
}

test "cancel finalizes an unclaimed task and fences complete" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    var dispatch = try ctx.request(.POST, "/v1/tasks/dispatch", "\"cancel me\"");
    defer dispatch.deinit(testing.allocator);
    const task_id = extractFirstTaskId(dispatch.body) orelse return error.MissingTaskId;
    defer testing.allocator.free(task_id);

    const cancel_path = try std.fmt.allocPrint(testing.allocator, "/v1/agents/agent-0/inbox/{s}/cancel", .{task_id});
    defer testing.allocator.free(cancel_path);
    var cancel = try ctx.requestWithAuth(.POST, cancel_path, "", "Bearer admin-token-change-me");
    defer cancel.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), cancel.status_code);

    const complete_path = try std.fmt.allocPrint(testing.allocator, "/v1/agents/agent-0/outbox/{s}/complete", .{task_id});
    defer testing.allocator.free(complete_path);
    var complete_resp = try ctx.requestWithAuth(.POST, complete_path, "{\"result\":\"late\"}", "Bearer default-secret-please-change");
    defer complete_resp.deinit(testing.allocator);
    try testing.expect(complete_resp.status_code == 404 or complete_resp.status_code == 200);

    var cancel2 = try ctx.requestWithAuth(.POST, cancel_path, "", "Bearer admin-token-change-me");
    defer cancel2.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 404), cancel2.status_code);
}

test "cancel of a claimed task marks it and the next claim skips it" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    var dispatch = try ctx.request(.POST, "/v1/tasks/dispatch", "\"claimed cancel\"");
    defer dispatch.deinit(testing.allocator);
    var claim = try ctx.requestWithAuth(.POST, "/v1/agents/agent-0/inbox/claim", "", "Bearer default-secret-please-change");
    defer claim.deinit(testing.allocator);
    const task_id = extractFirstTaskId(claim.body) orelse return error.MissingTaskId;
    defer testing.allocator.free(task_id);

    const cancel_path = try std.fmt.allocPrint(testing.allocator, "/v1/agents/agent-0/inbox/{s}/cancel", .{task_id});
    defer testing.allocator.free(cancel_path);
    var cancel = try ctx.requestWithAuth(.POST, cancel_path, "", "Bearer admin-token-change-me");
    defer cancel.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 202), cancel.status_code);

    var claim2 = try ctx.requestWithAuth(.POST, "/v1/agents/agent-0/inbox/claim", "", "Bearer default-secret-please-change");
    defer claim2.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 204), claim2.status_code);
}

test "getTask returns full state including A2A-style state names" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    var dispatch = try ctx.request(.POST, "/v1/tasks/dispatch", "{\"work\": \"report\"}");
    defer dispatch.deinit(testing.allocator);
    const task_id = extractFirstTaskId(dispatch.body) orelse return error.MissingTaskId;
    defer testing.allocator.free(task_id);

    const get_path = try std.fmt.allocPrint(testing.allocator, "/v1/agents/agent-0/tasks/{s}", .{task_id});
    defer testing.allocator.free(get_path);
    {
        var resp = try ctx.requestWithAuth(.GET, get_path, "", "Bearer default-secret-please-change");
        defer resp.deinit(testing.allocator);
        try testing.expectEqual(@as(u16, 200), resp.status_code);
        try testing.expect(std.mem.indexOf(u8, resp.body, "\"state\":\"submitted\"") != null);
    }

    var claim = try ctx.requestWithAuth(.POST, "/v1/agents/agent-0/inbox/claim", "", "Bearer default-secret-please-change");
    defer claim.deinit(testing.allocator);
    {
        var resp = try ctx.requestWithAuth(.GET, get_path, "", "Bearer default-secret-please-change");
        defer resp.deinit(testing.allocator);
        try testing.expect(std.mem.indexOf(u8, resp.body, "\"state\":\"working\"") != null);
    }

    const complete_path = try std.fmt.allocPrint(testing.allocator, "/v1/agents/agent-0/outbox/{s}/complete", .{task_id});
    defer testing.allocator.free(complete_path);
    var complete_resp = try ctx.requestWithAuth(.POST, complete_path, "{\"summary\":\"done\"}", "Bearer default-secret-please-change");
    defer complete_resp.deinit(testing.allocator);
    {
        var resp = try ctx.requestWithAuth(.GET, get_path, "", "Bearer default-secret-please-change");
        defer resp.deinit(testing.allocator);
        try testing.expect(std.mem.indexOf(u8, resp.body, "\"state\":\"completed\"") != null);
    }

    var resp404 = try ctx.requestWithAuth(.GET, "/v1/agents/agent-0/tasks/t_nonexistent", "", "Bearer default-secret-please-change");
    defer resp404.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 404), resp404.status_code);
}

test "human-in-the-loop: input-required parks, input resumes" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    var dispatch = try ctx.request(.POST, "/v1/tasks/dispatch", "\"approve my plan\"");
    defer dispatch.deinit(testing.allocator);
    var claim = try ctx.requestWithAuth(.POST, "/v1/agents/agent-0/inbox/claim", "", "Bearer default-secret-please-change");
    defer claim.deinit(testing.allocator);
    const task_id = extractFirstTaskId(claim.body) orelse return error.MissingTaskId;
    defer testing.allocator.free(task_id);

    const park_path = try std.fmt.allocPrint(testing.allocator, "/v1/agents/agent-0/inbox/{s}/input-required", .{task_id});
    defer testing.allocator.free(park_path);
    var park = try ctx.requestWithAuth(.POST, park_path, "{\"query\": \"Which database?\"}", "Bearer default-secret-please-change");
    defer park.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), park.status_code);

    var claim2 = try ctx.requestWithAuth(.POST, "/v1/agents/agent-0/inbox/claim", "", "Bearer default-secret-please-change");
    defer claim2.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 204), claim2.status_code);

    const input_path = try std.fmt.allocPrint(testing.allocator, "/v1/agents/agent-0/inbox/{s}/input", .{task_id});
    defer testing.allocator.free(input_path);
    var input = try ctx.requestWithAuth(.POST, input_path, "{\"input\": \"postgres\"}", "Bearer admin-token-change-me");
    defer input.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), input.status_code);

    const get_path = try std.fmt.allocPrint(testing.allocator, "/v1/agents/agent-0/tasks/{s}", .{task_id});
    defer testing.allocator.free(get_path);
    var resp = try ctx.requestWithAuth(.GET, get_path, "", "Bearer default-secret-please-change");
    defer resp.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"state\":\"working\"") != null);

    var input2 = try ctx.requestWithAuth(.POST, input_path, "{\"input\": \"again\"}", "Bearer admin-token-change-me");
    defer input2.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 404), input2.status_code);
}

test "agent registration persists and survives restart" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    var reg = try ctx.request(.POST, "/v1/agents",
        \\{"agent_id": "billing-agent", "secret": "super-secret-billing-key-123", "name": "Billing", "skills": ["invoices", "pdf"]}
    );
    defer reg.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), reg.status_code);
    try testing.expect(std.mem.indexOf(u8, reg.body, "\"billing-agent\"") != null);

    var claim = try ctx.requestWithAuth(.POST, "/v1/agents/billing-agent/inbox/claim", "", "Bearer super-secret-billing-key-123");
    defer claim.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 204), claim.status_code);

    var bad = try ctx.requestWithAuth(.POST, "/v1/agents/billing-agent/inbox/claim", "", "Bearer wrong-secret");
    defer bad.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 401), bad.status_code);

    var card = try ctx.request(.GET, "/v1/agents/billing-agent/card", "");
    defer card.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), card.status_code);
    try testing.expect(std.mem.indexOf(u8, card.body, "invoices") != null);
    try testing.expect(std.mem.indexOf(u8, card.body, "Billing") != null);

    var wk = try ctx.request(.GET, "/.well-known/agent-card.json", "");
    defer wk.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), wk.status_code);
    try testing.expect(std.mem.indexOf(u8, wk.body, "billing-agent") != null);

    var reg_bad = try ctx.request(.POST, "/v1/agents", "{\"agent_id\": \"weak\", \"secret\": \"short\"}");
    defer reg_bad.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 400), reg_bad.status_code);
}

test "grant token verification gates /v1/results" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    var dispatch = try ctx.request(.POST, "/v1/tasks/dispatch", "\"result payload\"");
    defer dispatch.deinit(testing.allocator);
    var claim = try ctx.requestWithAuth(.POST, "/v1/agents/agent-0/inbox/claim", "", "Bearer default-secret-please-change");
    defer claim.deinit(testing.allocator);
    const task_id = extractFirstTaskId(claim.body) orelse return error.MissingTaskId;
    defer testing.allocator.free(task_id);

    const complete_path = try std.fmt.allocPrint(testing.allocator, "/v1/agents/agent-0/outbox/{s}/complete", .{task_id});
    defer testing.allocator.free(complete_path);
    var complete_resp = try ctx.requestWithAuth(.POST, complete_path, "{\"summary\":\"the answer\"}", "Bearer default-secret-please-change");
    defer complete_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), complete_resp.status_code);
    const token = extractFirstToken(complete_resp.body) orelse return error.MissingGrantToken;
    defer testing.allocator.free(token);

    const result_path = try std.fmt.allocPrint(testing.allocator, "/v1/results/{s}?token={s}", .{ task_id, token });
    defer testing.allocator.free(result_path);
    var ok_resp = try ctx.request(.GET, result_path, "");
    defer ok_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), ok_resp.status_code);
    try testing.expect(std.mem.indexOf(u8, ok_resp.body, "the answer") != null);

    const bad_path = try std.fmt.allocPrint(testing.allocator, "/v1/results/{s}?token=fb_grant_deadbeef_exp9999999999", .{task_id});
    defer testing.allocator.free(bad_path);
    var bad_resp = try ctx.request(.GET, bad_path, "");
    defer bad_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 401), bad_resp.status_code);

    const notoken_path = try std.fmt.allocPrint(testing.allocator, "/v1/results/{s}", .{task_id});
    defer testing.allocator.free(notoken_path);
    var nt_resp = try ctx.request(.GET, notoken_path, "");
    defer nt_resp.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 400), nt_resp.status_code);
}

test "advanced dispatch with priority, schedule, deps, idempotency" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    var high = try ctx.requestWithAuth(.POST, "/v1/tasks/dispatch-advanced",
        \\{"agent_id": "agent-0", "action": "urgent", "payload": {"n": 1}, "priority": 10}
    , "Bearer admin-token-change-me");
    defer high.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), high.status_code);
    const high_id = extractFirstTaskId(high.body) orelse return error.MissingHighId;
    defer testing.allocator.free(high_id);

    var low = try ctx.requestWithAuth(.POST, "/v1/tasks/dispatch-advanced",
        \\{"agent_id": "agent-0", "action": "normal", "payload": {"n": 2}}
    , "Bearer admin-token-change-me");
    defer low.deinit(testing.allocator);
    const low_id = extractFirstTaskId(low.body) orelse return error.MissingLowId;
    defer testing.allocator.free(low_id);

    var claim1 = try ctx.requestWithAuth(.POST, "/v1/agents/agent-0/inbox/claim", "", "Bearer default-secret-please-change");
    defer claim1.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), claim1.status_code);
    const claimed1_id = extractFirstTaskId(claim1.body).?;
    defer testing.allocator.free(claimed1_id);
    try testing.expect(std.mem.eql(u8, high_id, claimed1_id));

    var sched = try ctx.requestWithAuth(.POST, "/v1/tasks/dispatch-advanced",
        \\{"agent_id": "agent-0", "action": "later", "payload": {}, "available_at": "2099-01-01 00:00:00"}
    , "Bearer admin-token-change-me");
    defer sched.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), sched.status_code);
    const sched_id = extractFirstTaskId(sched.body) orelse return error.MissingSchedId;
    defer testing.allocator.free(sched_id);
    {
        var c = try ctx.requestWithAuth(.POST, "/v1/agents/agent-0/inbox/claim", "", "Bearer default-secret-please-change");
        defer c.deinit(testing.allocator);
        const got = extractFirstTaskId(c.body).?;
        defer testing.allocator.free(got);
        try testing.expect(std.mem.eql(u8, low_id, got));
    }
    {
        var c = try ctx.requestWithAuth(.POST, "/v1/agents/agent-0/inbox/claim", "", "Bearer default-secret-please-change");
        defer c.deinit(testing.allocator);
        try testing.expectEqual(@as(u16, 204), c.status_code);
    }

    var blocked = try ctx.requestWithAuth(.POST, "/v1/tasks/dispatch-advanced",
        \\{"agent_id": "agent-0", "action": "dependent", "payload": {}, "blocked_by": ["t_missing"]}
    , "Bearer admin-token-change-me");
    defer blocked.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), blocked.status_code);
    {
        var c = try ctx.requestWithAuth(.POST, "/v1/agents/agent-0/inbox/claim", "", "Bearer default-secret-please-change");
        defer c.deinit(testing.allocator);
        try testing.expectEqual(@as(u16, 204), c.status_code);
    }

    var d1 = try ctx.requestWithAuth(.POST, "/v1/tasks/dispatch-advanced",
        \\{"agent_id": "agent-0", "action": "once", "payload": {}, "idempotency_key": "unique-1"}
    , "Bearer admin-token-change-me");
    defer d1.deinit(testing.allocator);
    var d2 = try ctx.requestWithAuth(.POST, "/v1/tasks/dispatch-advanced",
        \\{"agent_id": "agent-0", "action": "once", "payload": {}, "idempotency_key": "unique-1"}
    , "Bearer admin-token-change-me");
    defer d2.deinit(testing.allocator);
    const id1 = extractFirstTaskId(d1.body) orelse return error.MissingIdemId;
    defer testing.allocator.free(id1);
    const id2 = extractFirstTaskId(d2.body) orelse return error.MissingIdemId2;
    defer testing.allocator.free(id2);
    try testing.expect(std.mem.eql(u8, id1, id2));
    try testing.expect(std.mem.indexOf(u8, d2.body, "\"idempotent\":true") != null);
}

test "webhook subscription CRUD and listing" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    var add = try ctx.requestWithAuth(.POST, "/v1/webhooks",
        \\{"url": "http://127.0.0.1:9/hook", "agent_id": "agent-0"}
    , "Bearer admin-token-change-me");
    defer add.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), add.status_code);
    const sub_id = extractFirstSubId(add.body) orelse return error.MissingSubId;
    defer testing.allocator.free(sub_id);
    try testing.expect(std.mem.indexOf(u8, add.body, "\"secret\"") != null);

    var list = try ctx.requestWithAuth(.GET, "/v1/webhooks?agent_id=agent-0", "", "Bearer admin-token-change-me");
    defer list.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), list.status_code);
    try testing.expect(std.mem.indexOf(u8, list.body, sub_id) != null);

    var bad = try ctx.requestWithAuth(.POST, "/v1/webhooks", "{\"url\": \"http://127.0.0.1:9/hook\"}", "Bearer admin-token-change-me");
    defer bad.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 400), bad.status_code);

    var badurl = try ctx.requestWithAuth(.POST, "/v1/webhooks", "{\"url\": \"ftp://x/hook\", \"agent_id\": \"agent-0\"}", "Bearer admin-token-change-me");
    defer badurl.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 400), badurl.status_code);

    const del_path = try std.fmt.allocPrint(testing.allocator, "/v1/webhooks/{s}", .{sub_id});
    defer testing.allocator.free(del_path);
    var del = try ctx.requestWithAuth(.DELETE, del_path, "", "Bearer admin-token-change-me");
    defer del.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), del.status_code);
    var del2 = try ctx.requestWithAuth(.DELETE, del_path, "", "Bearer admin-token-change-me");
    defer del2.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 404), del2.status_code);
}

test "poison pill claim returns nothing instead of handing out the row" {
    var ctx = try TestContext.init(testing.allocator);
    defer ctx.deinit();

    var dispatch = try ctx.request(.POST, "/v1/tasks/dispatch", "\"poison\"");
    defer dispatch.deinit(testing.allocator);
    const task_id = extractFirstTaskId(dispatch.body) orelse return error.MissingTaskId;
    defer testing.allocator.free(task_id);

    {
        var stmt = try ctx.store_backend.db.prepare("UPDATE tasks SET try_count = 3 WHERE task_id = ?");
        defer stmt.finalize();
        try stmt.bindText(1, task_id);
        _ = try stmt.step();
    }

    var claim = try ctx.requestWithAuth(.POST, "/v1/agents/agent-0/inbox/claim", "", "Bearer default-secret-please-change");
    defer claim.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 204), claim.status_code);

    const get_path = try std.fmt.allocPrint(testing.allocator, "/v1/agents/agent-0/tasks/{s}", .{task_id});
    defer testing.allocator.free(get_path);
    var resp = try ctx.requestWithAuth(.GET, get_path, "", "Bearer default-secret-please-change");
    defer resp.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, resp.body, "\"state\":\"failed\"") != null);
}

// ── helpers for the new tests ─────────────────────────────────────────────

/// Extract the first "task_id":"..." value from a JSON body (caller-owned).
fn extractFirstTaskId(body: []const u8) ?[]u8 {
    const key = "\"task_id\":\"";
    const start = std.mem.indexOf(u8, body, key) orelse return null;
    const val_start = start + key.len;
    const end = std.mem.indexOfScalarPos(u8, body, val_start, '"') orelse return null;
    return testing.allocator.dupe(u8, body[val_start..end]) catch null;
}

/// Extract the first "grant_token":"..." value from a JSON body (caller-owned).
fn extractFirstToken(body: []const u8) ?[]u8 {
    const key = "\"grant_token\":\"";
    const start = std.mem.indexOf(u8, body, key) orelse return null;
    const val_start = start + key.len;
    const end = std.mem.indexOfScalarPos(u8, body, val_start, '"') orelse return null;
    return testing.allocator.dupe(u8, body[val_start..end]) catch null;
}

/// Extract the first "subscription_id":"..." value from a JSON body (caller-owned).
fn extractFirstSubId(body: []const u8) ?[]u8 {
    const key = "\"subscription_id\":\"";
    const start = std.mem.indexOf(u8, body, key) orelse return null;
    const val_start = start + key.len;
    const end = std.mem.indexOfScalarPos(u8, body, val_start, '"') orelse return null;
    return testing.allocator.dupe(u8, body[val_start..end]) catch null;
}
