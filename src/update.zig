//! Self-update — `franky-box update`.
//!
//! Mirror of the `franky update` subcommand (src/coding/update.zig in the
//! franky repo) and the github.com/containifyci/go-self-update flow:
//!
//!   1. GET https://api.github.com/repos/{owner}/{repo}/releases/latest
//!   2. Compare `tag_name` against `franky_box.version`. Skip if not newer.
//!   3. Locate the asset whose `name` is `franky-box_{os}_{arch}` and the
//!      sibling `checksums.txt` asset (both produced by .goreleaser.yaml).
//!   4. Download both into memory; verify SHA-256 of the binary against the
//!      matching line in checksums.txt.
//!   5. Write the verified bytes to `<exe>.tmp` next to the running
//!      executable (mode 0755) and atomically rename onto `<exe>`.
//!
//! Repo defaults to `fr12k/franky-box`. Override with the env var
//! `FRANKY_BOX_UPDATE_REPO=owner/name`. Override the API base for tests
//! with `FRANKY_BOX_UPDATE_BASE_URL`.
//!
//! Supported targets: macOS (arm64/amd64), Linux (arm64/amd64/386) —
//! the same matrix .goreleaser.yaml ships. Windows is unsupported
//! (os.rename over a running .exe fails on NT and the build matrix
//! doesn't ship a Windows binary anyway).

const std = @import("std");
const builtin = @import("builtin");
const http = std.http;

const franky_box = @import("root.zig");

pub const default_repo_owner = "fr12k";
pub const default_repo_name = "franky-box";
pub const default_base_url = "https://api.github.com";
pub const binary_name = "franky-box";

pub const Error = error{
    UnsupportedPlatform,
    HttpFailure,
    ReleaseParseFailed,
    AssetNotFound,
    ChecksumMissing,
    ChecksumMismatch,
    ReplaceFailed,
    ReleaseApiFailed,
    ChecksumDownloadFailed,
    BinaryDownloadFailed,
} || std.mem.Allocator.Error;

pub const Outcome = union(enum) {
    up_to_date: []const u8,
    updated: struct { from: []const u8, to: []const u8 },
};

pub const Options = struct {
    /// `https://api.github.com` in production. Override for tests.
    base_url: []const u8 = default_base_url,
    repo_owner: []const u8 = default_repo_owner,
    repo_name: []const u8 = default_repo_name,
    /// Set when the caller passed `--repo`. Drives env-fallback logic
    /// in the CLI driver (env override only kicks in if false).
    repo_explicit: bool = false,
    /// Replace the binary even when the latest tag is not newer.
    force: bool = false,
    /// Skip the actual binary swap — used by `--check`.
    dry_run: bool = false,
};

pub const TargetInfo = struct {
    os: []const u8,
    arch: []const u8,
};

/// Map the compile-time Zig target to the GoReleaser-style
/// `{os}_{arch}` token used in the franky-box release asset names
/// (see .goreleaser.yaml `name_template`). Returns null on platforms
/// we don't ship binaries for.
pub fn currentTarget() ?TargetInfo {
    const os: []const u8 = switch (builtin.target.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        else => return null,
    };
    const arch: []const u8 = switch (builtin.target.cpu.arch) {
        .x86 => "386",
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        else => return null,
    };
    return .{ .os = os, .arch = arch };
}

// ── version compare ────────────────────────────────────────────────

const SemVer = struct { major: u32, minor: u32, patch: u32 };

fn parseSemver(s: []const u8) ?SemVer {
    var rest = s;
    if (rest.len > 0 and (rest[0] == 'v' or rest[0] == 'V')) rest = rest[1..];
    if (std.mem.indexOfAny(u8, rest, "-+")) |idx| rest = rest[0..idx];
    var it = std.mem.splitScalar(u8, rest, '.');
    const maj = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const min = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const pat = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    if (it.next() != null) return null;
    return .{ .major = maj, .minor = min, .patch = pat };
}

/// True iff `latest` is strictly newer than `current` under
/// MAJOR.MINOR.PATCH semantics (pre-release / build metadata are
/// ignored — the franky-box release pipeline only cuts stable tags).
/// When `current` is unparseable the caller gets `true` (try to
/// upgrade), when `latest` is unparseable the caller gets `false`
/// (refuse blind overwrite).
pub fn isNewer(current: []const u8, latest: []const u8) bool {
    const a = parseSemver(current) orelse return true;
    const b = parseSemver(latest) orelse return false;
    if (b.major != a.major) return b.major > a.major;
    if (b.minor != a.minor) return b.minor > a.minor;
    return b.patch > a.patch;
}

