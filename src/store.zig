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
        /// Advanced dispatch with priority / scheduling / dependencies /
        /// idempotency. Returns the effective task_id (caller-owned, allocated
        /// with `allocator`; free with it) — the id of the pre-existing task
        /// when the idempotency key matched an earlier dispatch, else the
        /// freshly inserted task's id.
        dispatchAdvanced: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            tenant_id: []const u8,
            agent_id: []const u8,
            task_id: []const u8,
            action: []const u8,
            payload: []const u8,
            workstream_id: ?[]const u8,
            options: types.DispatchOptions,
        ) anyerror![]const u8,
        /// Extend the claim lease on a working task (heartbeat). Returns the
        /// new locked_until (caller-owned), or null when the task is not in
        /// the inbox (already completed / failed / unknown / parked).
        heartbeat: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            tenant_id: []const u8,
            agent_id: []const u8,
            task_id: []const u8,
            extend_seconds: i64,
        ) anyerror!?[]const u8,
        /// Cancel a task. Returns false when the task is unknown or already
        /// terminal (completed/failed/cancelled) — cancellation races with
        /// completion and the terminal state wins.
        cancel: *const fn (
            ctx: *anyopaque,
            tenant_id: []const u8,
            agent_id: []const u8,
            task_id: []const u8,
            reason: []const u8,
        ) anyerror!bool,
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
        /// Acknowledge (consume) a single outbox result. Marks the row as
        /// consumed so it is no longer returned by readOutbox. Returns false
        /// when the task does not exist or has no output yet (still in inbox).
        ack: *const fn (
            ctx: *anyopaque,
            tenant_id: []const u8,
            agent_id: []const u8,
            task_id: []const u8,
        ) anyerror!bool,
        /// Acknowledge all unconsumed results in an agent's outbox completed
        /// at or before `before_timestamp` ("1970-01-01 00:00:00" acks all).
        /// Returns what was acked and what was retired to the archive.
        ackAll: *const fn (
            ctx: *anyopaque,
            tenant_id: []const u8,
            agent_id: []const u8,
            before_timestamp: []const u8,
        ) anyerror!types.AckResult,
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
        /// List archived tasks (retired from the hot outbox), newest first (admin).
        fetchArchive: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
        ) anyerror![]types.OutboxResult,
        /// List all known workstreams with task counts (admin).
        fetchWorkstreams: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
        ) anyerror![]types.WorkstreamInfo,
        /// Create a new named workstream. Returns error.DuplicateWorkstreamName
        /// when the name is already taken. The caller supplies the workstream_id.
        createWorkstream: *const fn (
            ctx: *anyopaque,
            workstream_id: []const u8,
            name: []const u8,
        ) anyerror!void,
        /// Look up a workstream by its id. Returns the workstream_id (caller-owned)
        /// or null when not found.
        lookupWorkstreamById: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            workstream_id: []const u8,
        ) anyerror!?[]u8,
        /// Look up a workstream by its (unique) name. Returns the workstream_id
        /// (caller-owned) or null when not found.
        lookupWorkstreamByName: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            name: []const u8,
        ) anyerror!?[]u8,
        /// Get a single task's full state (any lifecycle stage) by id.
        /// Returns null when the task is unknown.
        getTask: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            tenant_id: []const u8,
            agent_id: []const u8,
            task_id: []const u8,
        ) anyerror!?types.Task,
        /// Park a working task in the human-in-the-loop state: release the
        /// lease and record a pending input request. Returns false when the
        /// task is not in the inbox (unknown or already terminal).
        requestInput: *const fn (
            ctx: *anyopaque,
            tenant_id: []const u8,
            agent_id: []const u8,
            task_id: []const u8,
            query: []const u8,
        ) anyerror!bool,
        /// Deliver human/producer input to a parked task and hand the lease
        /// back so the same agent can resume. Returns the input echoed back
        /// (caller-owned) or null when the task is not parked awaiting input.
        provideInput: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            tenant_id: []const u8,
            agent_id: []const u8,
            task_id: []const u8,
            input: []const u8,
        ) anyerror!?[]const u8,
        // ── Agent registry (P0: persisted) ─────────────────────────────
        /// Create or update an agent registration. Returns the stored secret.
        upsertAgent: *const fn (
            ctx: *anyopaque,
            agent_id: []const u8,
            secret: []const u8,
            name: ?[]const u8,
            skills: ?[]const u8,
            card_url: ?[]const u8,
        ) anyerror!void,
        /// Look up an agent's secret. Returns null when not registered.
        getAgentSecret: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            agent_id: []const u8,
        ) anyerror!?[]u8,
        /// List all registered agents (admin).
        listAgents: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
        ) anyerror![]types.AgentRecord,
        // ── Webhook subscriptions (P1: push) ───────────────────────────
        /// Register a webhook subscription (task- or agent-scoped).
        addWebhook: *const fn (
            ctx: *anyopaque,
            subscription_id: []const u8,
            url: []const u8,
            secret: []const u8,
            task_id: ?[]const u8,
            agent_id: ?[]const u8,
        ) anyerror!void,
        /// List webhook subscriptions matching a task and/or agent.
        listWebhooks: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            task_id: ?[]const u8,
            agent_id: ?[]const u8,
        ) anyerror![]types.WebhookSubscription,
        /// Delete a webhook subscription. Returns false when unknown.
        deleteWebhook: *const fn (
            ctx: *anyopaque,
            subscription_id: []const u8,
        ) anyerror!bool,
    };

    pub fn deinit(self: TaskStore) void {
        self.vtable.deinit(self.ctx);
    }

    pub fn dispatch(self: TaskStore, tenant_id: []const u8, agent_id: []const u8, task_id: []const u8, action: []const u8, payload: []const u8, workstream_id: ?[]const u8) !void {
        return self.vtable.dispatch(self.ctx, tenant_id, agent_id, task_id, action, payload, workstream_id);
    }

    pub fn dispatchAdvanced(self: TaskStore, allocator: std.mem.Allocator, tenant_id: []const u8, agent_id: []const u8, task_id: []const u8, action: []const u8, payload: []const u8, workstream_id: ?[]const u8, options: types.DispatchOptions) ![]const u8 {
        return self.vtable.dispatchAdvanced(self.ctx, allocator, tenant_id, agent_id, task_id, action, payload, workstream_id, options);
    }

    pub fn heartbeat(self: TaskStore, allocator: std.mem.Allocator, tenant_id: []const u8, agent_id: []const u8, task_id: []const u8, extend_seconds: i64) !?[]const u8 {
        return self.vtable.heartbeat(self.ctx, allocator, tenant_id, agent_id, task_id, extend_seconds);
    }

    pub fn cancel(self: TaskStore, tenant_id: []const u8, agent_id: []const u8, task_id: []const u8, reason: []const u8) !bool {
        return self.vtable.cancel(self.ctx, tenant_id, agent_id, task_id, reason);
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

    pub fn ack(self: TaskStore, tenant_id: []const u8, agent_id: []const u8, task_id: []const u8) !bool {
        return self.vtable.ack(self.ctx, tenant_id, agent_id, task_id);
    }

    pub fn ackAll(self: TaskStore, tenant_id: []const u8, agent_id: []const u8, before_timestamp: []const u8) !types.AckResult {
        return self.vtable.ackAll(self.ctx, tenant_id, agent_id, before_timestamp);
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

    pub fn fetchArchive(self: TaskStore, allocator: std.mem.Allocator) ![]types.OutboxResult {
        return self.vtable.fetchArchive(self.ctx, allocator);
    }

    pub fn fetchWorkstreams(self: TaskStore, allocator: std.mem.Allocator) ![]types.WorkstreamInfo {
        return self.vtable.fetchWorkstreams(self.ctx, allocator);
    }

    pub fn createWorkstream(self: TaskStore, workstream_id: []const u8, name: []const u8) !void {
        return self.vtable.createWorkstream(self.ctx, workstream_id, name);
    }

    pub fn lookupWorkstreamById(self: TaskStore, allocator: std.mem.Allocator, workstream_id: []const u8) !?[]u8 {
        return self.vtable.lookupWorkstreamById(self.ctx, allocator, workstream_id);
    }

    pub fn lookupWorkstreamByName(self: TaskStore, allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
        return self.vtable.lookupWorkstreamByName(self.ctx, allocator, name);
    }

    pub fn getTask(self: TaskStore, allocator: std.mem.Allocator, tenant_id: []const u8, agent_id: []const u8, task_id: []const u8) !?types.Task {
        return self.vtable.getTask(self.ctx, allocator, tenant_id, agent_id, task_id);
    }

    pub fn requestInput(self: TaskStore, tenant_id: []const u8, agent_id: []const u8, task_id: []const u8, query: []const u8) !bool {
        return self.vtable.requestInput(self.ctx, tenant_id, agent_id, task_id, query);
    }

    pub fn provideInput(self: TaskStore, allocator: std.mem.Allocator, tenant_id: []const u8, agent_id: []const u8, task_id: []const u8, input: []const u8) !?[]const u8 {
        return self.vtable.provideInput(self.ctx, allocator, tenant_id, agent_id, task_id, input);
    }

    pub fn upsertAgent(self: TaskStore, agent_id: []const u8, secret: []const u8, name: ?[]const u8, skills: ?[]const u8, card_url: ?[]const u8) !void {
        return self.vtable.upsertAgent(self.ctx, agent_id, secret, name, skills, card_url);
    }

    pub fn getAgentSecret(self: TaskStore, allocator: std.mem.Allocator, agent_id: []const u8) !?[]u8 {
        return self.vtable.getAgentSecret(self.ctx, allocator, agent_id);
    }

    pub fn listAgents(self: TaskStore, allocator: std.mem.Allocator) ![]types.AgentRecord {
        return self.vtable.listAgents(self.ctx, allocator);
    }

    pub fn addWebhook(self: TaskStore, subscription_id: []const u8, url: []const u8, secret: []const u8, task_id: ?[]const u8, agent_id: ?[]const u8) !void {
        return self.vtable.addWebhook(self.ctx, subscription_id, url, secret, task_id, agent_id);
    }

    pub fn listWebhooks(self: TaskStore, allocator: std.mem.Allocator, task_id: ?[]const u8, agent_id: ?[]const u8) ![]types.WebhookSubscription {
        return self.vtable.listWebhooks(self.ctx, allocator, task_id, agent_id);
    }

    pub fn deleteWebhook(self: TaskStore, subscription_id: []const u8) !bool {
        return self.vtable.deleteWebhook(self.ctx, subscription_id);
    }
};
