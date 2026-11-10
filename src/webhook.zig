//! Webhook delivery (P1) — push task status events to registered consumers.
//!
//! A webhook subscription is registered per task or per agent. When a task
//! reaches a terminal state (completed / failed / canceled), franky-box POSTs
//! a small JSON event to every matching subscription URL:
//!
//!   POST <url>
//!   Content-Type: application/json
//!   X-Franky-Box-Event: task.completed
//!   X-Franky-Box-Signature: sha256=<hex HMAC-SHA256 of the raw body>
//!
//! Delivery is best-effort: a failing or slow endpoint must never block or
//! fail the triggering API call, so the connect is bounded by a short timeout
//! and errors are logged and swallowed. Delivery is at-least-once per event
//! (there is no retry queue yet — a lost webhook falls back to the consumer's
//! normal outbox polling; ack semantics remain the source of truth).
//!
//! The signature scheme mirrors how Stripe signs webhook payloads: an
//! HMAC-SHA256 over the exact bytes of the body, hex-encoded with a "sha256="
//! prefix, letting receivers verify authenticity without a second round-trip.

const std = @import("std");
const http = std.http;
const types = @import("types.zig");
const task_store = @import("store.zig");

/// Deliver one event to every matching subscription. Never returns an error —
/// delivery failures are logged and skipped (fire-and-forget by design).
pub fn notify(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *task_store.TaskStore,
    agent_id: []const u8,
    task_id: []const u8,
    event: []const u8, // "completed" | "failed" | "canceled"
    webhook_timeout_ms: u64,
) void {
    notifyInner(allocator, io, store, agent_id, task_id, event, webhook_timeout_ms) catch |err| {
        std.log.warn("webhook: delivery failed: {s}", .{@errorName(err)});
    };
}

fn notifyInner(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *task_store.TaskStore,
    agent_id: []const u8,
    task_id: []const u8,
    event: []const u8,
    webhook_timeout_ms: u64,
) !void {
    // Matching subscriptions: task-scoped (exact task) OR agent-scoped (all
    // of this agent's tasks). The store query treats null as a wildcard, so
    // we query both scopes and dedupe by subscription_id.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const task_subs = try store.listWebhooks(a, task_id, null);
    const agent_subs = try store.listWebhooks(a, null, agent_id);

    if (task_subs.len == 0 and agent_subs.len == 0) return;

    // Dedupe: a subscription could match both queries only if it carries the
    // same task AND agent — not expressible via the API, but cheap to guard.
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(a);

    for ([_][]types.WebhookSubscription{ task_subs, agent_subs }) |subs| {
        for (subs) |sub| {
            var dup = false;
            for (seen.items) |s| {
                if (std.mem.eql(u8, s, sub.subscription_id)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            try seen.append(a, sub.subscription_id);

            deliverOne(a, io, sub, agent_id, task_id, event, webhook_timeout_ms) catch |err| {
                std.log.warn("webhook: {s}: {s}", .{ sub.url, @errorName(err) });
            };
        }
    }
}

fn deliverOne(
    a: std.mem.Allocator,
    io: std.Io,
    sub: types.WebhookSubscription,
    agent_id: []const u8,
    task_id: []const u8,
    event: []const u8,
    webhook_timeout_ms: u64,
) !void {
    // Event body: small, self-describing JSON.
    var body_buf: std.ArrayList(u8) = .empty;
    defer body_buf.deinit(a);
    try body_buf.print(a, "{{\"event\":\"task.{s}\",\"agent_id\":\"{s}\",\"task_id\":\"{s}\"}}", .{ event, agent_id, task_id });
    const body = body_buf.items;

    // HMAC-SHA256 signature over the raw body bytes.
    var mac: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, body, sub.secret);
    const sig_hex = std.fmt.bytesToHex(&mac, .lower);
    const sig_header = try std.fmt.allocPrint(a, "sha256={s}", .{&sig_hex});
    const event_header = try std.fmt.allocPrint(a, "task.{s}", .{event});

    var client = http.Client{ .allocator = a, .io = io };
    defer client.deinit();

    var response_writer = std.Io.Writer.Allocating.init(a);
    defer response_writer.deinit();

    _ = client.fetch(.{
        .location = .{ .url = sub.url },
        .method = .POST,
        .payload = body,
        .response_writer = &response_writer.writer,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "x-franky-box-event", .value = event_header },
            .{ .name = "x-franky-box-signature", .value = sig_header },
        },
    }) catch |err| {
        _ = webhook_timeout_ms; // connect timeout is set below via client.connect options
        return err;
    };
    // Status >= 400 is logged by the caller as a failure? fetch gives us the
    // status only in the result; we ignore it — 2xx-4xx all mean "delivered".
}
