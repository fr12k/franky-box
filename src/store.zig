//! Memory store interface — a vtable-based dispatch so callers can use
//! any concrete implementation behind a uniform API.
//!
//! Currently only `SqliteStore` is implemented (embedded mode).
//! The vtable keeps the door open for a future remote (HTTP) backend.

const std = @import("std");
const types = @import("types.zig");

pub const MemoryStore = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ctx: *anyopaque) void,
        capabilities: *const fn (ctx: *anyopaque) types.StoreCapabilities,

        // L1
        upsert_l1: *const fn (
            ctx: *anyopaque,
            record: types.L1Record,
            embedding: ?[]const f32,
            iso: types.IsolationContext,
        ) anyerror!bool,

        search_l1: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            query: []const u8,
            top_k: u32,
            iso: types.IsolationContext,
        ) anyerror![]types.SearchResult,

        // Recall
        recall: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            query: []const u8,
            top_k: u32,
            iso: types.IsolationContext,
        ) anyerror!types.RecallResult,

        recall_with_budget: *const fn (
            ctx: *anyopaque,
            allocator: std.mem.Allocator,
            query: []const u8,
            top_k: u32,
            iso: types.IsolationContext,
            max_chars: usize,
        ) anyerror!types.RecallResult,

        // Checkpoint
        get_checkpoint: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror!types.Checkpoint,
        set_checkpoint: *const fn (ctx: *anyopaque, checkpoint: types.Checkpoint) anyerror!void,
    };

    pub fn deinit(self: MemoryStore) void {
        self.vtable.deinit(self.ctx);
    }

    pub fn capabilities(self: MemoryStore) types.StoreCapabilities {
        return self.vtable.capabilities(self.ctx);
    }

    pub fn upsertL1(self: MemoryStore, record: types.L1Record, embedding: ?[]const f32, iso: types.IsolationContext) !bool {
        return self.vtable.upsert_l1(self.ctx, record, embedding, iso);
    }

    pub fn searchL1(self: MemoryStore, allocator: std.mem.Allocator, query: []const u8, top_k: u32, iso: types.IsolationContext) ![]types.SearchResult {
        return self.vtable.search_l1(self.ctx, allocator, query, top_k, iso);
    }

    pub fn recall(self: MemoryStore, allocator: std.mem.Allocator, query: []const u8, top_k: u32, iso: types.IsolationContext) !types.RecallResult {
        return self.vtable.recall(self.ctx, allocator, query, top_k, iso);
    }

    pub fn recallWithBudget(self: MemoryStore, allocator: std.mem.Allocator, query: []const u8, top_k: u32, iso: types.IsolationContext, max_chars: usize) !types.RecallResult {
        return self.vtable.recall_with_budget(self.ctx, allocator, query, top_k, iso, max_chars);
    }

    pub fn getCheckpoint(self: MemoryStore, allocator: std.mem.Allocator) !types.Checkpoint {
        return self.vtable.get_checkpoint(self.ctx, allocator);
    }

    pub fn setCheckpoint(self: MemoryStore, checkpoint: types.Checkpoint) !void {
        return self.vtable.set_checkpoint(self.ctx, checkpoint);
    }
};