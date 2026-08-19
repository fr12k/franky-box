//! Task store interface — vtable-based dispatch for franky-box inbox/outbox.

const std = @import("std");
const types = @import("types.zig");

pub const TaskStore = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ctx: *anyopaque) void,
        dispatch: *const fn (
            ctx: *anyopaque,
            tenant_id: []const u8,
            agent_id: []const u8,
            task_id: []const u8,
            action: []const u8,
            payload: []const u8,
            /// When non-null, links this task into an existing workstream
            /// (follow-up / continuation of another task). When null the
            /// task seeds a new workstream with its own task_id.
            workstream_id: ?[]const u8,
        ) anyerror!void,
        claim: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            tenant_id: []const u8,
            agent_id: []const u8,
        ) anyerror!?types.ClaimResult,
        complete: *const fn (
            ctx: *anyopaque,
            tenant_id: []const u8,
            agent_id: []const u8,
            task_id: []const u8,
            output: []const u8,
        ) anyerror!bool,
        readOutbox: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            tenant_id: []const u8,
            agent_id: []const u8,
            since_timestamp: []const u8,
        ) anyerror![]types.OutboxResult,
        fail: *const fn (
            ctx: *anyopaque,
            tenant_id: []const u8,
            agent_id: []const u8,
            task_id: []const u8,
            error_json: []const u8,
        ) anyerror!bool,
        purge: *const fn (ctx: *anyopaque) anyerror!void,
        /// List all pending inbox tasks (admin).
        fetchInbox: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
        ) anyerror![]types.InboxEntry,
        /// List all completed outbox tasks across all agents (admin).
        fetchOutboxAll: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
        ) anyerror![]types.OutboxResult,
        /// List all known workstreams with task counts (admin).
        fetchWorkstreams: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
        ) anyerror![]types.WorkstreamInfo,
        /// Create a new named workstream. Returns error.DuplicateWorkstreamName
        /// when the name is already taken.
        createWorkstream: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            workstream_id: []const u8,
            name: []const u8,
        ) anyerror!types.CreatedWorkstream,
        /// Look up a workstream by its id. Returns null when not found.
        lookupWorkstreamById: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            workstream_id: []const u8,
        ) anyerror!?types.CreatedWorkstream,
        /// Look up a workstream by its (unique) name. Returns null when not found.
        lookupWorkstreamByName: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            name: []const u8,
        ) anyerror!?types.CreatedWorkstream,
    };

    pub fn deinit(self: TaskStore) void {
        self.vtable.deinit(self.ctx);
    }

    pub fn dispatch(self: TaskStore, tenant_id: []const u8, agent_id: []const u8, task_id: []const u8, action: []const u8, payload: []const u8, workstream_id: ?[]const u8) !void {
        return self.vtable.dispatch(self.ctx, tenant_id, agent_id, task_id, action, payload, workstream_id);
    }

    pub fn claim(self: TaskStore, allocator: std.mem.Allocator, tenant_id: []const u8, agent_id: []const u8) !?types.ClaimResult {
        return self.vtable.claim(self.ctx, allocator, tenant_id, agent_id);
    }

    pub fn complete(self: TaskStore, tenant_id: []const u8, agent_id: []const u8, task_id: []const u8, output: []const u8) !bool {
        return self.vtable.complete(self.ctx, tenant_id, agent_id, task_id, output);
    }

    pub fn readOutbox(self: TaskStore, allocator: std.mem.Allocator, tenant_id: []const u8, agent_id: []const u8, since_timestamp: []const u8) ![]types.OutboxResult {
        return self.vtable.readOutbox(self.ctx, allocator, tenant_id, agent_id, since_timestamp);
    }

    pub fn fail(self: TaskStore, tenant_id: []const u8, agent_id: []const u8, task_id: []const u8, error_json: []const u8) !bool {
        return self.vtable.fail(self.ctx, tenant_id, agent_id, task_id, error_json);
    }

    pub fn purge(self: TaskStore) !void {
        return self.vtable.purge(self.ctx);
    }

    pub fn fetchInbox(self: TaskStore, allocator: std.mem.Allocator) ![]types.InboxEntry {
        return self.vtable.fetchInbox(self.ctx, allocator);
    }

    pub fn fetchOutboxAll(self: TaskStore, allocator: std.mem.Allocator) ![]types.OutboxResult {
        return self.vtable.fetchOutboxAll(self.ctx, allocator);
    }

    pub fn fetchWorkstreams(self: TaskStore, allocator: std.mem.Allocator) ![]types.WorkstreamInfo {
        return self.vtable.fetchWorkstreams(self.ctx, allocator);
    }

    pub fn createWorkstream(self: TaskStore, allocator: std.mem.Allocator, workstream_id: []const u8, name: []const u8) !types.CreatedWorkstream {
        return self.vtable.createWorkstream(self.ctx, allocator, workstream_id, name);
    }

    pub fn lookupWorkstreamById(self: TaskStore, allocator: std.mem.Allocator, workstream_id: []const u8) !?types.CreatedWorkstream {
        return self.vtable.lookupWorkstreamById(self.ctx, allocator, workstream_id);
    }

    pub fn lookupWorkstreamByName(self: TaskStore, allocator: std.mem.Allocator, name: []const u8) !?types.CreatedWorkstream {
        return self.vtable.lookupWorkstreamByName(self.ctx, allocator, name);
    }
};
