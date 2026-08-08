const std = @import("std");
const sqlite = @import("sqlite.zig");
const sqlitedb = @import("sqlite_store.zig");
const types = @import("types.zig");

pub fn main(init: std.process.Init) !void {

    // Allocate space for the path string dynamically

    // // 1. Get the CWD instance
    // const cwd = std.Io.Dir.cwd();

    // // 2. Resolve the real absolute path into a fixed buffer
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    // // In Zig 0.17, realPath requires passing the io backend handle
    // const len = try cwd.realPath(init.io, &path_buf);
    const len = try std.process.currentPath(init.io, &path_buf);
    const cwd_string = path_buf[0..len];

    const db_path = try std.fmt.allocPrintSentinel(init.gpa, "{s}/memory.db", .{cwd_string}, 0);
    defer init.gpa.free(db_path);
    // const db = try sqlite.Db.open(db_path);

    var s = try sqlitedb.SqliteStore.init(init.gpa, init.io, db_path);
    defer s.deinit();
}
