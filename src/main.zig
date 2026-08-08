const std = @import("std");
const sqlite = @import("sqlite.zig");
const sqlitedb = @import("sqlite_store.zig");
const types = @import("types.zig");

pub fn main(init: std.process.Init) !void {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.process.currentPath(init.io, &path_buf);
    const cwd_string = path_buf[0..len];

    const db_path = try std.fmt.allocPrintSentinel(init.gpa, "{s}/memory.db", .{cwd_string}, 0);
    defer init.gpa.free(db_path);

    var s = try sqlitedb.SqliteStore.init(init.gpa, db_path);
    defer s.deinit();
}
