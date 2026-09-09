//! HTTP API server for franky-box — routes, auth, and handlers.

const std = @import("std");
const http = std.http;
const mem = std.mem;
const fmt = std.fmt;

const types = @import("types.zig");
const task_store = @import("store.zig");
const authn = @import("auth.zig");
const uuid = @import("uuid.zig");
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

pub fn handleWithPath(self: *Server, req: *http.Server.Request, path_with_query: []const u8, body: []const u8) !void {
    const method = req.head.method;
    const a = self.allocator;

    // Split the query string off the target so path routing only sees the
    // path (segments), and queryParam reads the query part (via head_buffer).
    const path = if (mem.indexOfScalar(u8, path_with_query, '?')) |q| path_with_query[0..q] else path_with_query;

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

        if (segments.len >= 6 and isSeg(segments[3], "outbox") and isSeg(segments[5], "ack")) {
            if (method != .POST) return errJson(a, req, .method_not_allowed, "method not allowed");
            if (!self.requireAgent(agent, req)) return errJson(a, req, .unauthorized, "unauthorized");
            return self.handleAck(req, agent, segments[4]);
        }

        if (segments.len >= 5 and isSeg(segments[3], "outbox") and isSeg(segments[4], "ack-all")) {
            if (method != .POST) return errJson(a, req, .method_not_allowed, "method not allowed");
            if (!self.requireAgent(agent, req)) return errJson(a, req, .unauthorized, "unauthorized");
            return self.handleAckAll(req, agent);
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
    // The admin UI is an htmx 4 single-page shell (GET /admin) whose nav
    // links issue hx-get to the fragment endpoints below. Fragment endpoints
    // return HTML (text/html), not JSON; only /admin/api stays JSON (used by
    // `franky-box update --check`). See HTMX_ADMIN_RFC.md.
    if (segments.len == 1 and isSeg(segments[0], "admin")) {
        if (method != .GET) return errJson(a, req, .method_not_allowed, "method not allowed");
        return self.handleAdminPage(req);
    }

    // Vendored htmx 4 library (served as application/javascript so the browser
    // can execute it; embedded at compile time, no CDN/runtime dependency).
    if (segments.len == 2 and isSeg(segments[0], "admin") and isSeg(segments[1], "htmx.min.js")) {
        if (method != .GET) return errJson(a, req, .method_not_allowed, "method not allowed");
        try req.respond(htmx_js, .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "application/javascript; charset=utf-8" },
            .{ .name = "cache-control", .value = "public, max-age=86400" },
        } });
        return;
    }

    if (segments.len == 2 and isSeg(segments[0], "admin") and isSeg(segments[1], "api")) {
        if (method != .GET) return errJson(a, req, .method_not_allowed, "method not allowed");
        return self.handleAdminApi(req);
    }

    if (segments.len == 2 and isSeg(segments[0], "admin") and isSeg(segments[1], "agents")) {
        if (method != .GET) return errJson(a, req, .method_not_allowed, "method not allowed");
        return self.handleAdminAgentsFragment(req);
    }

    if (segments.len == 2 and isSeg(segments[0], "admin") and isSeg(segments[1], "inbox")) {
        if (method != .GET) return errJson(a, req, .method_not_allowed, "method not allowed");
        return self.handleAdminInboxFragment(req);
    }

    if (segments.len == 2 and isSeg(segments[0], "admin") and isSeg(segments[1], "outbox")) {
        if (method != .GET) return errJson(a, req, .method_not_allowed, "method not allowed");
        return self.handleAdminOutboxFragment(req);
    }

    if (segments.len == 2 and isSeg(segments[0], "admin") and isSeg(segments[1], "archive")) {
        if (method != .GET) return errJson(a, req, .method_not_allowed, "method not allowed");
        return self.handleAdminArchiveFragment(req);
    }

    if (segments.len == 2 and isSeg(segments[0], "admin") and isSeg(segments[1], "workstreams")) {
        if (method != .GET) return errJson(a, req, .method_not_allowed, "method not allowed");
        return self.handleAdminWorkstreamsFragment(req);
    }

    if (segments.len == 3 and isSeg(segments[0], "admin") and isSeg(segments[1], "fragments") and isSeg(segments[2], "dispatch")) {
        if (method != .GET) return errJson(a, req, .method_not_allowed, "method not allowed");
        return self.handleAdminDispatchForm(req);
    }

    if (segments.len == 3 and isSeg(segments[0], "admin") and isSeg(segments[1], "fragments") and isSeg(segments[2], "workstream-options")) {
        if (method != .GET) return errJson(a, req, .method_not_allowed, "method not allowed");
        return self.handleAdminWorkstreamOptions(req);
    }

    // Admin dispatch: form-encoded input (htmx submits the <form> as
    // application/x-www-form-urlencoded), HTML-fragment output (a toast).
    if (segments.len == 2 and isSeg(segments[0], "admin") and isSeg(segments[1], "dispatch")) {
        if (method != .POST) return errJson(a, req, .method_not_allowed, "method not allowed");
        return self.handleAdminDispatch(req, body);
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
    // Generate a unique task id (t_ + UUID) and a separate workstream id (w_ + UUID).
    const task_id = try uuid.newTaskId(self.io, self.allocator);
    defer self.allocator.free(task_id);
    const workstream_id = try uuid.newWorkstreamId(self.io, self.allocator);
    defer self.allocator.free(workstream_id);

    self.store.dispatch("default-team", "agent-0", task_id, "process", body, workstream_id) catch |err| {
        return errJson(self.allocator, req, .internal_server_error, @errorName(err));
    };
    const resp = try fmt.allocPrint(self.allocator, "{{\"task_id\":\"{s}\",\"workstream_id\":\"{s}\",\"status\":\"dispatched\"}}", .{ task_id, workstream_id });
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
        try buf.print(self.allocator, "{{\"task_id\":\"{s}\",\"action\":\"{s}\",\"payload\":", .{ claimed.task_id, claimed.action });
        try jsonPayload(&buf, self.allocator, claimed.payload);
        try buf.print(self.allocator, ",\"try_count\":{d}", .{claimed.try_count});
        // Workstream linkage (optional).
        try buf.appendSlice(self.allocator, ",");
        try emitOptField(&buf, self.allocator, "workstream_id", claimed.workstream_id);
        try buf.appendSlice(self.allocator, "}");
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
    // Honor the ?since=<timestamp> cursor: only results completed after the
    // given timestamp are returned. Consumers pass the newest completed_at
    // they have seen to avoid re-downloading the entire outbox each poll.
    // Missing or empty ?since falls back to the epoch (all unconsumed results)
    // so a bare `?since=` cannot silently filter everything out.
    const since_owned = queryParamDup(a, req.head_buffer, "since");
    defer if (since_owned) |s| a.free(s);
    var since: []const u8 = "1970-01-01 00:00:00";
    if (since_owned) |s| {
        if (s.len > 0) since = s;
    }
    const results = self.store.readOutbox(a, "default-team", agent_id, since) catch |err| {
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
        try buf.print(a, ",\"completed_at\":\"{s}\",", .{r.completed_at});
        try emitOptField(&buf, a, "workstream_id", r.workstream_id);
        try buf.appendSlice(a, "}");
    }
    try buf.appendSlice(a, "]");
    try json(req, .ok, buf.items);
}

