//! Lightweight module that only exports the box client library (no SQLite).
//! Use this when importing franky-box as a dependency from franky agents.
//! The full root.zig (with SQLite + server) is used for the franky-box binary.

pub const box_types = @import("box_types.zig");
pub const box_client = @import("box_client.zig");