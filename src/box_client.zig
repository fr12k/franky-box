//! Box client — HTTP client for the franky-box remote task queue.
//!
//! Thin wrapper around `std.http.Client` exposing all public API endpoints:
//! register, dispatch, claim, complete, fail, readOutbox, getResult.

const std = @import("std");
const http = std.http;

const box_types = @import("box_types.zig");

allocator: std.mem.Allocator,
io: std.Io,
client: http.Client,
base_url: []const u8,
agent_id: []const u8,
agent_secret: []const u8,
team_id: []const u8,
/// Pre-allocated auth header value: "Bearer <secret>"
auth_value: []const u8,
/// Reusable extra-headers slice pointing at `auth_value`.
headers: [1]http.Header,

pub const BoxClient = @This();

pub const InitOptions = struct {
    base_url: []const u8,
    agent_id: []const u8,
    agent_secret: []const u8,
    team_id: []const u8,
};

pub fn init(allocator: std.mem.Allocator, io: std.Io, opts: InitOptions) !BoxClient {
    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{opts.agent_secret});
    return .{
        .allocator = allocator,
        .io = io,
        .client = .{ .allocator = allocator, .io = io },
        .base_url = opts.base_url,
        .agent_id = opts.agent_id,
        .agent_secret = opts.agent_secret,
        .team_id = opts.team_id,
        .auth_value = auth_value,
        .headers = .{.{ .name = "authorization", .value = auth_value }},
    };
}

pub fn deinit(self: *BoxClient) void {
    self.allocator.free(self.auth_value);
    self.client.deinit();
}

// ── URL helpers ──────────────────────────────────────────────

fn registerUrl(self: *BoxClient, allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/v1/agents", .{self.base_url});
}

fn dispatchUrl(self: *BoxClient, allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/v1/tasks/dispatch", .{self.base_url});
}

fn claimUrl(self: *BoxClient, allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/v1/agents/{s}/inbox/claim", .{ self.base_url, self.agent_id });
}

fn readOutboxUrl(self: *BoxClient, allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/v1/agents/{s}/outbox", .{ self.base_url, self.agent_id });
}

fn completeUrl(self: *BoxClient, allocator: std.mem.Allocator, task_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/v1/agents/{s}/outbox/{s}/complete", .{ self.base_url, self.agent_id, task_id });
}

fn failUrl(self: *BoxClient, allocator: std.mem.Allocator, task_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/v1/agents/{s}/outbox/{s}/fail", .{ self.base_url, self.agent_id, task_id });
}

fn resultUrl(self: *BoxClient, allocator: std.mem.Allocator, task_id: []const u8, token: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/v1/results/{s}?token={s}", .{ self.base_url, task_id, token });
}

// ── Public API ──────────────────────────────────────────────

/// Register the agent with the box server.
/// On success, returns the server response body (JSON with agent_id/agent_secret/team_id).
pub fn register(self: *BoxClient) ![]const u8 {
    const url = try registerUrl(self, self.allocator);
    defer self.allocator.free(url);

    var body_writer = std.Io.Writer.Allocating.init(self.allocator);
    defer body_writer.deinit();

    const result = self.client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = "",
        .response_writer = &body_writer.writer,
        .extra_headers = &self.headers,
    }) catch |err| {
        std.log.warn("box_client: register request failed: {}", .{err});
        return error.RequestFailed;
    };

    if (result.status != .ok) return error.RequestFailed;
    return body_writer.writer.buffered();
}

/// Dispatch a task (admin endpoint).
/// Returns the response body JSON.
pub fn dispatch(self: *BoxClient, action: []const u8, payload: []const u8) ![]const u8 {
    const url = try dispatchUrl(self, self.allocator);
    defer self.allocator.free(url);

    var body_writer = std.Io.Writer.Allocating.init(self.allocator);
    defer body_writer.deinit();

    const body = try std.fmt.allocPrint(self.allocator, "{{\"action\":\"{s}\",\"payload\":{s}}}", .{ action, payload });
    defer self.allocator.free(body);

    const content_type_header: http.Header = .{ .name = "content-type", .value = "application/json" };
    const all_headers = [_]http.Header{ self.headers[0], content_type_header };

    const result = self.client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .response_writer = &body_writer.writer,
        .extra_headers = &all_headers,
    }) catch |err| {
        std.log.warn("box_client: dispatch request failed: {}", .{err});
        return error.RequestFailed;
    };

    if (result.status != .ok) return error.RequestFailed;
    return body_writer.writer.buffered();
}

