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
    /// Shared id grouping tasks in the same workstream.
    /// For a root task it equals the task's own id; for a follow-up it is
    /// the workstream_id of the task it continues. Never null for a stored task.
    workstream_id: ?[]const u8 = null,

    pub fn deinit(self: Task, allocator: std.mem.Allocator) void {
        allocator.free(self.tenant_id);
        allocator.free(self.agent_id);
        allocator.free(self.task_id);
        allocator.free(self.action);
        allocator.free(self.payload);
        if (self.output) |o| allocator.free(o);
        if (self.locked_until) |l| allocator.free(l);
        if (self.completed_at) |c| allocator.free(c);
        if (self.workstream_id) |w| allocator.free(w);
    }
};

pub const ClaimResult = struct {
    task_id: []const u8,
    action: []const u8,
    payload: []const u8,
    try_count: i32,
    /// Shared id grouping tasks in the same workstream (nullable).
    workstream_id: ?[]const u8 = null,

    pub fn deinit(self: ClaimResult, allocator: std.mem.Allocator) void {
        allocator.free(self.task_id);
        allocator.free(self.action);
        allocator.free(self.payload);
        if (self.workstream_id) |w| allocator.free(w);
    }
};

pub const OutboxResult = struct {
    task_id: []const u8,
    action: []const u8,
    payload: []const u8,
    output: []const u8,
    completed_at: []const u8,
    /// Shared id grouping tasks in the same workstream (nullable).
    workstream_id: ?[]const u8 = null,

    pub fn deinit(self: OutboxResult, allocator: std.mem.Allocator) void {
        allocator.free(self.task_id);
        allocator.free(self.action);
        allocator.free(self.payload);
        allocator.free(self.output);
        allocator.free(self.completed_at);
        if (self.workstream_id) |w| allocator.free(w);
    }
};

/// A row from the inbox — pending/unclaimed tasks.
/// Fields are caller-owned slices allocated via the provided allocator.
pub const InboxEntry = struct {
    tenant_id: []const u8,
    agent_id: []const u8,
    task_id: []const u8,
    action: []const u8,
    payload: []const u8,
    try_count: i32,
    locked_until: ?[]const u8,
    /// Shared id grouping tasks in the same workstream (nullable).
    workstream_id: ?[]const u8 = null,

    pub fn deinit(self: InboxEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.tenant_id);
        allocator.free(self.agent_id);
        allocator.free(self.task_id);
        allocator.free(self.action);
        allocator.free(self.payload);
        if (self.locked_until) |lu| allocator.free(lu);
        if (self.workstream_id) |w| allocator.free(w);
    }
};

/// Agent registration info.
pub const AgentInfo = struct {
    agent_id: []const u8,
    secret: []const u8,

    pub fn deinit(self: AgentInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.agent_id);
        allocator.free(self.secret);
    }
};