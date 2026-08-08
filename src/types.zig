//! Core type definitions for franky-box inbox/outbox.

const std = @import("std");

pub const Task = struct {
    tenant_id: []const u8,
    agent_id: []const u8,
    task_id: []const u8,
    action: []const u8,
    payload: []const u8,
    output: ?[]const u8 = null,
    try_count: i32 = 0,
    locked_until: ?[]const u8 = null,
    completed_at: ?[]const u8 = null,

    pub fn deinit(self: Task, allocator: std.mem.Allocator) void {
        allocator.free(self.tenant_id);
        allocator.free(self.agent_id);
        allocator.free(self.task_id);
        allocator.free(self.action);
        allocator.free(self.payload);
        if (self.output) |o| allocator.free(o);
        if (self.locked_until) |l| allocator.free(l);
        if (self.completed_at) |c| allocator.free(c);
    }
};

pub const ClaimResult = struct {
    task_id: []const u8,
    action: []const u8,
    payload: []const u8,
    try_count: i32,

    pub fn deinit(self: ClaimResult, allocator: std.mem.Allocator) void {
        allocator.free(self.task_id);
        allocator.free(self.action);
        allocator.free(self.payload);
    }
};

pub const OutboxResult = struct {
    task_id: []const u8,
    action: []const u8,
    payload: []const u8,
    output: []const u8,
    completed_at: []const u8,

    pub fn deinit(self: OutboxResult, allocator: std.mem.Allocator) void {
        allocator.free(self.task_id);
        allocator.free(self.action);
        allocator.free(self.payload);
        allocator.free(self.output);
        allocator.free(self.completed_at);
    }
};
