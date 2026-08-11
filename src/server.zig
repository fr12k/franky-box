//! HTTP API server for franky-box — routes, auth, and handlers.

const std = @import("std");
const http = std.http;
const mem = std.mem;
const fmt = std.fmt;

const types = @import("types.zig");
const task_store = @import("store.zig");
const authn = @import("auth.zig");
const build_options = @import("build_options");

/// Admin API token – set via env var `FRANKY_BOX_ADMIN_TOKEN` or default.
const default_admin_token = "admin-token-change-me";
var admin_token: []const u8 = default_admin_token;

fn isAdmin(token: []const u8) bool {
    return mem.eql(u8, token, admin_token);
}

/// Set the admin API token (call before serving).
pub fn setAdminToken(token: []const u8) void {
    admin_token = token;
}

allocator: std.mem.Allocator,
io: std.Io,
store: *task_store.TaskStore,
agents: std.StringHashMap([]const u8),
next_dispatch_task_id: u64 = 0,

pub const Server = @This();

pub fn init(allocator: std.mem.Allocator, io: std.Io, store: *task_store.TaskStore) Server {
    return .{ .allocator = allocator, .io = io, .store = store, .agents = std.StringHashMap([]const u8).init(allocator) };
}

pub fn deinit(self: *Server) void {
    var it = self.agents.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.*);
    }
    self.agents.deinit();
}

fn json(req: *http.Server.Request, status: http.Status, body: []const u8) !void {
    try req.respond(body, .{ .status = status, .extra_headers = &.{
        .{ .name = "connection", .value = "close" },
        .{ .name = "content-type", .value = "application/json" },
    } });
}

fn errJson(a: std.mem.Allocator, req: *http.Server.Request, status: http.Status, msg: []const u8) !void {
    const body = try fmt.allocPrint(a, "{{\"error\":\"{s}\"}}", .{msg});
    defer a.free(body);
    try json(req, status, body);
}

fn headerValue(head_buffer: []const u8, name: []const u8) ?[]const u8 {
    var it = http.HeaderIterator.init(head_buffer);
    while (it.next()) |hdr| {
        if (std.ascii.eqlIgnoreCase(hdr.name, name)) return hdr.value;
    }
    return null;
}

fn parsePath(path: []const u8, a: std.mem.Allocator) ![][]const u8 {
    var segs: std.ArrayList([]const u8) = .empty;
    var it = mem.splitScalar(u8, path, '/');
    while (it.next()) |s| {
        if (s.len > 0) try segs.append(a, s);
    }
    return try segs.toOwnedSlice(a);
}

fn requireAgent(self: *Server, agent_id: []const u8, req: *http.Server.Request) bool {
    const auth_hdr = headerValue(req.head_buffer, "authorization") orelse return false;
    const token = authn.extractBearerToken(auth_hdr) orelse return false;
    return authn.validateBearerToken(token, agent_id, self.agents);
}

pub fn handle(self: *Server, req: *http.Server.Request, body: []const u8) !void {
    try handleWithPath(self, req, req.head.target, body);
}

