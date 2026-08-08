//! HTTP API server for franky-box — routes, auth, and handlers.

const std = @import("std");
const http = std.http;
const mem = std.mem;
const fmt = std.fmt;

const types = @import("types.zig");
const task_store = @import("store.zig");
const authn = @import("auth.zig");

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
    const path = req.head.target;
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

        return errJson(a, req, .not_found, "route not found");
    }

    if (segments.len >= 3 and isSeg(segments[0], "v1") and isSeg(segments[1], "results")) {
        if (method != .GET) return errJson(a, req, .method_not_allowed, "method not allowed");
        return self.handleGetResult(req, segments[2]);
    }

    return errJson(a, req, .not_found, "route not found");
}

fn handleRegisterAgent(self: *Server, req: *http.Server.Request, _: []const u8) !void {
    var buf: [32]u8 = undefined;
    self.io.random(&buf);
    const secret = try fmt.allocPrint(self.allocator, "{s}", .{fmt.bytesToHex(&buf, .lower)});

    const agent_id = try fmt.allocPrint(self.allocator, "agent-{d}", .{self.agents.count()});
    try self.agents.put(agent_id, try self.allocator.dupe(u8, secret));

    const resp = try fmt.allocPrint(self.allocator, "{{\"agent_id\":\"{s}\",\"agent_secret\":\"{s}\",\"team_id\":\"default\"}}", .{ agent_id, secret });
    defer self.allocator.free(resp);
    try json(req, .ok, resp);
}

fn handleDispatch(self: *Server, req: *http.Server.Request, body: []const u8) !void {
    const task_id = "task-0";
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
        const resp = try fmt.allocPrint(self.allocator, "{{\"task_id\":\"{s}\",\"action\":\"{s}\",\"payload\":{s},\"try_count\":{d}}}", .{ claimed.task_id, claimed.action, claimed.payload, claimed.try_count });
        defer self.allocator.free(resp);
        try json(req, .ok, resp);
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
        try buf.print(a, "{{\"task_id\":\"{s}\",\"action\":\"{s}\",\"output\":{s},\"completed_at\":\"{s}\"}}", .{ r.task_id, r.action, r.output, r.completed_at });
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

pub fn registerDefaultAgent(self: *Server) !void {
    try self.agents.put(try self.allocator.dupe(u8, "agent-0"), try self.allocator.dupe(u8, "default-secret-please-change"));
}
