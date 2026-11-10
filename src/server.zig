//! HTTP API server for franky-box — routes, auth, and handlers.

const std = @import("std");
const http = std.http;
const mem = std.mem;
const fmt = std.fmt;

const types = @import("types.zig");
const task_store = @import("store.zig");
const authn = @import("auth.zig");
const uuid = @import("uuid.zig");
const webhook = @import("webhook.zig");
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
/// P1: webhook deliveries are performed inline (synchronously) but never
/// block or fail the triggering request — delivery errors are logged only.
/// Each delivery is best-effort with a short connect timeout.
webhook_timeout_ms: u64 = 3000,

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

    // P2: advanced dispatch — priority, schedule, dependencies, idempotency.
    // POST /v1/tasks/dispatch-advanced (admin/producer; JSON body)
    if (segments.len == 3 and isSeg(segments[0], "v1") and isSeg(segments[1], "tasks") and isSeg(segments[2], "dispatch-advanced")) {
        if (method != .POST) return errJson(a, req, .method_not_allowed, "method not allowed");
        if (!requireAdmin(req)) return errJson(a, req, .unauthorized, "unauthorized");
        return self.handleDispatchAdvanced(req, body);
    }

    // P1: A2A-style Agent Card — the box's own card, listing registered agents.
    // GET /.well-known/agent-card.json
    if (segments.len == 2 and isSeg(segments[0], ".well-known") and isSeg(segments[1], "agent-card.json")) {
        if (method != .GET) return errJson(a, req, .method_not_allowed, "method not allowed");
        return self.handleWellKnownCard(req);
    }

    // P1: webhook subscription management (A2A push-notification config analog).
    // POST   /v1/webhooks            register (JSON: url, task_id?/agent_id?)
    // GET    /v1/webhooks            list (?task_id=?&agent_id=?)
    // DELETE /v1/webhooks/{sub_id}  delete
    if (segments.len == 2 and isSeg(segments[0], "v1") and isSeg(segments[1], "webhooks")) {
        if (method == .POST) {
            if (!requireAdmin(req)) return errJson(a, req, .unauthorized, "unauthorized");
            return self.handleAddWebhook(req, body);
        }
        if (method == .GET) {
            if (!requireAdmin(req)) return errJson(a, req, .unauthorized, "unauthorized");
            return self.handleListWebhooks(req);
        }
        return errJson(a, req, .method_not_allowed, "method not allowed");
    }
    if (segments.len == 3 and isSeg(segments[0], "v1") and isSeg(segments[1], "webhooks")) {
        if (method != .DELETE) return errJson(a, req, .method_not_allowed, "method not allowed");
        if (!requireAdmin(req)) return errJson(a, req, .unauthorized, "unauthorized");
        return self.handleDeleteWebhook(req, segments[2]);
    }

    if (segments.len >= 3 and isSeg(segments[0], "v1") and isSeg(segments[1], "agents")) {
        const agent = segments[2];

        if (segments.len >= 5 and isSeg(segments[3], "inbox") and isSeg(segments[4], "claim")) {
            if (method != .POST) return errJson(a, req, .method_not_allowed, "method not allowed");
            if (!self.requireAgent(agent, req)) return errJson(a, req, .unauthorized, "unauthorized");
            return self.handleClaim(req, agent);
        }

        // P0: lease heartbeat — extend the claim's visibility timeout.
        // POST /v1/agents/{id}/inbox/{task}/heartbeat  (optional ?extend=N seconds)
        if (segments.len >= 6 and isSeg(segments[3], "inbox") and isSeg(segments[5], "heartbeat")) {
            if (method != .POST) return errJson(a, req, .method_not_allowed, "method not allowed");
            if (!self.requireAgent(agent, req)) return errJson(a, req, .unauthorized, "unauthorized");
            return self.handleHeartbeat(req, agent, segments[4]);
        }

        // P2: human-in-the-loop — park the task and ask for input, or deliver it.
        // POST /v1/agents/{id}/inbox/{task}/input-required  (body: {"query": "..."})
        // POST /v1/agents/{id}/inbox/{task}/input           (body: raw input text)
        if (segments.len >= 6 and isSeg(segments[3], "inbox") and isSeg(segments[5], "input-required")) {
            if (method != .POST) return errJson(a, req, .method_not_allowed, "method not allowed");
            if (!self.requireAgent(agent, req)) return errJson(a, req, .unauthorized, "unauthorized");
            return self.handleRequestInput(req, agent, segments[4], body);
        }
        if (segments.len >= 6 and isSeg(segments[3], "inbox") and isSeg(segments[5], "input")) {
            if (method != .POST) return errJson(a, req, .method_not_allowed, "method not allowed");
            // Delivered input may come from the agent (its secret) OR the
            // producer/admin (admin token) — a human answering an agent's
            // question is usually not the agent itself.
            if (!self.requireAgent(agent, req) and !requireAdmin(req)) return errJson(a, req, .unauthorized, "unauthorized");
            return self.handleProvideInput(req, agent, segments[4], body);
        }

        // P1: cancel a task (producer/admin or the agent itself).
        // POST /v1/agents/{id}/inbox/{task}/cancel  (optional body: {"reason": "..."})
        if (segments.len >= 6 and isSeg(segments[3], "inbox") and isSeg(segments[5], "cancel")) {
            if (method != .POST) return errJson(a, req, .method_not_allowed, "method not allowed");
            if (!self.requireAgent(agent, req) and !requireAdmin(req)) return errJson(a, req, .unauthorized, "unauthorized");
            return self.handleCancel(req, agent, segments[4], body);
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

        // P1: GetTask — full task state by id (A2A tasks/get analog).
        // GET /v1/agents/{id}/tasks/{task_id}
        if (segments.len >= 5 and isSeg(segments[3], "tasks") and method == .GET) {
            if (!self.requireAgent(agent, req) and !requireAdmin(req)) return errJson(a, req, .unauthorized, "unauthorized");
            return self.handleGetTask(req, agent, segments[4]);
        }

        // P0/P1: per-agent card (A2A Agent Card analog) — public metadata for
        // this agent: name, skills, card_url. No auth: a card is discovery data.
        // GET /v1/agents/{id}/card
        if (segments.len == 4 and isSeg(segments[3], "card") and method == .GET) {
            return self.handleAgentCard(req, agent);
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

    // P1: fire-and-forget webhook push for terminal transitions.
    self.notifyWebhooks(agent_id, task_id, "completed");

    if (self.agents.get(agent_id)) |secret| {
        // P0 fix: generate with the REAL current time. The old code passed
        // now_seconds = 0, producing tokens that were expired at unix-3600 —
        // every grant issued before this fix was dead on arrival.
        const grant = authn.generateGrantToken(self.allocator, task_id, secret, 3600, self.nowEpochSeconds()) catch "{}";
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

    // P1: fire-and-forget webhook push for terminal transitions.
    self.notifyWebhooks(agent_id, task_id, "failed");

    const resp = try fmt.allocPrint(self.allocator, "{{\"task_id\":\"{s}\",\"status\":\"failed\"}}", .{task_id});
    defer self.allocator.free(resp);
    try json(req, .ok, resp);
}

// ── P0/P1/P2 handlers ─────────────────────────────────────────────────────

/// Current Unix epoch seconds — used for grant-token expiry math. Uses the
/// Io real-time clock threaded through the server (matches the Io instance
/// used everywhere else; deterministic under the testing Io).
fn nowEpochSeconds(self: *Server) i64 {
    const ts = std.Io.Clock.Timestamp.now(self.io, .real);
    return ts.raw.toSeconds();
}

/// P0: lease heartbeat. Extends the claim's visibility timeout so long-running
/// LLM tasks are not re-queued while still being worked on.
/// POST /v1/agents/{id}/inbox/{task}/heartbeat[?extend=300]
fn handleHeartbeat(self: *Server, req: *http.Server.Request, agent_id: []const u8, task_id: []const u8) !void {
    const a = self.allocator;
    // Optional ?extend=<seconds> (default 300, same as the claim lease).
    var extend: i64 = 300;
    const extend_owned = queryParamDup(a, req.head_buffer, "extend");
    defer if (extend_owned) |e| a.free(e);
    if (extend_owned) |e| {
        if (e.len > 0) {
            extend = std.fmt.parseInt(i64, e, 10) catch {
                return errJson(a, req, .bad_request, "invalid extend value");
            };
            if (extend < 0 or extend > 86400) {
                return errJson(a, req, .bad_request, "extend out of range (0..86400)");
            }
        }
    }
    const locked_until = self.store.heartbeat(a, "default-team", agent_id, task_id, extend) catch |err| {
        return errJson(a, req, .internal_server_error, @errorName(err));
    };
    if (locked_until) |lu| {
        defer a.free(lu);
        const resp = try fmt.allocPrint(a, "{{\"task_id\":\"{s}\",\"status\":\"working\",\"locked_until\":\"{s}\"}}", .{ task_id, lu });
        defer a.free(resp);
        try json(req, .ok, resp);
    } else {
        try json(req, .no_content, "{}");
    }
}

/// P1: cancel a task. Producer/admin or the agent itself. If the task is
/// unclaimed it finalizes immediately; if claimed, it is marked and finalized
/// on the next claim pass (complete/fail are fenced out by cancel_requested).
fn handleCancel(self: *Server, req: *http.Server.Request, agent_id: []const u8, task_id: []const u8, body: []const u8) !void {
    const a = self.allocator;
    // Optional JSON body {"reason": "..."} — tolerate empty or non-JSON.
    var reason: []const u8 = "canceled by request";
    var reason_owned: ?[]const u8 = null;
    defer if (reason_owned) |r| a.free(r);
    if (body.len > 0) {
        if (jsonStringField(a, body, "reason")) |r| {
            reason_owned = r;
            reason = r;
        }
    }
    const ok = self.store.cancel("default-team", agent_id, task_id, reason) catch |err| {
        return errJson(a, req, .internal_server_error, @errorName(err));
    };
    if (ok) {
        // Immediate cancel succeeded — the task is now terminal (we set output).
        // Emit the terminal webhook + 200 "canceled".
        self.notifyWebhooks(agent_id, task_id, "canceled");
        const resp = try fmt.allocPrint(a, "{{\"task_id\":\"{s}\",\"status\":\"canceled\"}}", .{task_id});
        defer a.free(resp);
        try json(req, .ok, resp);
    } else {
        // `ok=false`: either deferred-mark (task exists, output NULL → 202)
        // or already-terminal/unknown (cancel failed → 404). Distinguish by task state.
        const task_opt = self.store.getTask(a, "default-team", agent_id, task_id) catch null;
        const already_terminal = if (task_opt) |t| (t.output != null) else false;
        if (task_opt) |t| t.deinit(a);
        if (already_terminal) {
            return errJson(a, req, .not_found, "task not found or already terminal");
        }
        const resp = try fmt.allocPrint(a, "{{\"task_id\":\"{s}\",\"status\":\"cancel-pending\"}}", .{task_id});
        defer a.free(resp);
        try json(req, .accepted, resp);
    }
}

/// P1: GetTask — full task state by id (A2A tasks/get analog). Includes
/// the effective A2A-style state name for interop readability.
fn handleGetTask(self: *Server, req: *http.Server.Request, agent_id: []const u8, task_id: []const u8) !void {
    const a = self.allocator;
    const task = self.store.getTask(a, "default-team", agent_id, task_id) catch |err| {
        return errJson(a, req, .internal_server_error, @errorName(err));
    };
    if (task == null) return errJson(a, req, .not_found, "task not found");
    const t = task.?;
    defer t.deinit(a);

    // Derive the A2A-style state name from nullability (the storage model).
    const state = taskStateOf(t);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.print(a, "{{\"task_id\":\"{s}\",\"agent_id\":\"{s}\",\"action\":\"{s}\",\"state\":\"{s}\",\"try_count\":{d},\"payload\":", .{ t.task_id, t.agent_id, t.action, state, t.try_count });
    try jsonPayload(&buf, a, t.payload);
    try buf.appendSlice(a, ",\"output\":");
    if (t.output) |o| try jsonPayload(&buf, a, o) else try buf.appendSlice(a, "null");
    try buf.appendSlice(a, ",");
    try emitOptField(&buf, a, "locked_until", t.locked_until);
    try buf.appendSlice(a, ",");
    try emitOptField(&buf, a, "completed_at", t.completed_at);
    try buf.appendSlice(a, ",");
    try emitOptField(&buf, a, "workstream_id", t.workstream_id);
    // P2 fields (now exposed via types.Task).
    try buf.appendSlice(a, ",");
    try emitOptField(&buf, a, "available_at", t.available_at);
    try buf.appendSlice(a, ",");
    try emitOptField(&buf, a, "blocked_by", t.blocked_by);
    try buf.appendSlice(a, ",");
    try emitOptField(&buf, a, "idempotency_key", t.idempotency_key);
    try buf.appendSlice(a, ",");
    try emitOptField(&buf, a, "pending_input", t.pending_input);
    try buf.print(a, ",\"priority\":{d},\"cancel_requested\":{s}", .{ t.priority, if (t.cancel_requested) "true" else "false" });
    try buf.appendSlice(a, "}");
    try json(req, .ok, buf.items);
}

/// Map the storage nullability model onto the A2A TASK_STATE_* vocabulary.
fn taskStateOf(t: types.Task) []const u8 {
    if (t.output) |o| {
        // Robust state detection (was: substring match on output, which
        // misclassified a completed result containing the word "error"/
        // "canceled"). Use the structured markers we now write:
        //   - cancel_requested flag set by cancel() → canceled (terminal).
        //   - fail() output starting with {"error": → failed (terminal).
        //   - anything else with output → completed.
        // A completed result that happens to contain "error" as a substring
        // is NOT misclassified (startsWith, not indexOf).
        if (t.cancel_requested) return "canceled";
        if (std.mem.startsWith(u8, o, "{\"error\":")) return "failed";
        return "completed";
    }
    if (t.pending_input != null) return "input-required";
    if (t.locked_until != null) return "working";
    return "submitted";
}

/// P2: human-in-the-loop. The agent parks the task and asks a question.
/// POST /v1/agents/{id}/inbox/{task}/input-required  (body: {"query": "..."})
fn handleRequestInput(self: *Server, req: *http.Server.Request, agent_id: []const u8, task_id: []const u8, body: []const u8) !void {
    const a = self.allocator;
    var query: []const u8 = "input required";
    var query_owned: ?[]const u8 = null;
    defer if (query_owned) |q| a.free(q);
    if (jsonStringField(a, body, "query")) |q| {
        query_owned = q;
        query = q;
    }
    const ok = self.store.requestInput("default-team", agent_id, task_id, query) catch |err| {
        return errJson(a, req, .internal_server_error, @errorName(err));
    };
    if (!ok) return errJson(a, req, .not_found, "task not found or already parked/terminal");
    const resp = try fmt.allocPrint(a, "{{\"task_id\":\"{s}\",\"status\":\"input-required\"}}", .{task_id});
    defer a.free(resp);
    try json(req, .ok, resp);
}

/// P2: human-in-the-loop. The producer/admin (or agent) answers a parked task.
/// POST /v1/agents/{id}/inbox/{task}/input  (body: raw input text, or {"input": "..."})
fn handleProvideInput(self: *Server, req: *http.Server.Request, agent_id: []const u8, task_id: []const u8, body: []const u8) !void {
    const a = self.allocator;
    if (body.len == 0) return errJson(a, req, .bad_request, "empty input");
    // Accept either raw text or a JSON {"input": "..."} wrapper.
    var input: []const u8 = body;
    var input_owned: ?[]const u8 = null;
    defer if (input_owned) |i| a.free(i);
    if (jsonStringField(a, body, "input")) |i| {
        input_owned = i;
        input = i;
    }
    const delivered = self.store.provideInput(a, "default-team", agent_id, task_id, input) catch |err| {
        return errJson(a, req, .internal_server_error, @errorName(err));
    };
    if (delivered == null) return errJson(a, req, .not_found, "task not parked awaiting input");
    a.free(delivered.?); // the echo is not used in the response — free immediately
    const resp = try fmt.allocPrint(a, "{{\"task_id\":\"{s}\",\"status\":\"working\",\"input_delivered\":true}}", .{task_id});
    defer a.free(resp);
    try json(req, .ok, resp);
}

/// P0: persisted agent registration. Accepts the legacy empty body (server
/// generates agent-N + secret) or a JSON body carrying metadata:
/// {"agent_id": "billing", "secret": "...", "name": "Billing Agent",
///  "skills": ["invoices", "pdf"], "card_url": "https://..."}
/// On restart the in-memory map is repopulated from the agents table
/// (loadAgents in main); the map remains the hot auth cache.
fn handleRegisterAgent(self: *Server, req: *http.Server.Request, body: []const u8) !void {
    const a = self.allocator;
    var agent_id: []const u8 = undefined;
    var secret: []const u8 = undefined;
    var owned_agent_id: ?[]const u8 = null;
    var owned_secret: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var skills_json: ?[]const u8 = null;
    var card_url: ?[]const u8 = null;
    defer {
        if (owned_agent_id) |x| a.free(x);
        if (owned_secret) |x| a.free(x);
        if (name) |x| a.free(x);
        if (skills_json) |x| a.free(x);
        if (card_url) |x| a.free(x);
    }

    if (body.len > 0) {
        // JSON registration: agent_id + secret are required when a body is sent.
        owned_agent_id = jsonStringField(a, body, "agent_id") orelse
            return errJson(a, req, .bad_request, "missing agent_id");
        agent_id = owned_agent_id.?;
        owned_secret = jsonStringField(a, body, "secret") orelse
            return errJson(a, req, .bad_request, "missing secret");
        secret = owned_secret.?;
        if (agent_id.len == 0 or agent_id.len > 256) return errJson(a, req, .bad_request, "agent_id must be 1..256 chars");
        if (secret.len < 16) return errJson(a, req, .bad_request, "secret must be at least 16 chars");
        name = jsonStringField(a, body, "name");
        if (jsonRawField(a, body, "skills")) |s| skills_json = s;
        card_url = jsonStringField(a, body, "card_url");
    } else {
        // Legacy anonymous registration (v0 behavior): server-generated ids.
        var buf: [32]u8 = undefined;
        self.io.random(&buf);
        owned_secret = try fmt.allocPrint(a, "{s}", .{fmt.bytesToHex(&buf, .lower)});
        secret = owned_secret.?;
        owned_agent_id = try fmt.allocPrint(a, "agent-{d}", .{self.agents.count()});
        agent_id = owned_agent_id.?;
    }

    // Persist (P0) + keep the in-memory hot cache in sync.
    self.store.upsertAgent(agent_id, secret, name, skills_json, card_url) catch |err| {
        return errJson(a, req, .internal_server_error, @errorName(err));
    };
    const dup = try a.dupe(u8, secret);
    const gop = try self.agents.getOrPut(agent_id);
    if (gop.found_existing) {
        a.free(dup); // the new key is the same as the existing key; free the redundant dup
        a.free(gop.value_ptr.*); // free the OLD secret
        gop.value_ptr.* = try a.dupe(u8, secret); // store a fresh copy
    } else {
        gop.key_ptr.* = try a.dupe(u8, agent_id);
        gop.value_ptr.* = dup; // the map takes ownership of dup on the insert path
    }

    const resp = try fmt.allocPrint(a, "{{\"agent_id\":\"{s}\",\"agent_secret\":\"{s}\",\"team_id\":\"default\"}}", .{ agent_id, secret });
    defer a.free(resp);
    try json(req, .ok, resp);
}

/// P2: advanced dispatch. JSON body (all optional except agent_id):
/// {"agent_id": "agent-0", "action": "process", "payload": {…},
///  "workstream_id": "w_…", "workstream_name": "…",
///  "priority": 10, "available_at": "2026-01-01 09:00:00",
///  "blocked_by": ["t_…", "t_…"], "idempotency_key": "key-1"}
fn handleDispatchAdvanced(self: *Server, req: *http.Server.Request, body: []const u8) !void {
    const a = self.allocator;
    if (body.len == 0) return errJson(a, req, .bad_request, "empty body");
    const agent_id = jsonStringField(a, body, "agent_id") orelse
        return errJson(a, req, .bad_request, "missing agent_id");
    defer a.free(agent_id);
    if (!self.agents.contains(agent_id)) return errJson(a, req, .bad_request, "unknown agent");

    var opts: types.DispatchOptions = .{};
    var owned: struct {
        action: ?[]const u8 = null,
        payload: ?[]const u8 = null,
        available_at: ?[]const u8 = null,
        idempotency_key: ?[]const u8 = null,
        workstream_id: ?[]const u8 = null,
        workstream_name: ?[]const u8 = null,
        blocked: ?[]const []const u8 = null,
        blocked_buf: ?[]const u8 = null,
    } = .{};
    defer {
        if (owned.action) |x| a.free(x);
        if (owned.payload) |x| a.free(x);
        if (owned.available_at) |x| a.free(x);
        if (owned.idempotency_key) |x| a.free(x);
        if (owned.workstream_id) |x| a.free(x);
        if (owned.workstream_name) |x| a.free(x);
        // blocked: the items slice AND each item string are separately
        // allocated by jsonStringArrayField — free the items first, then the
        // slice, then the raw backing buffer.
        if (owned.blocked) |items| {
            for (items) |item| a.free(item);
            a.free(items);
        }
        if (owned.blocked_buf) |x| a.free(x);
    }

    owned.action = jsonStringField(a, body, "action");
    if (jsonRawField(a, body, "payload")) |p| owned.payload = p;
    if (jsonStringField(a, body, "available_at")) |at| {
        owned.available_at = at;
        opts.available_at = at;
    }
    if (jsonStringField(a, body, "idempotency_key")) |k| {
        owned.idempotency_key = k;
        opts.idempotency_key = k;
    }
    if (jsonStringField(a, body, "workstream_id")) |w| {
        owned.workstream_id = w;
        // Validate it exists (same rule as the admin form).
        const found = self.store.lookupWorkstreamById(a, w) catch null;
        if (found == null) return errJson(a, req, .bad_request, "workstream_id not found");
        if (found) |f| a.free(f);
    }
    if (jsonStringField(a, body, "workstream_name")) |wname| {
        // Name mode: join if exists, else create.
        owned.workstream_name = wname;
        const found = self.store.lookupWorkstreamByName(a, wname) catch null;
        if (found) |f| {
            // `f` is caller-owned; keep it (do NOT free before storing).
            owned.workstream_id = f;
        } else {
            const new_ws = try uuid.newWorkstreamId(self.io, a);
            self.store.createWorkstream(new_ws, wname) catch |err| {
                a.free(new_ws);
                if (err == error.DuplicateWorkstreamName) return errJson(a, req, .conflict, "workstream name already exists");
                return errJson(a, req, .internal_server_error, @errorName(err));
            };
            owned.workstream_id = new_ws;
        }
    }
    // priority: integer or absent.
    if (jsonIntField(a, body, "priority")) |p| {
        if (p < -1000 or p > 1000) return errJson(a, req, .bad_request, "priority out of range (-1000..1000)");
        opts.priority = @intCast(p);
    }
    // blocked_by: array of task ids (JSON array of strings).
    if (jsonStringArrayField(a, body, "blocked_by")) |arr| {
        owned.blocked = arr.items;
        owned.blocked_buf = arr.backing;
        opts.blocked_by = arr.items;
    }

    const task_id = try uuid.newTaskId(self.io, a);
    defer a.free(task_id);
    const ws_for_dispatch: ?[]const u8 = owned.workstream_id orelse blk: {
        // Neither workstream_id nor name → fresh anonymous workstream.
        const new_ws = try uuid.newWorkstreamId(self.io, a);
        owned.workstream_id = new_ws;
        break :blk new_ws;
    };

    const effective_id = self.store.dispatchAdvanced(a, "default-team", agent_id, task_id, owned.action orelse "process", owned.payload orelse "{}", ws_for_dispatch, opts) catch |err| {
        return errJson(a, req, .internal_server_error, @errorName(err));
    };
    defer a.free(effective_id);

    const idempotent = !std.mem.eql(u8, effective_id, task_id);
    // On an idempotent hit, report the ORIGINAL task's workstream (the fresh
    // workstream generated above was discarded by the store).
    const ws_out = blk: {
        if (idempotent) {
            const existing = self.store.getTask(a, "default-team", agent_id, effective_id) catch null;
            if (existing) |t| {
                defer t.deinit(a);
                if (t.workstream_id) |w| break :blk try a.dupe(u8, w);
            }
        }
        break :blk try a.dupe(u8, owned.workstream_id orelse "");
    };
    defer a.free(ws_out);
    const resp = try fmt.allocPrint(a, "{{\"task_id\":\"{s}\",\"workstream_id\":\"{s}\",\"status\":\"dispatched\",\"idempotent\":{s}\"}}", .{ effective_id, ws_out, if (idempotent) "true" else "false" });
    defer a.free(resp);
    try json(req, .ok, resp);
}

/// P1: per-agent card — A2A Agent Card analog for one agent.
fn handleAgentCard(self: *Server, req: *http.Server.Request, agent_id: []const u8) !void {
    const a = self.allocator;
    // Read from the persisted registry (skills/name/card_url live there).
    const agents = self.store.listAgents(a) catch |err| {
        return errJson(a, req, .internal_server_error, @errorName(err));
    };
    defer {
        for (agents) |ag| ag.deinit(a);
        a.free(agents);
    }
    for (agents) |ag| {
        if (std.mem.eql(u8, ag.agent_id, agent_id)) {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(a);
            try buf.print(a, "{{\"agent_id\":\"{s}\",\"name\":", .{agent_id});
            if (ag.name) |n| try jsonPayload(&buf, a, n) else try buf.appendSlice(a, "null");
            try buf.appendSlice(a, ",\"skills\":");
            if (ag.skills) |s| try buf.appendSlice(a, s) else try buf.appendSlice(a, "[]");
            try buf.appendSlice(a, ",\"card_url\":");
            if (ag.card_url) |c| try jsonPayload(&buf, a, c) else try buf.appendSlice(a, "null");
            try buf.print(a, ",\"created_at\":\"{s}\"}}", .{ag.created_at});
            try json(req, .ok, buf.items);
            return;
        }
    }
    return errJson(a, req, .not_found, "agent not found");
}

/// P1: the box's own well-known card — describes the service and lists agents.
fn handleWellKnownCard(self: *Server, req: *http.Server.Request) !void {
    const a = self.allocator;
    const agents = self.store.listAgents(a) catch |err| {
        return errJson(a, req, .internal_server_error, @errorName(err));
    };
    defer {
        for (agents) |ag| ag.deinit(a);
        a.free(agents);
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "{\"name\":\"franky-box\",\"description\":\"SQLite-backed task inbox/outbox queue for LLM agents\",\"version\":\"");
    try buf.appendSlice(a, build_options.version);
    try buf.appendSlice(a, "\",\"agents\":[");
    for (agents, 0..) |ag, i| {
        if (i > 0) try buf.appendSlice(a, ",");
        try jsonPayload(&buf, a, ag.agent_id);
    }
    try buf.appendSlice(a, "]}");
    try json(req, .ok, buf.items);
}

// ── Webhook subscription handlers (P1) ────────────────────────────────────

fn handleAddWebhook(self: *Server, req: *http.Server.Request, body: []const u8) !void {
    const a = self.allocator;
    const url = jsonStringField(a, body, "url") orelse
        return errJson(a, req, .bad_request, "missing url");
    defer a.free(url);
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) {
        return errJson(a, req, .bad_request, "url must be http(s)");
    }
    const task_id = jsonStringField(a, body, "task_id");
    defer if (task_id) |t| a.free(t);
    const agent_id = jsonStringField(a, body, "agent_id");
    defer if (agent_id) |g| a.free(g);
    if (task_id == null and agent_id == null) {
        return errJson(a, req, .bad_request, "task_id or agent_id required");
    }
    // Optional secret: caller-supplied signing secret. When absent, generate.
    var secret = jsonStringField(a, body, "secret");
    defer if (secret) |s| a.free(s);
    if (secret == null) {
        var buf: [32]u8 = undefined;
        self.io.random(&buf);
        secret = try fmt.allocPrint(a, "{s}", .{fmt.bytesToHex(&buf, .lower)});
    }
    const sub_id = try uuid.newPrefixed(self.io, a, "wh_");
    defer a.free(sub_id);
    self.store.addWebhook(sub_id, url, secret.?, task_id, agent_id) catch |err| {
        return errJson(a, req, .internal_server_error, @errorName(err));
    };
    const resp = try fmt.allocPrint(a, "{{\"subscription_id\":\"{s}\",\"secret\":\"{s}\"}}", .{ sub_id, secret.? });
    defer a.free(resp);
    try json(req, .ok, resp);
}

fn handleListWebhooks(self: *Server, req: *http.Server.Request) !void {
    const a = self.allocator;
    const task_id = queryParamDup(a, req.head_buffer, "task_id");
    defer if (task_id) |t| a.free(t);
    const agent_id = queryParamDup(a, req.head_buffer, "agent_id");
    defer if (agent_id) |g| a.free(g);
    const subs = self.store.listWebhooks(a, task_id, agent_id) catch |err| {
        return errJson(a, req, .internal_server_error, @errorName(err));
    };
    defer {
        for (subs) |s| s.deinit(a);
        a.free(subs);
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "[");
    for (subs, 0..) |s, i| {
        if (i > 0) try buf.appendSlice(a, ",");
        try buf.print(a, "{{\"subscription_id\":\"{s}\",\"url\":\"{s}\",\"task_id\":", .{ s.subscription_id, s.url });
        if (s.task_id) |t| try jsonPayload(&buf, a, t) else try buf.appendSlice(a, "null");
        try buf.appendSlice(a, ",\"agent_id\":");
        if (s.agent_id) |g| try jsonPayload(&buf, a, g) else try buf.appendSlice(a, "null");
        try buf.print(a, ",\"created_at\":\"{s}\"}}", .{s.created_at});
    }
    try buf.appendSlice(a, "]");
    try json(req, .ok, buf.items);
}

fn handleDeleteWebhook(self: *Server, req: *http.Server.Request, sub_id: []const u8) !void {
    const a = self.allocator;
    const ok = self.store.deleteWebhook(sub_id) catch |err| {
        return errJson(a, req, .internal_server_error, @errorName(err));
    };
    if (!ok) return errJson(a, req, .not_found, "subscription not found");
    const resp = try fmt.allocPrint(a, "{{\"subscription_id\":\"{s}\",\"deleted\":true}}", .{sub_id});
    defer a.free(resp);
    try json(req, .ok, resp);
}

/// P0: grant-token verification closes the /v1/results stub. The task's
/// agent secret is the HMAC key; only a valid, unexpired token for THIS
/// task returns the result.
fn handleGetResult(self: *Server, req: *http.Server.Request, task_id: []const u8) !void {
    const a = self.allocator;
    const token = queryParamDup(a, req.head_buffer, "token") orelse
        return errJson(a, req, .bad_request, "missing token");
    defer a.free(token);
    if (token.len == 0) return errJson(a, req, .bad_request, "missing token");

    // Find which agent owns the task (the token is bound to the agent secret).
    // Scan registered agents — /v1/results is a cross-agent endpoint.
    const agents = self.store.listAgents(a) catch |err| {
        return errJson(a, req, .internal_server_error, @errorName(err));
    };
    defer {
        for (agents) |ag| ag.deinit(a);
        a.free(agents);
    }

    for (agents) |ag| {
        // Quick reject: token must verify against THIS agent's secret + task.
        const valid = authn.verifyGrantTokenFor(a, token, task_id, ag.secret, self.nowEpochSeconds()) catch false;
        if (!valid) continue;
        // Verified — return the task's output.
        const task = self.store.getTask(a, "default-team", ag.agent_id, task_id) catch |err| {
            return errJson(a, req, .internal_server_error, @errorName(err));
        };
        if (task == null) continue; // token valid but task in another tenant — keep scanning
        const t = task.?;
        defer t.deinit(a);
        if (t.output == null) {
            return errJson(a, req, .not_found, "task not completed yet");
        }
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a);
        try buf.print(a, "{{\"task_id\":\"{s}\",\"output\":", .{task_id});
        try jsonPayload(&buf, a, t.output.?);
        try buf.appendSlice(a, "}");
        try json(req, .ok, buf.items);
        return;
    }
    return errJson(a, req, .unauthorized, "invalid or expired token");
}

/// JSON helpers for the handlers above — lightweight extraction without a
/// full parse (std.json.Value over an arena would be fine too; these keep
/// allocations explicit and minimal).

/// Extract a top-level string field from a JSON object body. Caller owns the
/// returned slice. Returns null when the field is absent (or not a string).
fn jsonStringField(a: std.mem.Allocator, body: []const u8, key: []const u8) ?[]const u8 {
    // Find "key": then a string value. Minimal JSON: whitespace tolerant.
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] != '"') continue;
        // Candidate key start; match the key exactly.
        if (i + key.len + 1 > body.len) return null;
        if (!std.mem.eql(u8, body[i + 1 .. i + 1 + key.len], key)) continue;
        if (body[i + 1 + key.len] != '"') continue;
        // Key matched — find the colon after it.
        var j = i + key.len + 2;
        while (j < body.len and body[j] != ':') : (j += 1) {}
        if (j >= body.len) return null;
        j += 1;
        while (j < body.len and (body[j] == ' ' or body[j] == '\t' or body[j] == '\n' or body[j] == '\r')) : (j += 1) {}
        if (j >= body.len or body[j] != '"') return null; // not a string value
        // Parse the string with escapes into owned memory.
        j += 1;
        var out: std.ArrayList(u8) = .empty;
        while (j < body.len) {
            const c = body[j];
            if (c == '"') return out.toOwnedSlice(a) catch null;
            if (c == '\\' and j + 1 < body.len) {
                j += 1;
                switch (body[j]) {
                    'n' => out.append(a, '\n') catch return null,
                    't' => out.append(a, '\t') catch return null,
                    'r' => out.append(a, '\r') catch return null,
                    'b' => out.append(a, 8) catch return null,
                    'f' => out.append(a, 12) catch return null,
                    'u' => {
                        if (j + 4 >= body.len) return null;
                        const cp = std.fmt.parseInt(u21, body[j + 1 .. j + 5], 16) catch return null;
                        var utf8_buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &utf8_buf) catch return null;
                        out.appendSlice(a, utf8_buf[0..n]) catch return null;
                        j += 4;
                    },
                    else => out.append(a, body[j]) catch return null,
                }
            } else {
                out.append(a, c) catch return null;
            }
            j += 1;
        }
        return null;
    }
    return null;
}

