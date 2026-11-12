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
    /// P2: scheduling — claimable only after this timestamp (null = now).
    available_at: ?[]const u8 = null,
    /// P2: DAG dependencies — JSON array of task ids this task waits on.
    blocked_by: ?[]const u8 = null,
    /// P2: producer idempotency key (dedupes retries across the task's whole life).
    idempotency_key: ?[]const u8 = null,
    /// P2: human-in-the-loop — non-null while parked awaiting input.
    pending_input: ?[]const u8 = null,
    /// P1: cancellation marker — 1 once cancel was requested.
    cancel_requested: bool = false,
    /// P2: priority — higher runs first.
    priority: i32 = 0,

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
        if (self.available_at) |x| allocator.free(x);
        if (self.blocked_by) |x| allocator.free(x);
        if (self.idempotency_key) |x| allocator.free(x);
        if (self.pending_input) |x| allocator.free(x);
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

/// Task state, aligned with the A2A `TASK_STATE_*` vocabulary
/// (a2a-protocol.org). The v0 "nullability is the state" model maps onto
/// these names for API responses and the admin UI; storage stays unchanged.
pub const TaskState = enum {
    /// Waiting to be claimed (output IS NULL, lease not held).
    submitted,
    /// Claimed, lease held (output IS NULL, locked_until in the future).
    working,
    /// Completed with output (output IS NOT NULL).
    completed,
    /// Completed with an error output (poison pill or explicit fail).
    failed,
    /// Explicitly cancelled before completion (terminal, like failed).
    canceled,
};

/// Dispatch options for the advanced (P2) dispatch endpoint. Mirrors the
/// columns a task can carry beyond the basics.
pub const DispatchOptions = struct {
    /// Priority — higher runs first (claim ORDER BY priority DESC).
    priority: i32 = 0,
    /// Earliest claim time ("YYYY-MM-DD HH:MM:SS.fff"; claimable only after).
    /// Null = immediately claimable.
    available_at: ?[]const u8 = null,
    /// Task ids this task is blocked by (DAG edge list). The task only becomes
    /// claimable when all of them have output (completed or failed).
    blocked_by: []const []const u8 = &.{},
    /// Producer-supplied idempotency key — a second dispatch with the same
    /// key returns the original task instead of creating a duplicate.
    idempotency_key: ?[]const u8 = null,
};

/// A stored agent registration (P0: persisted registry).
pub const AgentRecord = struct {
    agent_id: []const u8,
    /// Bearer secret (kept as-is today; hashing is a later hardening step).
    secret: []const u8,
    /// Human-readable label shown in the admin UI (nullable).
    name: ?[]const u8 = null,
    /// Advertised capabilities/skills (JSON array of strings, nullable).
    skills: ?[]const u8 = null,
    /// Agent Card URL (nullable) — where this agent publishes its A2A card.
    card_url: ?[]const u8 = null,
    created_at: []const u8,

    pub fn deinit(self: AgentRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.agent_id);
        allocator.free(self.secret);
        if (self.name) |n| allocator.free(n);
        if (self.skills) |s| allocator.free(s);
        if (self.card_url) |c| allocator.free(c);
        allocator.free(self.created_at);
    }
};

/// A webhook subscription (P1: push notifications). Registered per task or
/// per agent; franky-box POSTs task status changes to `url` with an
/// HMAC-SHA256 signature over the body using `secret`.
pub const WebhookSubscription = struct {
    subscription_id: []const u8,
    /// Target URL to POST events to.
    url: []const u8,
    /// HMAC secret used to sign payloads (X-Franky-Box-Signature header).
    secret: []const u8,
    /// Task id this subscription is scoped to (nullable when agent-scoped).
    task_id: ?[]const u8 = null,
    /// Agent id this subscription is scoped to (nullable when task-scoped).
    agent_id: ?[]const u8 = null,
    created_at: []const u8,

    pub fn deinit(self: WebhookSubscription, allocator: std.mem.Allocator) void {
        allocator.free(self.subscription_id);
        allocator.free(self.url);
        allocator.free(self.secret);
        if (self.task_id) |t| allocator.free(t);
        if (self.agent_id) |a| allocator.free(a);
        allocator.free(self.created_at);
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
    /// When the result was acknowledged (consumed) by a reader — null while
    /// the result is still waiting to be picked up.
    consumed_at: ?[]const u8 = null,

    pub fn deinit(self: OutboxResult, allocator: std.mem.Allocator) void {
        allocator.free(self.task_id);
        allocator.free(self.action);
        allocator.free(self.payload);
        allocator.free(self.output);
        allocator.free(self.completed_at);
        if (self.workstream_id) |w| allocator.free(w);
        if (self.consumed_at) |c| allocator.free(c);
    }
};

/// A result of an ack operation — what changed in the outbox.
pub const AckResult = struct {
    /// Number of outbox rows marked consumed.
    acked: i64,
    /// Number of outbox rows moved to the archive table by this ack
    /// (rows that were eligible for retirement already).
    archived: i64,
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

/// Summary of a workstream: its id, human-readable name, and how many tasks belong to it.
/// Used by the admin UI to list/choose existing workstreams when dispatching
/// a follow-up task. Fields are caller-owned slices.
pub const WorkstreamInfo = struct {
    workstream_id: []const u8,
    name: []const u8,
    /// Timestamp of the most recent task in this workstream (pending or done).
    /// May be empty when no tasks carry a timestamp.
    last_seen: []const u8,
    task_count: i64,
    /// When the workstream record was created (ISO8601).
    created_at: []const u8,

    pub fn deinit(self: WorkstreamInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.workstream_id);
        allocator.free(self.name);
        allocator.free(self.last_seen);
        allocator.free(self.created_at);
    }
};

/// Agent registration info.
pub const AgentInfo = struct {
    agent_id: []const u8,
    secret: []const u8,
    name: ?[]const u8 = null,
    skills: ?[]const u8 = null,
    card_url: ?[]const u8 = null,
    created_at: []const u8 = "",

    pub fn deinit(self: AgentInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.agent_id);
        allocator.free(self.secret);
        if (self.name) |n| allocator.free(n);
        if (self.skills) |s| allocator.free(s);
        if (self.card_url) |c| allocator.free(c);
        if (self.created_at.len > 0) allocator.free(self.created_at);
    }
};