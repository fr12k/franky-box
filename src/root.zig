//! franky-box — embedded sqlite task inbox/outbox queue + HTTP API.

const std = @import("std");

/// Version info injected by goreleaser via -Dversion / -Dcommit / -Ddate.
/// Falls back to "dev"/"unknown" when building with plain `zig build`.
/// Used by the /status handler and the `franky-box update` subcommand
/// to decide whether the latest GitHub release is newer.
const build_options = @import("build_options");
pub const version: []const u8 = build_options.version;
pub const commit: []const u8 = build_options.commit;
pub const build_date: []const u8 = build_options.date;

pub const types = @import("types.zig");
pub const store = @import("store.zig");
pub const sqlite = @import("sqlite.zig");
pub const sqlite_store = @import("sqlite_store.zig");
pub const auth = @import("auth.zig");
pub const server = @import("server.zig");
pub const box_types = @import("box_types.zig");
pub const box_client = @import("box_client.zig");
pub const update = @import("update.zig");
pub const uuid = @import("uuid.zig");

pub const Task = types.Task;
pub const ClaimResult = types.ClaimResult;
pub const OutboxResult = types.OutboxResult;
pub const InboxEntry = types.InboxEntry;
pub const AgentInfo = types.AgentInfo;
pub const TaskStore = store.TaskStore;
pub const SqliteStore = sqlite_store.SqliteStore;
pub const Server = server.Server;

test {
    std.testing.refAllDecls(types);
    std.testing.refAllDecls(store);
    std.testing.refAllDecls(sqlite_store);
    std.testing.refAllDecls(auth);
    std.testing.refAllDecls(box_types);
    std.testing.refAllDecls(uuid);
    std.testing.refAllDecls(@This());
}