/// Extract a top-level field's RAW JSON value (trimmed) — for values that are
/// objects/arrays (payload, skills) that must be stored verbatim.
fn jsonRawField(a: std.mem.Allocator, body: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] != '"') continue;
        if (i + key.len + 1 > body.len) return null;
        if (!std.mem.eql(u8, body[i + 1 .. i + 1 + key.len], key)) continue;
        if (body[i + 1 + key.len] != '"') continue;
        var j = i + key.len + 2;
        while (j < body.len and body[j] != ':') : (j += 1) {}
        if (j >= body.len) return null;
        j += 1;
        while (j < body.len and (body[j] == ' ' or body[j] == '\t' or body[j] == '\n' or body[j] == '\r')) : (j += 1) {}
        if (j >= body.len) return null;
        // Find the end of the raw value: for objects/arrays, match braces;
        // for scalars, up to comma/}/end.
        const start = j;
        if (body[j] == '{' or body[j] == '[') {
            const open = body[j];
            const close: u8 = if (open == '{') '}' else ']';
            var depth: usize = 0;
            var in_str = false;
            while (j < body.len) : (j += 1) {
                const c = body[j];
                if (in_str) {
                    if (c == '\\') j += 1 else if (c == '"') in_str = false;
                    continue;
                }
                if (c == '"') in_str = true;
                if (c == open) depth += 1;
                if (c == close) {
                    depth -= 1;
                    if (depth == 0) {
                        return a.dupe(u8, body[start .. j + 1]) catch null;
                    }
                }
            }
            return null;
        }
        // Scalar: up to a comma or closing brace at depth 0 (no strings here).
        while (j < body.len and body[j] != ',' and body[j] != '}') : (j += 1) {}
        return a.dupe(u8, body[start..j]) catch null;
    }
    return null;
}

