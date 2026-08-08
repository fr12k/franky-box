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
    };

    pub fn deinit(self: TaskStore) void {
        self.vtable.deinit(self.ctx);
    }

    pub fn dispatch(self: TaskStore, tenant_id: []const u8, agent_id: []const u8, task_id: []const u8, action: []const u8, payload: []const u8) !void {
        return self.vtable.dispatch(self.ctx, tenant_id, agent_id, task_id, action, payload);
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
};
