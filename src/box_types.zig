//! Types for the franky-box remote task inbox/outbox.

const std = @import("std");

/// A task claimed from the inbox.
/// Fields are caller-owned slices (allocated via the provided allocator).
pub const ClaimedTask = struct {
    task_id: []const u8,
    action: []const u8,
    /// JSON payload — caller owns the memory.
    payload: []const u8,
    try_count: i64,
    /// Shared id grouping tasks in the same workstream (null when absent).
    workstream_id: ?[]const u8 = null,

    pub fn deinit(self: ClaimedTask, allocator: std.mem.Allocator) void {
        allocator.free(self.task_id);
        allocator.free(self.action);
        allocator.free(self.payload);
        if (self.workstream_id) |w| allocator.free(w);
    }
};

/// Parse a ClaimedTask from the JSON body of a claim response.
pub fn parseClaimedTask(allocator: std.mem.Allocator, json: []const u8) !?ClaimedTask {
    if (json.len == 0) return null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), json, .{}) catch return null;
    if (parsed.value != .object) return null;
    const o = parsed.value.object;

    const task_id = if (o.get("task_id")) |v| if (v == .string) v.string else return null else return null;
    const action = if (o.get("action")) |v| if (v == .string) v.string else return null else return null;
    const payload_val = if (o.get("payload")) |v| v else return null;
    const try_count_val = if (o.get("try_count")) |v| if (v == .integer) v.integer else return null else return null;

    const payload = blk: {
        if (payload_val == .string) {
            break :blk try allocator.dupe(u8, payload_val.string);
        }
        break :blk try std.json.Stringify.valueAlloc(allocator, payload_val, .{});
    };

    // Optional workstream_id (null when the field is absent or explicitly null).
    var workstream_id: ?[]const u8 = null;
    if (o.get("workstream_id")) |v| {
        if (v == .string) workstream_id = try allocator.dupe(u8, v.string);
    }

    return ClaimedTask{
        .task_id = try allocator.dupe(u8, task_id),
        .action = try allocator.dupe(u8, action),
        .payload = payload,
        .try_count = try_count_val,
        .workstream_id = workstream_id,
    };
}

test "parse claimed task" {
    const allocator = std.testing.allocator;
    const json = "{\"task_id\":\"task-abc\",\"action\":\"process\",\"payload\":{\"file\":\"test.txt\"},\"try_count\":1}";
    const task = try parseClaimedTask(allocator, json);
    try std.testing.expect(task != null);
    if (task) |t| {
        defer t.deinit(allocator);
        try std.testing.expectEqualStrings("task-abc", t.task_id);
        try std.testing.expectEqualStrings("process", t.action);
        try std.testing.expectEqual(@as(i64, 1), t.try_count);
        try std.testing.expect(t.payload.len > 0);
    }
}

test "parse claimed task with workstream_id" {
    const allocator = std.testing.allocator;
    const json = "{\"task_id\":\"task-abc\",\"action\":\"process\",\"payload\":\"hi\",\"try_count\":1,\"workstream_id\":\"ws-123\"}";
    const task = try parseClaimedTask(allocator, json);
    try std.testing.expect(task != null);
    if (task) |t| {
        defer t.deinit(allocator);
        try std.testing.expectEqualStrings("task-abc", t.task_id);
        try std.testing.expect(t.workstream_id != null);
        if (t.workstream_id) |w| try std.testing.expectEqualStrings("ws-123", w);
    }
}

test "parse empty" {
    const allocator = std.testing.allocator;
    try std.testing.expect((try parseClaimedTask(allocator, "{}")) == null);
    try std.testing.expect((try parseClaimedTask(allocator, "")) == null);
}