pub fn handleWithPath(self: *Server, req: *http.Server.Request, path: []const u8, body: []const u8) !void {
    const method = req.head.method;
    const a = self.allocator;

    const segments = parsePath(path, a) catch |err| return errJson(a, req, .internal_server_error, @errorName(err));
    defer a.free(segments);

    if (segments.len == 2 and isSeg(segments[0], "v1") and isSeg(segments[1], "agents")) {
        if (method != .POST) return errJson(a, req, .method_not_allowed, "method not allowed");
        return self.handleRegisterAgent(req, body);
    }

    if (segments.len == 3 and isSeg(segments[0], "v1") and isSeg(segments[1], "tasks") and isSeg(segments[2], "dispatch")) {
        if (method != .POST) return errJson(a, req, .method_not_allowed, "method not allowed");
        return self.handleDispatch(req, body);
    }

    if (segments.len >= 3 and isSeg(segments[0], "v1") and isSeg(segments[1], "agents")) {
        const agent = segments[2];

        if (segments.len >= 5 and isSeg(segments[3], "inbox") and isSeg(segments[4], "claim")) {
            if (method != .POST) return errJson(a, req, .method_not_allowed, "method not allowed");
            if (!self.requireAgent(agent, req)) return errJson(a, req, .unauthorized, "unauthorized");
            return self.handleClaim(req, agent);
        }

        if (segments.len == 4 and isSeg(segments[3], "outbox")) {
            if (method != .GET) return errJson(a, req, .method_not_allowed, "method not allowed");
            if (!self.requireAgent(agent, req)) return errJson(a, req, .unauthorized, "unauthorized");
            return self.handleReadOutbox(req, agent);
        }

        if (segments.len >= 6 and isSeg(segments[3], "outbox") and isSeg(segments[5], "complete")) {
            if (method != .POST) return errJson(a, req, .method_not_allowed, "method not allowed");
            if (!self.requireAgent(agent, req)) return errJson(a, req, .unauthorized, "unauthorized");
            return self.handleComplete(req, agent, segments[4], body);
        }

        if (segments.len >= 6 and isSeg(segments[3], "outbox") and isSeg(segments[5], "fail")) {
            if (method != .POST) return errJson(a, req, .method_not_allowed, "method not allowed");
            if (!self.requireAgent(agent, req)) return errJson(a, req, .unauthorized, "unauthorized");
            return self.handleFail(req, agent, segments[4], body);
        }

        return errJson(a, req, .not_found, "route not found");
    }

    if (segments.len >= 3 and isSeg(segments[0], "v1") and isSeg(segments[1], "results")) {
        if (method != .GET) return errJson(a, req, .method_not_allowed, "method not allowed");
        return self.handleGetResult(req, segments[2]);
    }

    // --- Admin UI routes ---
    if (segments.len == 1 and isSeg(segments[0], "admin")) {
        if (method != .GET) return errJson(a, req, .method_not_allowed, "method not allowed");
        return self.handleAdminPage(req);
    }

    if (segments.len == 2 and isSeg(segments[0], "admin") and isSeg(segments[1], "api")) {
        if (method != .GET) return errJson(a, req, .method_not_allowed, "method not allowed");
        return self.handleAdminApi(req);
    }

    if (segments.len == 2 and isSeg(segments[0], "admin") and isSeg(segments[1], "agents")) {
        if (method != .GET) return errJson(a, req, .method_not_allowed, "method not allowed");
        return self.handleAdminAgentsApi(req);
    }

    if (segments.len == 2 and isSeg(segments[0], "admin") and isSeg(segments[1], "inbox")) {
        if (method != .GET) return errJson(a, req, .method_not_allowed, "method not allowed");
        return self.handleAdminInboxApi(req);
    }

    if (segments.len == 2 and isSeg(segments[0], "admin") and isSeg(segments[1], "outbox")) {
        if (method != .GET) return errJson(a, req, .method_not_allowed, "method not allowed");
        return self.handleAdminOutboxApi(req);
    }

    if (segments.len == 2 and isSeg(segments[0], "admin") and isSeg(segments[1], "dispatch")) {
        if (method != .POST) return errJson(a, req, .method_not_allowed, "method not allowed");
        return self.handleAdminDispatch(req, body);
    }

    if (segments.len == 2 and isSeg(segments[0], "admin") and isSeg(segments[1], "register-agent")) {
        if (method != .POST) return errJson(a, req, .method_not_allowed, "method not allowed");
        return self.handleAdminRegisterAgent(req);
    }

    return errJson(a, req, .not_found, "route not found");
}