/// Claim the next available task. Returns `null` when no tasks are available (HTTP 204).
pub fn claim(self: *BoxClient) !?box_types.ClaimedTask {
    const url = try claimUrl(self, self.allocator);
    defer self.allocator.free(url);

    var body_writer = std.Io.Writer.Allocating.init(self.allocator);
    defer body_writer.deinit();

    const result = self.client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .send_body = false,
        .response_writer = &body_writer.writer,
        .extra_headers = &self.headers,
    }) catch |err| {
        std.log.warn("box_client: claim request failed: {}", .{err});
        return null;
    };

    if (result.status != .ok) return null;

    const body = body_writer.writer.buffered();
    return box_types.parseClaimedTask(self.allocator, body) catch null;
}

/// Mark a task as completed by posting the result output to the outbox.
pub fn complete(self: *BoxClient, task_id: []const u8, output: []const u8) !bool {
    const url = try completeUrl(self, self.allocator, task_id);
    defer self.allocator.free(url);

    var body_writer = std.Io.Writer.Allocating.init(self.allocator);
    defer body_writer.deinit();

    const content_type_header: http.Header = .{ .name = "content-type", .value = "application/json" };
    const all_headers = [_]http.Header{ self.headers[0], content_type_header };

    const result = self.client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = output,
        .response_writer = &body_writer.writer,
        .extra_headers = &all_headers,
    }) catch |err| {
        std.log.warn("box_client: complete request failed: {}", .{err});
        return false;
    };
    return result.status == .ok;
}

/// Mark a task as failed by posting an error JSON to the outbox.
pub fn fail(self: *BoxClient, task_id: []const u8, error_json: []const u8) !bool {
    const url = try failUrl(self, self.allocator, task_id);
    defer self.allocator.free(url);

    var body_writer = std.Io.Writer.Allocating.init(self.allocator);
    defer body_writer.deinit();

    const content_type_header: http.Header = .{ .name = "content-type", .value = "application/json" };
    const all_headers = [_]http.Header{ self.headers[0], content_type_header };

    const result = self.client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = error_json,
        .response_writer = &body_writer.writer,
        .extra_headers = &all_headers,
    }) catch |err| {
        std.log.warn("box_client: fail request failed: {}", .{err});
        return false;
    };
    return result.status == .ok;
}

/// Read the outbox for this agent (all completed/failed tasks since the epoch).
/// Returns the raw JSON bytes (caller must free).
pub fn readOutbox(self: *BoxClient) ![]const u8 {
    const url = try readOutboxUrl(self, self.allocator);
    defer self.allocator.free(url);

    var body_writer = std.Io.Writer.Allocating.init(self.allocator);
    defer body_writer.deinit();

    const result = self.client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &body_writer.writer,
        .extra_headers = &self.headers,
    }) catch |err| {
        std.log.warn("box_client: readOutbox request failed: {}", .{err});
        return error.RequestFailed;
    };

    if (result.status != .ok) return error.RequestFailed;
    return body_writer.writer.buffered();
}

/// Get a result by task ID (requires a grant token from the complete response).
/// Returns the raw JSON bytes (caller must free).
pub fn getResult(self: *BoxClient, task_id: []const u8, token: []const u8) ![]const u8 {
    const url = try resultUrl(self, self.allocator, task_id, token);
    defer self.allocator.free(url);

    var body_writer = std.Io.Writer.Allocating.init(self.allocator);
    defer body_writer.deinit();

    const result = self.client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &body_writer.writer,
    }) catch |err| {
        std.log.warn("box_client: getResult request failed: {}", .{err});
        return error.RequestFailed;
    };

    if (result.status != .ok) return error.RequestFailed;
    return body_writer.writer.buffered();
}