// ── release JSON parsing ───────────────────────────────────────────

pub const Asset = struct {
    name: []const u8,
    url: []const u8,
};

/// Iterate `assets` from the GitHub `/releases/latest` JSON and
/// return the download URL of the asset whose name equals `want`,
/// or null if absent. Borrowed slices into the parsed JSON.
pub fn findAssetByName(root: std.json.Value, want: []const u8) ?Asset {
    const obj = switch (root) {
        .object => |o| o,
        else => return null,
    };
    const assets = obj.get("assets") orelse return null;
    const arr = switch (assets) {
        .array => |a| a,
        else => return null,
    };
    for (arr.items) |entry| {
        const e = switch (entry) {
            .object => |o| o,
            else => continue,
        };
        const name_v = e.get("name") orelse continue;
        const url_v = e.get("browser_download_url") orelse continue;
        const name = switch (name_v) {
            .string => |s| s,
            else => continue,
        };
        const url = switch (url_v) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, name, want)) return .{ .name = name, .url = url };
    }
    return null;
}

pub fn releaseTag(root: std.json.Value) ?[]const u8 {
    const obj = switch (root) {
        .object => |o| o,
        else => return null,
    };
    const v = obj.get("tag_name") orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Find the line in `checksums.txt` that ends in ` <asset_name>`
/// and return the leading 64-hex SHA-256, or null. The format is
/// the GoReleaser default: `<sha256>  <name>` per line.
pub fn findChecksumLine(checksums_text: []const u8, asset_name: []const u8) ?[]const u8 {
    var line_it = std.mem.splitScalar(u8, checksums_text, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len < 66) continue; // 64 hex + at least one space + 1-char name
        const sha = line[0..64];
        for (sha) |c| {
            const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
            if (!ok) break;
        } else {
            const rest = std.mem.trim(u8, line[64..], " \t");
            if (std.mem.eql(u8, rest, asset_name)) return sha;
        }
    }
    return null;
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex_chars = "0123456789abcdef";
    var hex: [64]u8 = undefined;
    for (digest, 0..) |b, i| {
        hex[i * 2] = hex_chars[b >> 4];
        hex[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return hex;
}

// ── HTTP fetch ─────────────────────────────────────────────────────

/// One-shot GET that follows up to 3 redirects and returns the full
/// decompressed body. The franky-box binary has no shared HTTP client
/// module, so we lean on `std.http.Client.fetch` directly. Caller
/// owns the returned slice (allocated from `arena`).
fn httpGetBytes(
    arena: std.mem.Allocator,
    client: *http.Client,
    url: []const u8,
    extra_headers: []const std.http.Header,
) Error![]u8 {
    // Combine the caller-provided headers with our defaults. The release
    // API needs `Accept: application/vnd.github+json`; binary/checksum
    // downloads pass an empty slice and only get UA + Accept.
    var aw = std.Io.Writer.Allocating.init(arena);
    defer aw.deinit();

    const accept = std.http.Header{ .name = "Accept", .value = "application/vnd.github+json" };
    const ua_value = "franky-box-update/" ++ franky_box.version;
    const ua = std.http.Header{ .name = "User-Agent", .value = ua_value };

    var headers_buf: [4]std.http.Header = undefined;
    var nheaders: usize = 0;
    headers_buf[nheaders] = ua;
    nheaders += 1;
    headers_buf[nheaders] = accept;
    nheaders += 1;
    for (extra_headers) |h| {
        if (nheaders >= headers_buf.len) break;
        headers_buf[nheaders] = h;
        nheaders += 1;
    }

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &aw.writer,
        .extra_headers = headers_buf[0..nheaders],
    }) catch |e| return switch (e) {
        // Propagate OOM distinctly so callers don't mistake a memory
        // exhaustion for a transport failure (and so --force doesn't
        // silently fall through to an unverified download on OOM).
        error.OutOfMemory => Error.OutOfMemory,
        else => Error.HttpFailure,
    };

    if (@intFromEnum(result.status) != 200) return Error.HttpFailure;
    return aw.toOwnedSlice() catch return Error.OutOfMemory;
}

// ── orchestrator ───────────────────────────────────────────────────