fn handleAck(self: *Server, req: *http.Server.Request, agent_id: []const u8, task_id: []const u8) !void {
    const a = self.allocator;
    const ok = self.store.ack("default-team", agent_id, task_id) catch |err| {
        return errJson(a, req, .internal_server_error, @errorName(err));
    };
    if (!ok) return errJson(a, req, .not_found, "task not found or not consumable");
    const resp = try fmt.allocPrint(a, "{{\"task_id\":\"{s}\",\"status\":\"consumed\"}}", .{task_id});
    defer a.free(resp);
    try json(req, .ok, resp);
}

fn handleAckAll(self: *Server, req: *http.Server.Request, agent_id: []const u8) !void {
    const a = self.allocator;
    // Optional ?before=<timestamp> bounds the ack: only results completed at
    // or before that timestamp are consumed (default: ack everything).
    const before_owned = queryParamDup(a, req.head_buffer, "before");
    defer if (before_owned) |b| a.free(b);
    const before: []const u8 = before_owned orelse "9999-12-31 23:59:59";
    const result = self.store.ackAll("default-team", agent_id, before) catch |err| {
        return errJson(a, req, .internal_server_error, @errorName(err));
    };
    const resp = try fmt.allocPrint(a, "{{\"status\":\"consumed\",\"acked\":{d},\"archived\":{d}}}", .{ result.acked, result.archived });
    defer a.free(resp);
    try json(req, .ok, resp);
}

