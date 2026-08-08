//! Core type definitions for agent-memory-zig.
//!
//! These types define the L1 memory record shapes and the isolation
//! context used to scope multi-tenant data. All types are plain structs;
//! every value is serializable to JSON.

const std = @import("std");

/// Describes what search capabilities a store backend supports.
/// Callers use this to select search strategies and degrade gracefully.
pub const StoreCapabilities = struct {
    fts_search: bool = false,
};

// ============================
// Tests
// ============================