fn handleRegisterAgent(self: *Server, req: *http.Server.Request, _: []const u8) !void {
    var buf: [32]u8 = undefined;
    self.io.random(&buf);
    const secret = try fmt.allocPrint(self.allocator, "{s}", .{fmt.bytesToHex(&buf, .lower)});
    defer self.allocator.free(secret);

    const agent_id = try fmt.allocPrint(self.allocator, "agent-{d}", .{self.agents.count()});
    errdefer self.allocator.free(agent_id);
    try self.agents.put(agent_id, try self.allocator.dupe(u8, secret));

    const resp = try fmt.allocPrint(self.allocator, "{{\"agent_id\":\"{s}\",\"agent_secret\":\"{s}\",\"team_id\":\"default\"}}", .{ agent_id, secret });
    defer self.allocator.free(resp);
    try json(req, .ok, resp);
}

fn handleDispatch(self: *Server, req: *http.Server.Request, body: []const u8) !void {
    // Generate a unique task_id from a monotonic counter.
    const task_id = try fmt.allocPrint(self.allocator, "task-{d}", .{self.next_dispatch_task_id});
    defer self.allocator.free(task_id);
    self.next_dispatch_task_id += 1;

    self.store.dispatch("default-team", "agent-0", task_id, "process", body) catch |err| {
        return errJson(self.allocator, req, .internal_server_error, @errorName(err));
    };
    const resp = try fmt.allocPrint(self.allocator, "{{\"task_id\":\"{s}\",\"status\":\"dispatched\"}}", .{task_id});
    defer self.allocator.free(resp);
    try json(req, .ok, resp);
}

fn handleClaim(self: *Server, req: *http.Server.Request, agent_id: []const u8) !void {
    const result = self.store.claim(self.allocator, "default-team", agent_id) catch |err| {
        return errJson(self.allocator, req, .internal_server_error, @errorName(err));
    };
    if (result) |claimed| {
        defer claimed.deinit(self.allocator);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        try buf.print(self.allocator, "{{\"task_id\":\"{s}\",\"action\":\"{s}\",\"payload\":", .{claimed.task_id, claimed.action});
        try jsonPayload(&buf, self.allocator, claimed.payload);
        try buf.print(self.allocator, ",\"try_count\":{d}}}", .{claimed.try_count});
        try json(req, .ok, buf.items);
    } else {
        try json(req, .no_content, "{}");
    }
}

fn handleComplete(self: *Server, req: *http.Server.Request, agent_id: []const u8, task_id: []const u8, body: []const u8) !void {
    const ok = self.store.complete("default-team", agent_id, task_id, body) catch |err| {
        return errJson(self.allocator, req, .internal_server_error, @errorName(err));
    };
    if (!ok) return errJson(self.allocator, req, .not_found, "task not found");

    if (self.agents.get(agent_id)) |secret| {
        const grant = authn.generateGrantToken(self.allocator, task_id, secret, 3600, 0) catch "{}";
        defer self.allocator.free(grant);
        const resp = try fmt.allocPrint(self.allocator, "{{\"task_id\":\"{s}\",\"status\":\"completed\",\"grant_token\":\"{s}\"}}", .{ task_id, grant });
        defer self.allocator.free(resp);
        try json(req, .ok, resp);
    } else {
        const resp = try fmt.allocPrint(self.allocator, "{{\"task_id\":\"{s}\",\"status\":\"completed\"}}", .{task_id});
        defer self.allocator.free(resp);
        try json(req, .ok, resp);
    }
}

fn handleFail(self: *Server, req: *http.Server.Request, agent_id: []const u8, task_id: []const u8, body: []const u8) !void {
    const ok = self.store.fail("default-team", agent_id, task_id, body) catch |err| {
        return errJson(self.allocator, req, .internal_server_error, @errorName(err));
    };
    if (!ok) return errJson(self.allocator, req, .not_found, "task not found");

    const resp = try fmt.allocPrint(self.allocator, "{{\"task_id\":\"{s}\",\"status\":\"failed\"}}", .{task_id});
    defer self.allocator.free(resp);
    try json(req, .ok, resp);
}

