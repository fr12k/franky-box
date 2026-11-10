//! Authentication & authorization for franky-box.

const std = @import("std");
const crypto = std.crypto;
const mem = std.mem;
const hmac = crypto.auth.hmac;

pub fn validateBearerToken(
    token: []const u8,
    expected_agent_id: []const u8,
    agents: std.StringHashMap([]const u8),
) bool {
    if (agents.get(expected_agent_id)) |stored_secret| {
        return mem.eql(u8, token, stored_secret);
    }
    return false;
}

/// Generate an HMAC-SHA256 grant token.
/// `now_seconds` is the current Unix epoch timestamp in seconds.
pub fn generateGrantToken(
    allocator: std.mem.Allocator,
    task_id: []const u8,
    agent_secret: []const u8,
    expires_in_seconds: i64,
    now_seconds: i64,
) ![]const u8 {
    const expires_at = now_seconds + expires_in_seconds;
    const message = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ task_id, expires_at });
    defer allocator.free(message);

    var mac: [hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    hmac.sha2.HmacSha256.create(&mac, message, agent_secret);

    const hex = std.fmt.bytesToHex(&mac, .lower);
    const token = try std.fmt.allocPrint(allocator, "fb_grant_{s}_exp{d}", .{ &hex, expires_at });
    return token;
}

/// Verify a grant token for a specific task (the normal use: /v1/results/{id}).
/// Returns true iff the token is well-formed, unexpired, and its HMAC matches
/// the HMAC over "{task_id}:{expires_at}" signed with `agent_secret`.
/// Comparison is constant-time so tokens cannot be guessed via timing.
pub fn verifyGrantTokenFor(
    allocator: std.mem.Allocator,
    token: []const u8,
    task_id: []const u8,
    agent_secret: []const u8,
    now_seconds: i64,
) !bool {
    if (!mem.startsWith(u8, token, "fb_grant_")) return false;
    const rest = token["fb_grant_".len..];
    const exp_idx = mem.indexOf(u8, rest, "_exp") orelse return false;
    const hex_mac = rest[0..exp_idx];
    const exp_str = rest[exp_idx + "_exp".len..];
    if (hex_mac.len != hmac.sha2.HmacSha256.mac_length * 2) return false;
    if (exp_str.len == 0) return false;
    const expires_at = std.fmt.parseInt(i64, exp_str, 10) catch return false;
    if (expires_at <= now_seconds) return false;

    // Recompute the expected MAC over task_id:expires_at.
    const message = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ task_id, expires_at });
    defer allocator.free(message);
    var expected: [hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    hmac.sha2.HmacSha256.create(&expected, message, agent_secret);
    const expected_hex = std.fmt.bytesToHex(&expected, .lower);

    // Constant-time compare of the hex MACs.
    var diff: u8 = 0;
    for (expected_hex, hex_mac) |a, b| diff |= a ^ b;
    return diff == 0;
}

/// Extract the Bearer token value from an Authorization header.
pub fn extractBearerToken(auth_header: []const u8) ?[]const u8 {
    if (!mem.startsWith(u8, auth_header, "Bearer ")) return null;
    return auth_header["Bearer ".len..];
}

test "generate grant token format" {
    const allocator = std.testing.allocator;
    const token = try generateGrantToken(allocator, "task-101", "my-secret-key", 3600, 1700000000);
    defer allocator.free(token);

    try std.testing.expect(mem.startsWith(u8, token, "fb_grant_"));
    try std.testing.expect(token.len > 30);
}

test "grant token verifies for its own task" {
    const allocator = std.testing.allocator;
    const now: i64 = 1700000000;
    const token = try generateGrantToken(allocator, "task-101", "my-secret-key", 3600, now);
    defer allocator.free(token);

    // Correct task + secret + within expiry → true.
    try std.testing.expect(try verifyGrantTokenFor(allocator, token, "task-101", "my-secret-key", now));
    // Same now + 1s before expiry → true.
    try std.testing.expect(try verifyGrantTokenFor(allocator, token, "task-101", "my-secret-key", now + 3599));
}

test "grant token rejects wrong task, wrong secret, expiry, and garbage" {
    const allocator = std.testing.allocator;
    const now: i64 = 1700000000;
    const token = try generateGrantToken(allocator, "task-101", "my-secret-key", 3600, now);
    defer allocator.free(token);

    // Wrong task id → false (MAC covers task_id).
    try std.testing.expect(!(try verifyGrantTokenFor(allocator, token, "task-102", "my-secret-key", now)));
    // Wrong secret → false.
    try std.testing.expect(!(try verifyGrantTokenFor(allocator, token, "task-101", "other-secret", now)));
    // Expired → false.
    try std.testing.expect(!(try verifyGrantTokenFor(allocator, token, "task-101", "my-secret-key", now + 3600)));
    // Malformed → false.
    try std.testing.expect(!(try verifyGrantTokenFor(allocator, "garbage", "task-101", "my-secret-key", now)));
    try std.testing.expect(!(try verifyGrantTokenFor(allocator, "fb_grant_short_exp1700003600", "task-101", "my-secret-key", now)));
    try std.testing.expect(!(try verifyGrantTokenFor(allocator, "", "task-101", "my-secret-key", now)));
}

test "extract bearer token" {
    const val = extractBearerToken("Bearer my-token-123");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("my-token-123", val.?);
    try std.testing.expect(extractBearerToken("Basic abc") == null);
    try std.testing.expect(extractBearerToken("") == null);
}