fn handleGetResult(self: *Server, req: *http.Server.Request, _: []const u8) !void {
    const target = req.head.target;
    const qpos = mem.indexOfScalar(u8, target, '?') orelse return errJson(self.allocator, req, .bad_request, "missing token");
    const qs = target[qpos + 1 ..];
    if (mem.indexOf(u8, qs, "token=") == null) return errJson(self.allocator, req, .bad_request, "missing token parameter");
    try json(req, .ok, "{\"status\":\"result_available\"}");
}

fn isSeg(seg: []const u8, lit: []const u8) bool { return mem.eql(u8, seg, lit); }

/// Extract a query-string parameter (?key=value or &key=value) from the raw
/// request head buffer. The target line (`GET /path?k=v HTTP/1.1`) lives in the
/// same buffer, so a simple scan is enough. Returns a slice into head_buffer
/// (no allocation, no URL-decoding — values here are timestamps / ids).
fn queryParam(head_buffer: []const u8, key: []const u8) ?[]const u8 {
    // Find the request line's query string first.
    const line_end = mem.indexOfScalar(u8, head_buffer, '\n') orelse return null;
    const line = head_buffer[0..line_end];
    const qpos = mem.indexOfScalar(u8, line, '?') orelse return null;
    var rest = line[qpos + 1 ..];
    if (mem.indexOfScalar(u8, rest, ' ')) |sp| rest = rest[0..sp];
    var it = mem.splitScalar(u8, rest, '&');
    while (it.next()) |pair| {
        const eq = mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

/// Like `queryParam`, but percent-decodes the value ('%20' → space, '+' →
/// space) into caller-owned allocated memory. Use for values that are not
/// simple tokens (e.g. timestamps with spaces). Returns null when missing.
/// The returned slice's length matches the allocation exactly (two-pass
/// decode-count-then-fill), so `allocator.free` on it is valid.
fn queryParamDup(a: std.mem.Allocator, head_buffer: []const u8, key: []const u8) ?[]const u8 {
    const raw = queryParam(head_buffer, key) orelse return null;
    // Two-pass decode (count, then fill): decoding never expands (%XX → 1
    // byte, '+' → 1 byte), so pass 1 yields the exact output length and pass 2
    // allocates exactly that — Zig's allocator.free requires the returned
    // slice's length to match the allocation, so a realloc-based shrink is
    // not portable here (realloc must receive the full-length slice).
    var n: usize = 0;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '%' and i + 3 <= raw.len) {
            if (std.fmt.charToDigit(raw[i + 1], 16) catch null) |_| {
                if (std.fmt.charToDigit(raw[i + 2], 16) catch null) |_| {
                    n += 1;
                    i += 3;
                    continue;
                }
            }
        }
        n += 1;
        i += 1;
    }
    const out = a.alloc(u8, n) catch return null;
    var o: usize = 0;
    i = 0;
    while (i < raw.len) {
        if (raw[i] == '+') {
            out[o] = ' ';
            o += 1;
            i += 1;
        } else if (raw[i] == '%' and i + 3 <= raw.len) {
            if (std.fmt.charToDigit(raw[i + 1], 16) catch null) |hi| {
                if (std.fmt.charToDigit(raw[i + 2], 16) catch null) |lo| {
                    out[o] = @intCast(hi * 16 + lo);
                    o += 1;
                    i += 3;
                    continue;
                }
            }
            out[o] = raw[i];
            o += 1;
            i += 1;
        } else {
            out[o] = raw[i];
            o += 1;
            i += 1;
        }
    }
    return out[0..o];
}

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

/// HTML-escape `src` into `buf`. Replaces the browser-side `escapeHtml()` and,
/// for admin views, the server-side JSON escapers (`jsonString`/`jsonPayload`).
/// Escapes &, <, >, ", ' to prevent HTML injection from user-supplied data.
fn htmlEscape(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, src: []const u8) !void {
    for (src) |c| {
        switch (c) {
            '&' => try buf.appendSlice(allocator, "&amp;"),
            '<' => try buf.appendSlice(allocator, "&lt;"),
            '>' => try buf.appendSlice(allocator, "&gt;"),
            '"' => try buf.appendSlice(allocator, "&quot;"),
            '\'' => try buf.appendSlice(allocator, "&#39;"),
            else => try buf.append(allocator, c),
        }
    }
}

