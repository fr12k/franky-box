const std = @import("std");
const net = std.Io.net;
const http = std.http;
const franky = @import("root.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const port: u16 = 8080;
    const db_path = "franky-box.db";

    var store_backend = try franky.SqliteStore.init(allocator, db_path);
    var ts = store_backend.storeInterface();
    defer store_backend.deinit();

    var api = franky.Server.init(allocator, io, &ts);
    defer api.deinit();
    try api.registerDefaultAgent();

    const address = try net.IpAddress.parseIp4("0.0.0.0", port);
    var tcp_server = try address.listen(io, .{ .reuse_address = true, .kernel_backlog = 128 });
    defer tcp_server.deinit(io);

    std.log.info("franky-box listening on 0.0.0.0:{d}", .{port});

    while (true) {
        const stream = tcp_server.accept(io) catch |err| {
            std.log.err("accept: {s}", .{@errorName(err)});
            continue;
        };
        defer stream.close(io);

        var read_buf: [8192]u8 = undefined;
        var write_buf: [4096]u8 = undefined;

        var reader = net.Stream.Reader.init(stream, io, &read_buf);
        var writer = net.Stream.Writer.init(stream, io, &write_buf);
        var http_server = http.Server.init(&reader.interface, &writer.interface);

        var request = http_server.receiveHead() catch |err| {
            if (err != error.EndOfStream) std.log.warn("receiveHead: {s}", .{@errorName(err)});
            continue;
        };

        const body = if (request.head.content_length) |cl| blk: {
            if (cl > 0) {
                const size = @as(usize, @intCast(cl));
                var body_buf = try allocator.alloc(u8, size);
                defer allocator.free(body_buf);
                var body_reader = request.readerExpectNone(body_buf);
                var body_read_buf: [1][]u8 = .{body_buf};
                _ = try body_reader.readVec(body_read_buf[0..1]);
                break :blk body_buf[0..size];
            }
            break :blk "";
        } else "";

        api.handle(&request, body) catch |err| {
            std.log.err("handle: {s}", .{@errorName(err)});
            request.respond("", .{ .status = .internal_server_error }) catch {};
        };
    }
}