fn handleReadOutbox(self: *Server, req: *http.Server.Request, agent_id: []const u8) !void {
    const a = self.allocator;
    const results = self.store.readOutbox(a, "default-team", agent_id, "1970-01-01 00:00:00") catch |err| {
        return errJson(a, req, .internal_server_error, @errorName(err));
    };
    defer { for (results) |r| r.deinit(a); a.free(results); }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "[");
    for (results, 0..) |r, i| {
        if (i > 0) try buf.appendSlice(a, ",");
        try buf.print(a, "{{\"task_id\":\"{s}\",\"action\":\"{s}\",\"payload\":", .{r.task_id, r.action});
        try jsonPayload(&buf, a, r.payload);
        try buf.appendSlice(a, ",\"output\":");
        try jsonPayload(&buf, a, r.output);
        try buf.print(a, ",\"completed_at\":\"{s}\"}}", .{r.completed_at});
    }
    try buf.appendSlice(a, "]");
    try json(req, .ok, buf.items);
}

fn handleGetResult(self: *Server, req: *http.Server.Request, _: []const u8) !void {
    const target = req.head.target;
    const qpos = mem.indexOfScalar(u8, target, '?') orelse return errJson(self.allocator, req, .bad_request, "missing token");
    const qs = target[qpos + 1 ..];
    if (mem.indexOf(u8, qs, "token=") == null) return errJson(self.allocator, req, .bad_request, "missing token parameter");
    try json(req, .ok, "{\"status\":\"result_available\"}");
}

fn isSeg(seg: []const u8, lit: []const u8) bool { return mem.eql(u8, seg, lit); }

fn requireAdmin(req: *http.Server.Request) bool {
    // Check Authorization header first
    if (headerValue(req.head_buffer, "authorization")) |auth_hdr| {
        if (authn.extractBearerToken(auth_hdr)) |token| {
            if (isAdmin(token)) return true;
        }
    }
    // Fall back to fb_admin_token cookie
    if (headerValue(req.head_buffer, "cookie")) |cookie| {
        const needle = "fb_admin_token=";
        const start = mem.indexOf(u8, cookie, needle) orelse return false;
        const val_start = start + needle.len;
        var end = val_start;
        while (end < cookie.len and cookie[end] != ';') : (end += 1) {}
        const token = cookie[val_start..end];
        return isAdmin(token);
    }
    return false;
}

fn htmlResp(req: *http.Server.Request, body: []const u8) !void {
    try req.respond(body, .{ .extra_headers = &.{
        .{ .name = "content-type", .value = "text/html; charset=utf-8" },
    } });
}

/// Admin UI HTML, embedded from src/web/admin.html at compile time.
const admin_page_html = @embedFile("web/admin.html");

fn handleAdminPage(_: *Server, req: *http.Server.Request) !void {
    const page = admin_page_html;
    try htmlResp(req, page);
}

fn handleAdminApi(self: *Server, req: *http.Server.Request) !void {
    if (!requireAdmin(req)) return errJson(self.allocator, req, .unauthorized, "unauthorized");
    // v0.5.0 — report the real build version (injected by goreleaser via
    // -Dversion, see build.zig / src/root.zig) instead of a hard-coded
    // constant, so the admin UI and `franky-box update --check` agree.
    const body = try std.fmt.allocPrint(self.allocator, "{{\"status\":\"ok\",\"version\":\"{s}\"}}", .{build_options.version});
    defer self.allocator.free(body);
    try json(req, .ok, body);
}