/// Respond with an HTML error fragment (a toast) at the given HTTP status.
/// htmx 4 swaps 4xx/5xx responses into the target by default, so the error
/// toast lands in the user-visible target with zero client-side JS.
fn htmlError(a: std.mem.Allocator, req: *http.Server.Request, status: http.Status, msg: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "<div class=\"toast error\">");
    try htmlEscape(&buf, a, msg);
    try buf.appendSlice(a, "</div>");
    try req.respond(buf.items, .{ .status = status, .extra_headers = &.{
        .{ .name = "content-type", .value = "text/html; charset=utf-8" },
    } });
}

/// Like htmlError, but emits a disabled <option> instead of a <div> toast.
/// Used by handlers whose response is swapped into a <select> (where a <div>
/// would be invalid HTML and not render).
fn htmlOptionError(a: std.mem.Allocator, req: *http.Server.Request, status: http.Status, msg: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "<option value=\"\" disabled>");
    try htmlEscape(&buf, a, msg);
    try buf.appendSlice(a, "</option>");
    try req.respond(buf.items, .{ .status = status, .extra_headers = &.{
        .{ .name = "content-type", .value = "text/html; charset=utf-8" },
    } });
}

/// Extract a field from an `application/x-www-form-urlencoded` body.
/// URL-decodes the value. Returns a caller-owned slice (allocator), or null if
/// the field is absent. Replaces `extractJsonField`+`stripJsonString` for the
/// form-encoded admin dispatch/register routes (the agent JSON routes keep
/// `extractJsonField`).
fn formField(body: []const u8, key: []const u8, allocator: std.mem.Allocator) ?[]u8 {
    var it = mem.splitScalar(u8, body, '&');
    while (it.next()) |pair| {
        const eq = mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!mem.eql(u8, pair[0..eq], key)) continue;
        const enc = pair[eq + 1 ..];
        // URL-decode (%XX and +). An empty decoded value counts as absent
        // (returns null) so callers can treat `workstream_id=` (the placeholder
        // <option>) and a missing field identically — no per-call empty-string
        // guards needed.
        const out = allocator.alloc(u8, enc.len) catch return null;
        var oi: usize = 0;
        var i: usize = 0;
        while (i < enc.len) : (i += 1) {
            if (enc[i] == '+') {
                out[oi] = ' ';
                oi += 1;
            } else if (enc[i] == '%' and i + 2 < enc.len) {
                const hi = std.fmt.charToDigit(enc[i + 1], 16) catch {
                    out[oi] = enc[i];
                    oi += 1;
                    continue;
                };
                const lo = std.fmt.charToDigit(enc[i + 2], 16) catch {
                    out[oi] = enc[i];
                    oi += 1;
                    continue;
                };
                out[oi] = @intCast(hi * 16 + lo);
                oi += 1;
                i += 2;
            } else {
                out[oi] = enc[i];
                oi += 1;
            }
        }
        if (oi == 0) {
            allocator.free(out);
            return null;
        }
        // On realloc failure, free the original and report absence rather than
        // returning a slice into a possibly-invalidated allocation.
        return allocator.realloc(out, oi) catch {
            allocator.free(out);
            return null;
        };
    }
    return null;
}

/// Admin UI HTML, embedded from src/web/admin.html at compile time.
const admin_page_html = @embedFile("web/admin.html");
/// htmx 4 library, embedded at compile time so the binary is self-contained
/// (no CDN/runtime dependency; same approach as the SQLite amalgamation).
const htmx_js = @embedFile("web/htmx.min.js");

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

