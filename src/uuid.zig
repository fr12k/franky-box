//! RFC 4122 v4 UUID generation for franky-box task identifiers.
//!
//! A v4 UUID is generated from 16 random bytes with the version (4) and
//! variant (10) bits fixed, then formatted as the canonical
//! `8-4-4-4-12` hex string (36 chars, lowercase).
//!
//! Randomness is drawn from the `std.Io` instance threaded through the
//! server, which in production is backed by the OS CSPRNG and in tests by
//! the deterministic testing IO — so unit tests get reproducible UUIDs.

const std = @import("std");

/// Generate a new v4 UUID and return a caller-owned 36-byte slice.
///
/// `io` provides the entropy source (`io.random`). `allocator` owns the
/// returned slice.
pub fn newV4(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);

    // RFC 4122 §4.4: set the version (4) and variant (10) bits.
    bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant 10

    return format(bytes, allocator);
}

/// Generate a new v4 UUID with a short type prefix and return a caller-owned
/// slice. The prefix (e.g. `"t_"` for tasks, `"w_"` for workstreams) makes the
/// id self-describing at a glance. The stored/passed value is `prefix + uuid`.
pub fn newPrefixed(io: std.Io, allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    const uid = try newV4(io, allocator);
    defer allocator.free(uid);
    const out = try allocator.alloc(u8, prefix.len + uid.len);
    @memcpy(out[0..prefix.len], prefix);
    @memcpy(out[prefix.len..], uid);
    return out;
}

/// Generate a task id: `t_` + v4 UUID (e.g. `t_550e8400-e29b-41d4-a716-446655440000`).
pub fn newTaskId(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    return newPrefixed(io, allocator, "t_");
}

/// Generate a workstream id: `w_` + v4 UUID (e.g. `w_550e8400-e29b-41d4-a716-446655440000`).
pub fn newWorkstreamId(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    return newPrefixed(io, allocator, "w_");
}

/// Format 16 raw bytes into the canonical `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` string.
pub fn format(bytes: [16]u8, allocator: std.mem.Allocator) ![]u8 {
    const out = try allocator.alloc(u8, 36);
    const hex = "0123456789abcdef";
    var i: usize = 0; // byte index
    var o: usize = 0; // output index
    while (i < 16) : (i += 1) {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[o] = '-';
            o += 1;
        }
        out[o] = hex[bytes[i] >> 4];
        out[o + 1] = hex[bytes[i] & 0x0F];
        o += 2;
    }
    return out;
}

test "uuid v4 format is canonical" {
    // Known bytes → canonical string (version/variant bits already set).
    const bytes = [16]u8{ 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0x4f, 0xde, 0x80, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 };
    const s = try format(bytes, std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("12345678-9abc-4fde-8000-112233445566", s);
    try std.testing.expectEqual(@as(usize, 36), s.len);
}

test "uuid v4 sets version and variant bits" {
    // Use the deterministic testing IO so this is reproducible.
    const s = try newV4(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqual(@as(usize, 36), s.len);
    // 14th char (index 14) is the version nibble → '4'.
    try std.testing.expectEqual(@as(u8, '4'), s[14]);
    // 19th char (index 19) is the first variant nibble → '8', '9', 'a', or 'b'.
    try std.testing.expect(s[19] == '8' or s[19] == '9' or s[19] == 'a' or s[19] == 'b');
}

test "uuid v4 is unique across many generations" {
    // With the deterministic testing IO the first byte increments, so
    // consecutive UUIDs differ.
    const a = try newV4(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(a);
    const b = try newV4(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

test "task id has t_ prefix and 38 chars" {
    const s = try newTaskId(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqual(@as(usize, 38), s.len);
    try std.testing.expectEqualStrings("t_", s[0..2]);
    // The UUID portion still has the version nibble at index 14+2=16.
    try std.testing.expectEqual(@as(u8, '4'), s[16]);
}

test "workstream id has w_ prefix and 38 chars" {
    const s = try newWorkstreamId(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqual(@as(usize, 38), s.len);
    try std.testing.expectEqualStrings("w_", s[0..2]);
    try std.testing.expectEqual(@as(u8, '4'), s[16]);
}

test "task and workstream ids are distinguishable" {
    const t = try newTaskId(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(t);
    const w = try newWorkstreamId(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(w);
    try std.testing.expect(t[0] == 't');
    try std.testing.expect(w[0] == 'w');
    try std.testing.expect(!std.mem.eql(u8, t, w));
}