fn handleAdminAgentsApi(self: *Server, req: *http.Server.Request) !void {
    if (!requireAdmin(req)) return errJson(self.allocator, req, .unauthorized, "unauthorized");
    const a = self.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "{\"agents\":[");
    var first = true;
    var it = self.agents.iterator();
    while (it.next()) |entry| {
        if (!first) try buf.appendSlice(a, ",");
        first = false;
        try buf.print(a, "{{\"agent_id\":\"{s}\",\"secret\":\"{s}\"}}", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
    try buf.appendSlice(a, "]}");
    try json(req, .ok, buf.items);
}

fn handleAdminInboxApi(self: *Server, req: *http.Server.Request) !void {
    if (!requireAdmin(req)) return errJson(self.allocator, req, .unauthorized, "unauthorized");
    const a = self.allocator;
    const tasks = self.store.fetchInbox(a) catch |err| return errJson(a, req, .internal_server_error, @errorName(err));
    defer { for (tasks) |t| t.deinit(a); a.free(tasks); }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "{\"tasks\":[");
    var first = true;
    for (tasks) |t| {
        if (!first) try buf.appendSlice(a, ",");
        first = false;
        const locked_s = if (t.locked_until) |lu| lu else "null";
        try buf.print(a, "{{\"task_id\":\"{s}\",\"agent_id\":\"{s}\",\"tenant_id\":\"{s}\",\"action\":\"{s}\",\"payload\":", .{t.task_id, t.agent_id, t.tenant_id, t.action});
        try jsonPayload(&buf, a, t.payload);
        try buf.print(a, ",\"try_count\":{d},\"locked_until\":\"{s}\"}}", .{ t.try_count, locked_s });
    }
    try buf.appendSlice(a, "]}");
    try json(req, .ok, buf.items);
}

fn handleAdminOutboxApi(self: *Server, req: *http.Server.Request) !void {
    if (!requireAdmin(req)) return errJson(self.allocator, req, .unauthorized, "unauthorized");
    const a = self.allocator;
    const tasks = self.store.fetchOutboxAll(a) catch |err| return errJson(a, req, .internal_server_error, @errorName(err));
    defer { for (tasks) |t| t.deinit(a); a.free(tasks); }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "{\"tasks\":[");
    var first = true;
    for (tasks) |t| {
        if (!first) try buf.appendSlice(a, ",");
        first = false;
        try buf.print(a, "{{\"task_id\":\"{s}\",\"action\":\"{s}\",\"payload\":", .{t.task_id, t.action});
        try jsonPayload(&buf, a, t.payload);
        try buf.appendSlice(a, ",\"output\":");
        try jsonPayload(&buf, a, t.output);
        try buf.print(a, ",\"completed_at\":\"{s}\"}}", .{t.completed_at});
    }
    try buf.appendSlice(a, "]}");
    try json(req, .ok, buf.items);
}

fn handleAdminDispatch(self: *Server, req: *http.Server.Request, body: []const u8) !void {
    if (!requireAdmin(req)) return errJson(self.allocator, req, .unauthorized, "unauthorized");
    const a = self.allocator;
    // Parse JSON body: { "agent_id": "...", "action": "...", "payload": "..." or {...} }
    // We use a simple approach – extract fields via json scanning.
    const agent_id = extractJsonField(body, "agent_id", a) orelse return errJson(a, req, .bad_request, "missing agent_id");
    defer a.free(agent_id);
    const action = extractJsonField(body, "action", a) orelse return errJson(a, req, .bad_request, "missing action");
    defer a.free(action);
    const payload_raw = extractJsonField(body, "payload", a) orelse return errJson(a, req, .bad_request, "missing payload");
    defer a.free(payload_raw);

    // Check agent exists
    if (!self.agents.contains(agent_id)) return errJson(a, req, .bad_request, "unknown agent");

    const task_id = try fmt.allocPrint(a, "task-{d}", .{self.next_dispatch_task_id});
    defer a.free(task_id);
    self.next_dispatch_task_id += 1;

    self.store.dispatch("default-team", agent_id, task_id, action, payload_raw) catch |err| {
        return errJson(a, req, .internal_server_error, @errorName(err));
    };
    const resp = try fmt.allocPrint(a, "{{\"task_id\":\"{s}\",\"status\":\"dispatched\"}}", .{task_id});
    defer a.free(resp);
    try json(req, .ok, resp);
}

