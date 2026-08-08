//! franky-box — embedded sqlite task inbox/outbox queue.

const std = @import("std");

pub const types = @import("types.zig");
pub const store = @import("store.zig");
pub const sqlite = @import("sqlite.zig");
pub const sqlite_store = @import("sqlite_store.zig");

pub const Task = types.Task;
pub const ClaimResult = types.ClaimResult;
pub const OutboxResult = types.OutboxResult;
pub const TaskStore = store.TaskStore;
pub const SqliteStore = sqlite_store.SqliteStore;

test {
    std.testing.refAllDecls(types);
    std.testing.refAllDecls(store);
    std.testing.refAllDecls(sqlite_store);
}
