const std = @import("std");
const net = std.Io.net;
const http = std.http;
const franky = @import("root.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // `franky-box update [--check] [--force] [--repo owner/name]` is a
    // standalone subcommand — it doesn't need the SQLite store or the HTTP
    // server. Dispatch it before touching the database / opening the listen
    // socket so an out-of-date binary on a broken server can still upgrade
    // itself. Modeled on the `franky update` subcommand
    // (franky/src/coding/update.zig + modes/print.zig).
    if (try argAt(init, 1)) |second| {
        if (std.mem.eql(u8, second, "update")) {
            return runUpdate(allocator, io, init.environ_map, init.minimal.args);
        }
        if (std.mem.eql(u8, second, "--version") or std.mem.eql(u8, second, "-V")) {
            return writeOut(io, franky.version ++ "\n");
        }
        if (std.mem.eql(u8, second, "--help") or std.mem.eql(u8, second, "-h")) {
            return writeOut(io, usage_text);
        }
    }

    const port: u16 = 8080;
    const db_path = "franky-box.db";

    // Read admin token from environment, if set
    if (init.environ_map.get("FRANKY_BOX_ADMIN_TOKEN")) |tok| {
        franky.Server.setAdminToken(tok);
    }

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

// ── update subcommand ──────────────────────────────────────────────

const usage_text =
    \\Usage: franky-box [command] [options]
    \\
    \\
    \\franky-box is the embedded sqlite task inbox/outbox queue for franky.
    \\By default it starts the HTTP API server on 0.0.0.0:8080.
    \\
    \\Commands:
    \\  update          Replace the running binary with the latest GitHub release.
    \\  --version, -V   Print the build version and exit.
    \\  --help, -h      Show this help text and exit.
    \\
    \\Environment:
    \\  FRANKY_BOX_ADMIN_TOKEN     Admin API token (default: admin-token-change-me).
    \\  FRANKY_BOX_UPDATE_REPO     owner/name fallback for `update --repo`.
    \\  FRANKY_BOX_UPDATE_BASE_URL Override https://api.github.com (tests).
    \\
;

const update_usage =
    \\Usage: franky-box update [--check] [--force] [--repo owner/name]
    \\
    \\
    \\Replace the running franky-box binary with the latest GitHub release.
    \\
    \\  --check                Print the latest tag and exit (no replace).
    \\  --force                Replace even when versions match.
    \\  --repo owner/name      Override the GitHub repo. Defaults to
    \\                         $FRANKY_BOX_UPDATE_REPO or fr12k/franky-box.
    \\
    \\Env:
    \\  FRANKY_BOX_UPDATE_REPO     owner/name fallback for --repo.
    \\  FRANKY_BOX_UPDATE_BASE_URL Override https://api.github.com (tests).
    \\
;

/// Return argv[index] without allocating. Returns null if index is out of range.
/// On the POSIX fast path this just indexes the vector; the WASI/libc path
/// would need an allocator, but franky-box only ships for linux/macos where
/// the vector is a slice of pointers.
fn argAt(init: std.process.Init, index: usize) !?[]const u8 {
    const vector = init.minimal.args.vector;
    if (index >= vector.len) return null;
    return std.mem.sliceTo(vector[index], 0);
}

fn writeOut(io: std.Io, msg: []const u8) !void {
    const stdout = std.Io.File.stdout();
    var buf: [4096]u8 = undefined;
    var writer = stdout.writer(io, &buf);
    try writer.interface.writeAll(msg);
    try writer.interface.flush();
}

/// Handle `franky-box update [...]`. Owns its own arena so it doesn't share
/// lifetime with the main server path.
fn runUpdate(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    args: std.process.Args,
) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var opts = franky.update.Options{};

    // Skip argv[0] (program name) and argv[1] ("update"). Iterate the
    // remaining flags. The Args.Iterator gives borrowed [:0]const u8 slices;
    // we dup the ones we keep past the iterator's lifetime into the arena.
    var it = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer it.deinit();
    _ = it.next(); // argv[0]
    _ = it.next(); // "update"

    while (it.next()) |raw_arg| {
        const a = try arena.dupe(u8, raw_arg);
        if (std.mem.eql(u8, a, "--check")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, a, "--force")) {
            opts.force = true;
        } else if (std.mem.eql(u8, a, "--repo")) {
            const next = it.next() orelse {
                return exitMsg(io, "--repo requires a value (owner/name)\n", 2);
            };
            const ok = parseRepoSpec(try arena.dupe(u8, next), &opts);
            if (!ok) return exitMsg(io, "--repo expects 'owner/name'\n", 2);
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            return writeOut(io, update_usage);
        } else {
            const msg = try std.fmt.allocPrint(arena, "unknown flag: {s}\n", .{a});
            return exitMsg(io, msg, 2);
        }
    }

    if (!opts.repo_explicit) {
        if (environ_map.get("FRANKY_BOX_UPDATE_REPO")) |env_repo| {
            if (!parseRepoSpec(env_repo, &opts)) {
                return exitMsg(io, "FRANKY_BOX_UPDATE_REPO must be 'owner/name'\n", 2);
            }
        }
    }
    if (environ_map.get("FRANKY_BOX_UPDATE_BASE_URL")) |env_base| {
        opts.base_url = env_base;
    }

    const outcome = franky.update.run(arena, io, franky.version, .{
        .force = opts.force,
        .dry_run = opts.dry_run,
        .repo_owner = opts.repo_owner,
        .repo_name = opts.repo_name,
        .repo_explicit = opts.repo_explicit,
        .base_url = opts.base_url,
    }) catch |err| {
        const reason: []const u8 = switch (err) {
            error.UnsupportedPlatform => "unsupported platform — releases ship only macOS/Linux on amd64/arm64 (+ linux/386)",
            error.HttpFailure => "failed to reach GitHub releases API",
            error.ReleaseApiFailed => "failed to reach GitHub releases API",
            error.ChecksumDownloadFailed => "failed to download checksums.txt from GitHub releases",
            error.BinaryDownloadFailed => "failed to download binary asset from GitHub releases",
            error.ReleaseParseFailed => "could not parse the GitHub releases response",
            error.AssetNotFound => "no matching binary asset in the latest release",
            error.ChecksumMissing => "no checksums.txt asset (or our entry was missing)",
            error.ChecksumMismatch => "checksum mismatch — refusing to replace binary",
            error.ReplaceFailed => "could not replace the running binary (permissions?)",
            error.OutOfMemory => "out of memory",
        };
        const msg = try std.fmt.allocPrint(arena, "franky-box update: {s}\n", .{reason});
        return exitMsg(io, msg, 1);
    };

    switch (outcome) {
        .up_to_date => |tag| {
            const msg = try std.fmt.allocPrint(arena, "franky-box {s} is already up to date (latest: {s})\n", .{ franky.version, tag });
            return writeOut(io, msg);
        },
        .updated => |u| {
            const verb: []const u8 = if (opts.dry_run) "would update" else "updated";
            const msg = try std.fmt.allocPrint(arena, "{s} franky-box {s} -> {s}\n", .{ verb, u.from, u.to });
            return writeOut(io, msg);
        },
    }
}

fn parseRepoSpec(spec: []const u8, opts: *franky.update.Options) bool {
    const slash = std.mem.indexOfScalar(u8, spec, '/') orelse return false;
    if (slash == 0 or slash == spec.len - 1) return false;
    opts.repo_owner = spec[0..slash];
    opts.repo_name = spec[slash + 1 ..];
    opts.repo_explicit = true;
    return true;
}

fn exitMsg(io: std.Io, msg: []const u8, code: u8) !void {
    const stderr = std.Io.File.stderr();
    var buf: [4096]u8 = undefined;
    var writer = stderr.writer(io, &buf);
    try writer.interface.writeAll(msg);
    try writer.interface.flush();
    std.process.exit(code);
}