fn handleAdminAgentsFragment(self: *Server, req: *http.Server.Request) !void {
    if (!requireAdmin(req)) return htmlError(self.allocator, req, .unauthorized, "unauthorized");
    const a = self.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "<h2 id=\"agents\">🤖 Registered Agents</h2>");
    if (self.agents.count() == 0) {
        try buf.appendSlice(a, "<p>No agents registered.</p>");
    } else {
        try buf.appendSlice(a, "<table class=\"resp-table\" id=\"agents-table\"><thead><tr><th>Agent ID</th><th>Secret</th></tr></thead><tbody>");
        var it = self.agents.iterator();
        while (it.next()) |entry| {
            try buf.appendSlice(a, "<tr><td data-label=\"Agent ID\">");
            try htmlEscape(&buf, a, entry.key_ptr.*);
            try buf.appendSlice(a, "</td><td data-label=\"Secret\"><code>");
            try htmlEscape(&buf, a, entry.value_ptr.*);
            try buf.appendSlice(a, "</code></td></tr>");
        }
        try buf.appendSlice(a, "</tbody></table>");
    }
    try htmlResp(req, buf.items);
}

fn handleAdminInboxFragment(self: *Server, req: *http.Server.Request) !void {
    if (!requireAdmin(req)) return htmlError(self.allocator, req, .unauthorized, "unauthorized");
    const a = self.allocator;
    const tasks = self.store.fetchInbox(a) catch |err| return htmlError(a, req, .internal_server_error, @errorName(err));
    defer { for (tasks) |t| t.deinit(a); a.free(tasks); }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "<h2 id=\"inbox\">📥 Inbox (Pending Tasks)</h2>");
    if (tasks.len == 0) {
        try buf.appendSlice(a, "<p>No pending tasks.</p>");
    } else {
        try buf.appendSlice(a, "<table class=\"resp-table\"><thead><tr><th>Task ID</th><th>Workstream</th><th>Agent</th><th>Action</th><th>Payload</th><th>Try</th><th>Locked Until</th></tr></thead><tbody>");
        for (tasks) |t| {
            const lock_class = if (t.locked_until != null) "locked" else "pending";
            try buf.appendSlice(a, "<tr><td data-label=\"Task ID\"><code>");
            try htmlEscape(&buf, a, t.task_id);
            try buf.appendSlice(a, "</code></td><td data-label=\"Workstream\"><code>");
            if (t.workstream_id) |w| try htmlEscape(&buf, a, w) else try buf.appendSlice(a, "-");
            try buf.appendSlice(a, "</code></td><td data-label=\"Agent\">");
            try htmlEscape(&buf, a, t.agent_id);
            try buf.appendSlice(a, "</td><td data-label=\"Action\">");
            try htmlEscape(&buf, a, t.action);
            try buf.appendSlice(a, "</td><td data-label=\"Payload\"><pre>");
            try htmlEscape(&buf, a, t.payload);
            try buf.appendSlice(a, "</pre></td><td data-label=\"Try\"><span class=\"status-badge ");
            try buf.appendSlice(a, lock_class);
            try buf.print(a, "\">{d}</span></td><td data-label=\"Locked Until\">", .{t.try_count});
            if (t.locked_until) |lu| try htmlEscape(&buf, a, lu) else try buf.appendSlice(a, "-");
            try buf.appendSlice(a, "</td></tr>");
        }
        try buf.appendSlice(a, "</tbody></table>");
    }
    try htmlResp(req, buf.items);
}

/// Shared builder for the outbox and archive tables (same columns). The
/// `consumed_label` differs: outbox shows "waiting for consumer…", archive
/// shows "aged out unconsumed" for null consumed_at.
fn writeOutboxTable(buf: *std.ArrayList(u8), a: std.mem.Allocator, tasks: []const types.OutboxResult, consumed_label: []const u8) !void {
    if (tasks.len == 0) {
        try buf.appendSlice(a, "<p>No completed tasks.</p>");
        return;
    }
    try buf.appendSlice(a, "<table class=\"resp-table\"><thead><tr><th>Task ID</th><th>Workstream</th><th>Action</th><th>Payload</th><th>Output</th><th>Completed At</th><th>Consumed At</th></tr></thead><tbody>");
    for (tasks) |t| {
        try buf.appendSlice(a, "<tr><td data-label=\"Task ID\"><code>");
        try htmlEscape(buf, a, t.task_id);
        try buf.appendSlice(a, "</code></td><td data-label=\"Workstream\"><code>");
        if (t.workstream_id) |w| try htmlEscape(buf, a, w) else try buf.appendSlice(a, "-");
        try buf.appendSlice(a, "</code></td><td data-label=\"Action\">");
        try htmlEscape(buf, a, t.action);
        try buf.appendSlice(a, "</td><td data-label=\"Payload\"><pre>");
        try htmlEscape(buf, a, t.payload);
        try buf.appendSlice(a, "</pre></td><td data-label=\"Output\"><pre>");
        try htmlEscape(buf, a, t.output);
        try buf.appendSlice(a, "</pre></td><td data-label=\"Completed At\">");
        try htmlEscape(buf, a, t.completed_at);
        try buf.appendSlice(a, "</td><td data-label=\"Consumed At\">");
        if (t.consumed_at) |c| try htmlEscape(buf, a, c) else try buf.appendSlice(a, consumed_label);
        try buf.appendSlice(a, "</td></tr>");
    }
    try buf.appendSlice(a, "</tbody></table>");
}