/// Run the full update flow. Returns Outcome on success or one of
/// `Error` on transport/release/verification failure. Borrowed strings
/// in `Outcome` live inside `arena` — caller owns the arena.
pub fn run(
    arena: std.mem.Allocator,
    io: std.Io,
    current_version: []const u8,
    opts: Options,
) Error!Outcome {
    const target = currentTarget() orelse return Error.UnsupportedPlatform;

    // One client across the three GETs — the connection pool keeps the
    // api.github.com socket alive for the JSON + checksums.txt fetches
    // (the binary download follows a 302 to a CDN host).
    var client: http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    const release_url = try std.fmt.allocPrint(
        arena,
        "{s}/repos/{s}/{s}/releases/latest",
        .{ opts.base_url, opts.repo_owner, opts.repo_name },
    );
    const release_body = httpGetBytes(arena, &client, release_url, &.{}) catch |e| {
        return switch (e) {
            error.HttpFailure => Error.ReleaseApiFailed,
            else => |other| other,
        };
    };

    var parsed = std.json.parseFromSlice(std.json.Value, arena, release_body, .{}) catch
        return Error.ReleaseParseFailed;
    defer parsed.deinit();

    const tag = releaseTag(parsed.value) orelse return Error.ReleaseParseFailed;

    if (!opts.force and !isNewer(current_version, tag)) {
        return .{ .up_to_date = try arena.dupe(u8, tag) };
    }

    const asset_name = try std.fmt.allocPrint(arena, "{s}_{s}_{s}", .{ binary_name, target.os, target.arch });
    const binary_asset = findAssetByName(parsed.value, asset_name) orelse return Error.AssetNotFound;
    const checksums_asset = findAssetByName(parsed.value, "checksums.txt") orelse
        return Error.ChecksumMissing;

    const checksums_text = httpGetBytes(arena, &client, checksums_asset.url, &.{}) catch |e| switch (e) {
        // OOM must propagate even under --force; don't fall through to an
        // unverified download on memory exhaustion.
        error.OutOfMemory => |oom| return oom,
        else => {
            if (opts.force) {
                // --force: skip verification, download binary directly.
                return forceDownloadBinary(arena, io, &client, binary_asset.url, current_version, tag, opts);
            }
            return Error.ChecksumDownloadFailed;
        },
    };

    const expected_sha = findChecksumLine(checksums_text, asset_name) orelse {
        if (opts.force) {
            return forceDownloadBinary(arena, io, &client, binary_asset.url, current_version, tag, opts);
        }
        return Error.ChecksumMissing;
    };

    const binary_bytes = httpGetBytes(arena, &client, binary_asset.url, &.{}) catch |e| {
        return switch (e) {
            error.HttpFailure => Error.BinaryDownloadFailed,
            else => |other| other,
        };
    };
    const got = sha256Hex(binary_bytes);
    if (!std.ascii.eqlIgnoreCase(&got, expected_sha)) {
        if (opts.force) {
            // Force overrides checksum mismatch — proceed to replace.
        } else {
            return Error.ChecksumMismatch;
        }
    }

    if (opts.dry_run) {
        return .{ .updated = .{
            .from = try arena.dupe(u8, current_version),
            .to = try arena.dupe(u8, tag),
        } };
    }

    // 5. Replace running binary.
    replaceExecutable(arena, io, binary_bytes) catch return Error.ReplaceFailed;
    return .{ .updated = .{
        .from = try arena.dupe(u8, current_version),
        .to = try arena.dupe(u8, tag),
    } };
}

/// Download and replace the binary without checksum verification.
/// Only called when --force is set and checksum data is unavailable.
fn forceDownloadBinary(
    arena: std.mem.Allocator,
    io: std.Io,
    client: *http.Client,
    binary_url: []const u8,
    current_version: []const u8,
    tag: []const u8,
    opts: Options,
) Error!Outcome {
    const binary_bytes = httpGetBytes(arena, client, binary_url, &.{}) catch |e| {
        return switch (e) {
            error.HttpFailure => Error.BinaryDownloadFailed,
            else => |other| other,
        };
    };

    if (opts.dry_run) {
        return .{ .updated = .{
            .from = try arena.dupe(u8, current_version),
            .to = try arena.dupe(u8, tag),
        } };
    }

    replaceExecutable(arena, io, binary_bytes) catch return Error.ReplaceFailed;
    return .{ .updated = .{
        .from = try arena.dupe(u8, current_version),
        .to = try arena.dupe(u8, tag),
    } };
}

