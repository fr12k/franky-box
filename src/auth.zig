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

test "extract bearer token" {
    const val = extractBearerToken("Bearer my-token-123");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("my-token-123", val.?);
    try std.testing.expect(extractBearerToken("Basic abc") == null);
    try std.testing.expect(extractBearerToken("") == null);
}