fn handleAdminOutboxFragment(self: *Server, req: *http.Server.Request) !void {
    if (!requireAdmin(req)) return htmlError(self.allocator, req, .unauthorized, "unauthorized");
    const a = self.allocator;
    const tasks = self.store.fetchOutboxAll(a) catch |err| return htmlError(a, req, .internal_server_error, @errorName(err));
    defer { for (tasks) |t| t.deinit(a); a.free(tasks); }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "<h2 id=\"outbox\">📤 Outbox (Completed Tasks)</h2><p>Results stay here until a consumer <em>acks</em> them (POST /v1/agents/&lt;id&gt;/outbox/&lt;task&gt;/ack). Consumed results retire to the archive after a grace window.</p>");
    try writeOutboxTable(&buf, a, tasks, "<em>waiting for consumer…</em>");
    try htmlResp(req, buf.items);
}

fn handleAdminArchiveFragment(self: *Server, req: *http.Server.Request) !void {
    if (!requireAdmin(req)) return htmlError(self.allocator, req, .unauthorized, "unauthorized");
    const a = self.allocator;
    const tasks = self.store.fetchArchive(a) catch |err| return htmlError(a, req, .internal_server_error, @errorName(err));
    defer { for (tasks) |t| t.deinit(a); a.free(tasks); }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "<h2 id=\"archive\">🗄️ Archive (Retired Tasks)</h2><p>Consumed (or aged-out) results, kept forever. Nothing is ever hard-deleted.</p>");
    try writeOutboxTable(&buf, a, tasks, "<em>aged out unconsumed</em>");
    try htmlResp(req, buf.items);
}

fn handleAdminWorkstreamsFragment(self: *Server, req: *http.Server.Request) !void {
    if (!requireAdmin(req)) return htmlError(self.allocator, req, .unauthorized, "unauthorized");
    const a = self.allocator;
    const streams = self.store.fetchWorkstreams(a) catch |err| return htmlError(a, req, .internal_server_error, @errorName(err));
    defer { for (streams) |s| s.deinit(a); a.free(streams); }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "<h2 id=\"workstreams\">🔗 Workstreams</h2>");
    if (streams.len == 0) {
        try buf.appendSlice(a, "<p>No workstreams yet. Dispatch a task with a workstream name to create one.</p>");
    } else {
        try buf.appendSlice(a, "<table class=\"resp-table\"><thead><tr><th>Name</th><th>Workstream ID</th><th>Tasks</th><th>Last Activity</th><th>Created</th></tr></thead><tbody>");
        for (streams) |s| {
            try buf.appendSlice(a, "<tr><td data-label=\"Name\">");
            if (s.name.len > 0) try htmlEscape(&buf, a, s.name) else try buf.appendSlice(a, "<em>(unnamed)</em>");
            try buf.appendSlice(a, "</td><td data-label=\"Workstream ID\"><code>");
            try htmlEscape(&buf, a, s.workstream_id);
            try buf.print(a, "</code></td><td data-label=\"Tasks\">{d}</td><td data-label=\"Last Activity\">", .{s.task_count});
            if (s.last_seen.len > 0) try htmlEscape(&buf, a, s.last_seen) else try buf.appendSlice(a, "-");
            try buf.appendSlice(a, "</td><td data-label=\"Created\">");
            if (s.created_at.len > 0) try htmlEscape(&buf, a, s.created_at) else try buf.appendSlice(a, "-");
            try buf.appendSlice(a, "</td></tr>");
        }
        try buf.appendSlice(a, "</tbody></table>");
    }
    try htmlResp(req, buf.items);
}