/// Extract a top-level integer field. Returns null when absent/non-integer.
fn jsonIntField(a: std.mem.Allocator, body: []const u8, key: []const u8) ?i64 {
    const raw = jsonRawField(a, body, key) orelse return null;
    defer a.free(raw);
    return std.fmt.parseInt(i64, std.mem.trim(u8, raw, " \t\n\r"), 10) catch null;
}

/// A parsed string-array field (for blocked_by): items point into `backing`.
const JsonStringArray = struct {
    items: []const []const u8,
    backing: []const u8,
};

/// Extract a top-level array-of-strings field. Caller frees `backing` and
/// `items` (items slice first, then backing). Returns null when absent/malformed.
fn jsonStringArrayField(a: std.mem.Allocator, body: []const u8, key: []const u8) ?JsonStringArray {
    const raw = jsonRawField(a, body, key) orelse return null;
    errdefer a.free(raw);
    if (raw.len < 2 or raw[0] != '[') {
        a.free(raw);
        return null;
    }
    var items: std.ArrayList([]const u8) = .empty;
    // On any failure after items were allocated, free them all before
    // returning null (errdefer alone doesn't cover per-item slices).
    errdefer {
        for (items.items) |it| a.free(it);
        items.deinit(a);
    }
    var i: usize = 1;
    while (i < raw.len) {
        while (i < raw.len and (raw[i] == ' ' or raw[i] == ',')) : (i += 1) {}
        if (i >= raw.len or raw[i] == ']') break;
        if (raw[i] != '"') return null;
        i += 1;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        while (i < raw.len and raw[i] != '"') {
            if (raw[i] == '\\' and i + 1 < raw.len) {
                i += 1;
                out.append(a, raw[i]) catch return null;
            } else {
                out.append(a, raw[i]) catch return null;
            }
            i += 1;
        }
        if (i >= raw.len) return null; // unterminated string
        i += 1;
        const owned = out.toOwnedSlice(a) catch return null;
        items.append(a, owned) catch {
            a.free(owned);
            return null;
        };
    }
    const items_slice = items.toOwnedSlice(a) catch return null; // items moved into the slice
    errdefer a.free(items_slice);
    return .{ .items = items_slice, .backing = raw };
}