fn replaceExecutable(allocator: std.mem.Allocator, io: std.Io, bytes: []const u8) !void {
    const exe_path = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(exe_path);

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{exe_path});
    defer allocator.free(tmp_path);

    const cwd = std.Io.Dir.cwd();
    {
        // .executable_file resolves to 0o777 on POSIX (→ 0o755 after umask).
        // The default (.default_file = 0o666 → 0o644) would leave the
        // replaced binary without the executable bit, bricking the install.
        var f = try cwd.createFile(io, tmp_path, .{ .permissions = .executable_file });
        defer f.close(io);
        try f.writeStreamingAll(io, bytes);
        f.sync(io) catch {};
    }
    cwd.rename(tmp_path, cwd, exe_path, io) catch |e| {
        cwd.deleteFile(io, tmp_path) catch {};
        return e;
    };
}

// ── tests ──────────────────────────────────────────────────────────

test "isNewer: basic ordering" {
    const t = std.testing;
    try t.expect(isNewer("1.29.7", "1.29.8"));
    try t.expect(isNewer("1.29.7", "1.30.0"));
    try t.expect(isNewer("1.29.7", "v2.0.0"));
    try t.expect(!isNewer("1.29.7", "1.29.7"));
    try t.expect(!isNewer("1.29.7", "v1.29.7"));
    try t.expect(!isNewer("1.29.7", "1.29.6"));
    try t.expect(!isNewer("2.0.0", "1.99.99"));
}

test "isNewer: pre-release suffix is stripped" {
    const t = std.testing;
    try t.expect(!isNewer("1.30.0", "1.30.0-rc1"));
    try t.expect(isNewer("1.29.7", "1.30.0-rc1"));
}

test "isNewer: unparseable inputs" {
    const t = std.testing;
    // current unparseable -> assume update needed
    try t.expect(isNewer("dev", "1.0.0"));
    // latest unparseable -> refuse
    try t.expect(!isNewer("1.0.0", "garbage"));
}

test "currentTarget: returns supported triple on linux/macos" {
    const t = std.testing;
    const tag = builtin.target.os.tag;
    if (tag == .linux or tag == .macos) {
        const ti = currentTarget() orelse return error.TestUnexpectedResult;
        try t.expect(std.mem.eql(u8, ti.os, "darwin") or std.mem.eql(u8, ti.os, "linux"));
        try t.expect(ti.arch.len > 0);
    }
}

test "findChecksumLine: matches asset name" {
    const t = std.testing;
    const txt =
        \\82322c3eeac29654fff6de189d2948bf27edeeb2eefa44639f40d717c431c298  franky-box_darwin_amd64
        \\6e7b8817a98cd129967f07f0be4b06edb34a838464134787ed546fe91ea5f6ae  franky-box_darwin_arm64
        \\c79946934483b5190563713c2f4e509ba95cbae85f7957687888dc24dfa81d7d  franky-box_linux_amd64
        \\
    ;
    const sha = findChecksumLine(txt, "franky-box_linux_amd64") orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings("c79946934483b5190563713c2f4e509ba95cbae85f7957687888dc24dfa81d7d", sha);
    try t.expect(findChecksumLine(txt, "franky-box_linux_arm64") == null);
    try t.expect(findChecksumLine(txt, "") == null);
}

test "findChecksumLine: rejects non-hex prefix" {
    const t = std.testing;
    const txt = "ZZZZ2c3eeac29654fff6de189d2948bf27edeeb2eefa44639f40d717c431c298  franky-box_linux_amd64\n";
    try t.expect(findChecksumLine(txt, "franky-box_linux_amd64") == null);
}

test "findAssetByName + releaseTag parse a representative payload" {
    const t = std.testing;
    const json_text =
        \\{
        \\  "tag_name": "v1.31.0",
        \\  "assets": [
        \\    {"name": "franky-box_linux_amd64", "browser_download_url": "https://example.test/f_lin"},
        \\    {"name": "checksums.txt",      "browser_download_url": "https://example.test/sums"}
        \\  ]
        \\}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, json_text, .{});
    defer parsed.deinit();
    try t.expectEqualStrings("v1.31.0", releaseTag(parsed.value).?);
    const a = findAssetByName(parsed.value, "franky-box_linux_amd64") orelse return error.TestUnexpectedResult;
    try t.expectEqualStrings("https://example.test/f_lin", a.url);
    try t.expect(findAssetByName(parsed.value, "missing") == null);
}

test "sha256Hex: known vector" {
    const t = std.testing;
    // SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    const got = sha256Hex("");
    try t.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &got);
}