/// The dispatch <form> fragment. htmx swaps this into #content when the
/// "Send Task" nav link is clicked. The form itself hx-posts to /admin/dispatch
/// on submit and swaps the toast into #dispatchResult. The workstream <select>
/// seeds its <option>s from /admin/fragments/workstream-options on load.
fn handleAdminDispatchForm(self: *Server, req: *http.Server.Request) !void {
    if (!requireAdmin(req)) return htmlError(self.allocator, req, .unauthorized, "unauthorized");
    const form =
        \\ <h2 id="dispatch">📨 Send Task to Agent</h2>
        \\ <form hx-post="/admin/dispatch" hx-target="#dispatchResult" hx-swap="innerHTML">
        \\   <label>Agent ID
        \\     <input type="text" name="agent_id" value="agent-0" required />
        \\   </label>
        \\   <label>Action
        \\     <input type="text" name="action" value="process" required />
        \\   </label>
        \\   <label>Payload (JSON)
        \\     <textarea name="payload" rows="4" required>{"key": "value"}</textarea>
        \\   </label>
        \\   <fieldset style="border:1px solid #ddd;padding:.5rem .75rem;margin-bottom:1rem">
        \\     <legend style="font-weight:bold">Workstream</legend>
        \\     <label>Join an existing workstream
        \\       <select name="workstream_id" id="dispatchWorkstreamId"
        \\               hx-get="/admin/fragments/workstream-options" hx-target="this" hx-trigger="load">
        \\         <option value="">— none (create new below) —</option>
        \\       </select>
        \\     </label>
        \\     <label>…or create a new workstream by name
        \\       <input type="text" name="workstream_name" placeholder="e.g. Daily Newsletter Summary" maxlength="256" />
        \\     </label>
        \\     <small style="display:block;color:#888;margin-top:.25rem">Leave both empty to auto-generate an anonymous workstream.</small>
        \\   </fieldset>
        \\   <button type="submit">🚀 Dispatch</button>
        \\ </form>
        \\ <div id="dispatchResult"></div>
    ;
    try htmlResp(req, form);
}

/// <option> fragment for the dispatch form's workstream <select>.
/// htmx swaps these into the <select> on load (hx-trigger="load").
fn handleAdminWorkstreamOptions(self: *Server, req: *http.Server.Request) !void {
    const a = self.allocator;
    // Errors are emitted as <option> elements (not a <div> toast) because htmx
    // swaps this response into a <select>; a <div> inside a <select> is invalid
    // HTML and would not render. htmlOptionError handles this.
    if (!requireAdmin(req)) return htmlOptionError(a, req, .unauthorized, "unauthorized");
    const streams = self.store.fetchWorkstreams(a) catch |err| return htmlOptionError(a, req, .internal_server_error, @errorName(err));
    defer { for (streams) |s| s.deinit(a); a.free(streams); }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    // htmx swaps into the <select> (hx-swap="innerHTML"), replacing all children.
    // Re-emit the placeholder first so the "— none —" option survives the swap.
    try buf.appendSlice(a, "<option value=\"\">— none (create new below) —</option>");
    for (streams) |s| {
        try buf.appendSlice(a, "<option value=\"");
        try htmlEscape(&buf, a, s.workstream_id);
        try buf.appendSlice(a, "\">");
        if (s.name.len > 0) try htmlEscape(&buf, a, s.name) else try buf.appendSlice(a, "(unnamed)");
        try buf.print(a, " — {d} tasks</option>", .{s.task_count});
    }
    try htmlResp(req, buf.items);
}

