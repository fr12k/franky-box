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

        const target = try allocator.dupe(u8, request.head.target);
        defer allocator.free(target);

        const body = blk: {
            // Properly consume the HTTP body using the server's reader API.
            // This ensures the HTTP state machine transitions correctly so
            // that respond() does not hit the discardBody assertion.
            // For methods without a body (GET, HEAD) we skip this entirely.
            if (!request.head.method.requestHasBody()) break :blk "";

            var buf: [4096]u8 = undefined;
            var body_reader = request.readerExpectNone(&buf);
            // NOTE: after readerExpectNone, head strings are invalidated.
            // We already saved target above; handlers must not read
            // request.head.target after this point.

            // For requests with a Content-Length we read the body;
            // for those without (no body sent), the reader is in
            // body_none state and we must NOT try to read from it
            // (it would block forever on a keep-alive connection).
            if (request.head.content_length) |cl| {
                if (cl == 0) break :blk "";
                const body_bytes = body_reader.allocRemaining(allocator, .unlimited) catch |err| {
                    std.log.warn("read body: {s}", .{@errorName(err)});
                    request.respond("", .{ .status = .bad_request }) catch {};
                    continue;
                };
                break :blk body_bytes;
            }
            break :blk "";
        };
        defer if (body.len > 0) allocator.free(body);

        api.handleWithPath(&request, target, body) catch |err| {
            std.log.err("handle: {s}", .{@errorName(err)});
            request.respond("", .{ .status = .internal_server_error }) catch {};
        };
    }
}