fn handleAdminRegisterAgent(self: *Server, req: *http.Server.Request) !void {
    if (!requireAdmin(req)) return errJson(self.allocator, req, .unauthorized, "unauthorized");
    const a = self.allocator;
    var buf: [32]u8 = undefined;
    self.io.random(&buf);
    const secret = try fmt.allocPrint(a, "{s}", .{fmt.bytesToHex(&buf, .lower)});
    defer a.free(secret);
    const agent_id = try fmt.allocPrint(a, "agent-{d}", .{self.agents.count()});
    errdefer a.free(agent_id);
    try self.agents.put(agent_id, try a.dupe(u8, secret));
    const resp = try fmt.allocPrint(a, "{{\"agent_id\":\"{s}\",\"agent_secret\":\"{s}\",\"team_id\":\"default\"}}", .{ agent_id, secret });
    defer a.free(resp);
    try json(req, .ok, resp);
}

/// Emit a payload value as valid JSON: if it looks like a JSON object/array emit raw, otherwise quote+escape.
fn jsonPayload(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, raw: []const u8) !void {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len > 0 and (trimmed[0] == '{' or trimmed[0] == '[')) {
        try buf.appendSlice(allocator, raw);
    } else {
        try buf.append(allocator, '"');
        for (raw) |c| {
            switch (c) {
                '"' => try buf.appendSlice(allocator, "\\\""),
                '\\' => try buf.appendSlice(allocator, "\\\\"),
                '\n' => try buf.appendSlice(allocator, "\\n"),
                '\r' => try buf.appendSlice(allocator, "\\r"),
                '\t' => try buf.appendSlice(allocator, "\\t"),
                else => try buf.append(allocator, c),
            }
        }
        try buf.append(allocator, '"');
    }
}

/// Scan for `"<key>":` then extract the value (string, object, or literal).
fn extractJsonField(body: []const u8, key: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    const a = allocator;
    // find "<key>"  (with optional whitespace after colon)
    var pos: usize = 0;
    while (pos < body.len) {
        // find quote
        const q = mem.indexOfScalarPos(u8, body, pos, '"') orelse return null;
        const end_q = mem.indexOfScalarPos(u8, body, q + 1, '"') orelse return null;
        const k = body[q + 1 .. end_q];
        if (mem.eql(u8, k, key)) {
            // found key, skip colon and whitespace
            var p = end_q + 1;
            while (p < body.len and (body[p] == ':' or body[p] == ' ' or body[p] == '\t')) : (p += 1) {}
            if (p >= body.len) return null;
            const c = body[p];
            if (c == '"') {
                // string
                var i: usize = p + 1;
                while (i < body.len) : (i += 1) {
                    if (body[i] == '\\' and i + 1 < body.len) { i += 1; continue; }
                    if (body[i] == '"') {
                        return a.dupe(u8, body[p + 1 .. i]) catch null;
                    }
                }
                return null;
            } else if (c == '{' or c == '[') {
                var depth: u32 = 1;
                var i: usize = p + 1;
                while (i < body.len and depth > 0) : (i += 1) {
                    if (body[i] == '{' or body[i] == '[') depth += 1;
                    if (body[i] == '}' or body[i] == ']') depth -= 1;
                }
                return a.dupe(u8, body[p..i]) catch null;
            } else {
                // number / bool / null
                var i: usize = p;
                while (i < body.len and body[i] != ',' and body[i] != '}' and body[i] != ']') : (i += 1) {}
                return a.dupe(u8, body[p..i]) catch null;
            }
        }
        pos = end_q + 1;
    }
    return null;
}

pub fn registerDefaultAgent(self: *Server) !void {
    try self.agents.put(try self.allocator.dupe(u8, "agent-0"), try self.allocator.dupe(u8, "default-secret-please-change"));
}