fn handleAdminDispatch(self: *Server, req: *http.Server.Request, body: []const u8) !void {
    if (!requireAdmin(req)) return htmlError(self.allocator, req, .unauthorized, "unauthorized");
    const a = self.allocator;
    // Parse form-encoded body (htmx submits the <form> as
    // application/x-www-form-urlencoded). formField URL-decodes values.
    const agent_id = formField(body, "agent_id", a) orelse return htmlError(a, req, .bad_request, "missing agent_id");
    defer a.free(agent_id);
    const action = formField(body, "action", a) orelse return htmlError(a, req, .bad_request, "missing action");
    defer a.free(action);
    const payload_raw = formField(body, "payload", a) orelse return htmlError(a, req, .bad_request, "missing payload");
    defer a.free(payload_raw);

    // Resolve the workstream id. Three modes (first match wins):
    //   1. workstream_id given  → must already exist (lookup), else 400.
    //   2. workstream_name given → lookup by name; if found join, if not create + join.
    //   3. neither given         → generate a fresh workstream UUID (no name row).
    // formField returns null for absent OR empty values, so the placeholder
    // <option value=""> the browser always submits is treated as not-given.
    const ws_id = formField(body, "workstream_id", a);
    defer if (ws_id) |w| a.free(w);
    const ws_name = formField(body, "workstream_name", a);
    defer if (ws_name) |w| a.free(w);

    // Check agent exists
    if (!self.agents.contains(agent_id)) return htmlError(a, req, .bad_request, "unknown agent");

    // Generate a unique task id (t_ + v4 UUID).
    const task_id = try uuid.newTaskId(self.io, a);
    defer a.free(task_id);

    // Resolve the workstream id per the three modes above.
    // `owned_ws` owns any id we allocate (lookup dupe or new UUID); freed at end.
    var owned_ws: ?[]u8 = null;
    defer if (owned_ws) |w| a.free(w);
    const ws: []const u8 = blk: {
        if (ws_id) |id| {
            // Mode 1: explicit id — must exist.
            const found = try self.store.lookupWorkstreamById(a, id);
            if (found) |fid| { owned_ws = fid; break :blk fid; }
            return htmlError(a, req, .bad_request, "workstream_id not found");
        }
        if (ws_name) |name| {
            if (name.len > 256) return htmlError(a, req, .bad_request, "workstream_name exceeds 256 characters");
            // Mode 2: name — lookup, then create-or-join.
            const found = try self.store.lookupWorkstreamByName(a, name);
            if (found) |fid| { owned_ws = fid; break :blk fid; }
            // Not found — create it. A duplicate name (race or deliberate) → 409.
            const new_id = try uuid.newWorkstreamId(self.io, a);
            owned_ws = new_id;
            self.store.createWorkstream(new_id, name) catch |err| {
                if (err == error.DuplicateWorkstreamName) return htmlError(a, req, .conflict, "workstream name already exists");
                return htmlError(a, req, .internal_server_error, @errorName(err));
            };
            break :blk new_id;
        }
        // Mode 3: neither given — generate a fresh anonymous workstream id (w_ + UUID).
        const new_id = try uuid.newWorkstreamId(self.io, a);
        owned_ws = new_id;
        break :blk new_id;
    };

    self.store.dispatch("default-team", agent_id, task_id, action, payload_raw, ws) catch |err| {
        return htmlError(a, req, .internal_server_error, @errorName(err));
    };
    // Respond with an HTML toast fragment; htmx swaps it into #dispatchResult.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "<div class=\"toast success\">✅ Task dispatched: <code>");
    try htmlEscape(&buf, a, task_id);
    try buf.appendSlice(a, "</code><br>workstream: <code>");
    try htmlEscape(&buf, a, ws);
    try buf.appendSlice(a, "</code></div>");
    try htmlResp(req, buf.items);
}


/// Emit a properly-escaped JSON string (opening + closing quotes, escaped contents).
/// Used for all string values in JSON responses to prevent injection of `"`, `\`,
/// or control characters from user-supplied data (e.g. workstream names).
fn jsonString(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, raw: []const u8) !void {
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

/// Emit a JSON key/value pair for an optional string field: `"key":"value"` or `"key":null`.
/// The value is JSON-escaped to prevent injection of quotes/control chars.
fn emitOptField(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, key: []const u8, value: ?[]const u8) !void {
    if (value) |v| {
        try buf.print(allocator, "\"{s}\":", .{key});
        try jsonString(buf, allocator, v);
    } else {
        try buf.print(allocator, "\"{s}\":null", .{key});
    }
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

pub fn registerDefaultAgent(self: *Server) !void {
    try self.agents.put(try self.allocator.dupe(u8, "agent-0"), try self.allocator.dupe(u8, "default-secret-please-change"));
}