/// Deliver webhooks for a terminal task transition (fire-and-forget).
fn notifyWebhooks(self: *Server, agent_id: []const u8, task_id: []const u8, event: []const u8) void {
    webhook.notify(self.allocator, self.io, self.store, agent_id, task_id, event, self.webhook_timeout_ms);
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
    // P0: list from the persisted registry (the source of truth), so the
    // fragment shows name/skills/created_at and survives restarts.
    const agents = self.store.listAgents(a) catch |err| {
        return htmlError(a, req, .internal_server_error, @errorName(err));
    };
    defer {
        for (agents) |ag| ag.deinit(a);
        a.free(agents);
    }
    if (agents.len == 0) {
        try buf.appendSlice(a, "<p>No agents registered.</p>");
    } else {
        try buf.appendSlice(a, "<table class=\"resp-table\" id=\"agents-table\"><thead><tr><th>Agent ID</th><th>Name</th><th>Skills</th><th>Secret</th><th>Created</th></tr></thead><tbody>");
        for (agents) |ag| {
            try buf.appendSlice(a, "<tr><td data-label=\"Agent ID\">");
            try htmlEscape(&buf, a, ag.agent_id);
            try buf.appendSlice(a, "</td><td data-label=\"Name\">");
            if (ag.name) |n| try htmlEscape(&buf, a, n) else try buf.appendSlice(a, "—");
            try buf.appendSlice(a, "</td><td data-label=\"Skills\">");
            if (ag.skills) |s| {
                try buf.appendSlice(a, "<code>");
                try htmlEscape(&buf, a, s);
                try buf.appendSlice(a, "</code>");
            } else try buf.appendSlice(a, "—");
            try buf.appendSlice(a, "</td><td data-label=\"Secret\"><code>");
            try htmlEscape(&buf, a, ag.secret);
            try buf.appendSlice(a, "</code></td><td data-label=\"Created\">");
            try htmlEscape(&buf, a, ag.created_at);
            try buf.appendSlice(a, "</td></tr>");
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
    // P0: persist the default agent too, so a fresh DB and an old DB behave
    // the same way (the in-memory map is rebuilt from the store on startup).
    self.store.upsertAgent("agent-0", "default-secret-please-change", "Default Agent", null, null) catch |err| {
        std.log.warn("registerDefaultAgent: persist failed: {s}", .{@errorName(err)});
    };
    const gop = try self.agents.getOrPut("agent-0");
    if (gop.found_existing) {
        // Key exists — free the old secret and store a fresh copy. The key
        // string itself is a literal and not owned by the map, so no key free.
        self.allocator.free(gop.value_ptr.*);
        gop.value_ptr.* = try self.allocator.dupe(u8, "default-secret-please-change");
    } else {
        // Insert path: the map owns both the key and the value from now on.
        gop.key_ptr.* = try self.allocator.dupe(u8, "agent-0");
        gop.value_ptr.* = try self.allocator.dupe(u8, "default-secret-please-change");
    }
}

/// P0: repopulate the in-memory auth cache from the persisted agents table.
/// Called once at startup after the store is ready, before serving. Idempotent:
/// existing map entries are replaced (the store is the source of truth).
pub fn loadAgents(self: *Server) !void {
    const records = self.store.listAgents(self.allocator) catch |err| {
        std.log.warn("loadAgents: {s}", .{@errorName(err)});
        return;
    };
    defer {
        for (records) |r| r.deinit(self.allocator);
        self.allocator.free(records);
    }
    for (records) |r| {
        const gop = try self.agents.getOrPut(r.agent_id);
        if (gop.found_existing) {
            // Key collision (shouldn't happen for persisted ids, but be correct):
            // free the old secret, store a fresh copy. The key is already owned
            // by the map, so the `r.agent_id` slice (owned by the record) is the
            // canonical key — no key dup/free needed here.
            self.allocator.free(gop.value_ptr.*);
            gop.value_ptr.* = try self.allocator.dupe(u8, r.secret);
        } else {
            // Insert path: the map takes ownership of both the key and value.
            gop.key_ptr.* = try self.allocator.dupe(u8, r.agent_id);
            gop.value_ptr.* = try self.allocator.dupe(u8, r.secret);
        }
    }
}