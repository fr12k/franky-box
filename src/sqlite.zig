//! Minimal SQLite C bindings — only the functions we need.
//!
//! We link the system `libsqlite3` (via `linkSystemLibrary("sqlite3")` in
//! build.zig). We declare the C functions and types manually rather than
//! using @cImport (which is not available in Zig 0.17-dev).
//!
//! See https://www.sqlite.org/c3ref/funclist.html for full docs.

const std = @import("std");

// ============================
// C type definitions
// ============================

pub const sqlite3 = opaque {};
pub const sqlite3_stmt = opaque {};

pub const SQLITE_OK: c_int = 0;
pub const SQLITE_ROW: c_int = 100;
pub const SQLITE_DONE: c_int = 101;
pub const SQLITE_BUSY: c_int = 5;
pub const SQLITE_CONSTRAINT: c_int = 19;
pub const SQLITE_NULL: c_int = 5;

// Open flags.
pub const SQLITE_OPEN_READWRITE: c_int = 0x00000002;
pub const SQLITE_OPEN_CREATE: c_int = 0x00000004;
pub const SQLITE_OPEN_FULLMUTEX: c_int = 0x00010000;

// Special destructor constant for bind (transient copy).
pub const SQLITE_TRANSIENT: ?*anyopaque = @ptrFromInt(@as(usize, std.math.maxInt(usize)));

// ============================
// Extern C function declarations
// ============================

extern fn sqlite3_open_v2(
    filename: [*:0]const u8,
    ppDb: *?*sqlite3,
    flags: c_int,
    zVfs: ?[*:0]const u8,
) c_int;

extern fn sqlite3_close(db: ?*sqlite3) c_int;

extern fn sqlite3_exec(
    db: ?*sqlite3,
    sql: [*]const u8,
    callback: ?*const anyopaque,
    arg: ?*anyopaque,
    errmsg: ?*[*c]u8,
) c_int;

extern fn sqlite3_prepare_v2(
    db: ?*sqlite3,
    zSql: [*]const u8,
    nByte: c_int,
    ppStmt: *?*sqlite3_stmt,
    pzTail: ?*[*c]const u8,
) c_int;

extern fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;

extern fn sqlite3_reset(stmt: ?*sqlite3_stmt) c_int;

extern fn sqlite3_clear_bindings(stmt: ?*sqlite3_stmt) c_int;

extern fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;

extern fn sqlite3_bind_text(
    stmt: ?*sqlite3_stmt,
    idx: c_int,
    text: [*]const u8,
    nByte: c_int,
    destructor: ?*anyopaque,
) c_int;

extern fn sqlite3_bind_int64(stmt: ?*sqlite3_stmt, idx: c_int, value: i64) c_int;

extern fn sqlite3_bind_double(stmt: ?*sqlite3_stmt, idx: c_int, value: f64) c_int;

extern fn sqlite3_bind_blob(
    stmt: ?*sqlite3_stmt,
    idx: c_int,
    data: *const anyopaque,
    nByte: c_int,
    destructor: ?*anyopaque,
) c_int;

extern fn sqlite3_bind_null(stmt: ?*sqlite3_stmt, idx: c_int) c_int;

extern fn sqlite3_column_text(stmt: ?*sqlite3_stmt, idx: c_int) ?[*]const u8;

extern fn sqlite3_column_bytes(stmt: ?*sqlite3_stmt, idx: c_int) c_int;

extern fn sqlite3_column_int64(stmt: ?*sqlite3_stmt, idx: c_int) i64;

extern fn sqlite3_column_double(stmt: ?*sqlite3_stmt, idx: c_int) f64;

extern fn sqlite3_column_blob(stmt: ?*sqlite3_stmt, idx: c_int) ?*const anyopaque;

extern fn sqlite3_column_type(stmt: ?*sqlite3_stmt, idx: c_int) c_int;

extern fn sqlite3_last_insert_rowid(db: ?*sqlite3) i64;

extern fn sqlite3_changes(db: ?*sqlite3) c_int;

extern fn sqlite3_busy_timeout(db: ?*sqlite3, ms: c_int) c_int;

extern fn sqlite3_errmsg(db: ?*sqlite3) [*c]const u8;

extern fn sqlite3_free(ptr: ?*anyopaque) void;

// ============================
// Error message helper
// ============================

pub fn errmsgStr(db: ?*sqlite3) []const u8 {
    const msg = sqlite3_errmsg(db);
    if (msg == null) return "";
    return std.mem.span(msg);
}

// ============================
// Database handle wrapper
// ============================

pub const Db = struct {
    handle: ?*sqlite3,

    pub fn open(path: [:0]const u8) !Db {
        var handle: ?*sqlite3 = null;
        const flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX;
        const rc = sqlite3_open_v2(path.ptr, &handle, flags, null);
        if (rc != SQLITE_OK) {
            if (handle != null) _ = sqlite3_close(handle);
            return error.SqliteOpenFailed;
        }
        _ = sqlite3_busy_timeout(handle, 5000);
        return .{ .handle = handle };
    }

    pub fn close(self: *Db) void {
        if (self.handle) |h| {
            _ = sqlite3_close(h);
            self.handle = null;
        }
    }

    /// Execute a SQL statement that returns no rows (DDL, PRAGMA, etc.).
    pub fn exec(self: *Db, sql: []const u8) !void {
        var err_msg: [*c]u8 = null;
        const rc = sqlite3_exec(
            self.handle,
            sql.ptr,
            null,
            null,
            &err_msg,
        );
        if (rc != SQLITE_OK) {
            if (err_msg != null) {
                sqlite3_free(@ptrCast(err_msg));
            }
            return error.SqliteExecFailed;
        }
    }

    /// Prepare a SQL statement.
    pub fn prepare(self: *Db, sql: []const u8) !Stmt {
        var stmt: ?*sqlite3_stmt = null;
        const rc = sqlite3_prepare_v2(
            self.handle,
            sql.ptr,
            @intCast(sql.len),
            &stmt,
            null,
        );
        if (rc != SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        return .{ .handle = stmt, .db = self.handle };
    }

    pub fn lastInsertRowid(self: *Db) i64 {
        return sqlite3_last_insert_rowid(self.handle);
    }

    pub fn changes(self: *Db) i32 {
        return @intCast(sqlite3_changes(self.handle));
    }
};

// ============================
// Statement wrapper
// ============================

pub const Stmt = struct {
    handle: ?*sqlite3_stmt,
    db: ?*sqlite3,

    pub fn finalize(self: *Stmt) void {
        if (self.handle) |s| {
            _ = sqlite3_finalize(s);
            self.handle = null;
        }
    }

    /// Step the statement. Returns true if a row was produced, false if done.
    pub fn step(self: *Stmt) !bool {
        const rc = sqlite3_step(self.handle);
        if (rc == SQLITE_ROW) return true;
        if (rc == SQLITE_DONE) return false;
        return error.SqliteStepFailed;
    }

    pub fn reset(self: *Stmt) void {
        _ = sqlite3_reset(self.handle);
        _ = sqlite3_clear_bindings(self.handle);
    }

    // ── Bind ──────────────────────────────────────────────────────────

    pub fn bindText(self: *Stmt, idx: c_int, text: []const u8) !void {
        const rc = sqlite3_bind_text(
            self.handle,
            idx,
            text.ptr,
            @intCast(text.len),
            SQLITE_TRANSIENT,
        );
        if (rc != SQLITE_OK) return error.SqliteBindFailed;
    }

    pub fn bindInt(self: *Stmt, idx: c_int, value: i64) !void {
        const rc = sqlite3_bind_int64(self.handle, idx, value);
        if (rc != SQLITE_OK) return error.SqliteBindFailed;
    }

    pub fn bindFloat(self: *Stmt, idx: c_int, value: f64) !void {
        const rc = sqlite3_bind_double(self.handle, idx, value);
        if (rc != SQLITE_OK) return error.SqliteBindFailed;
    }

    pub fn bindBlob(self: *Stmt, idx: c_int, blob: []const u8) !void {
        const rc = sqlite3_bind_blob(
            self.handle,
            idx,
            blob.ptr,
            @intCast(blob.len),
            SQLITE_TRANSIENT,
        );
        if (rc != SQLITE_OK) return error.SqliteBindFailed;
    }

    // ── Column access ─────────────────────────────────────────────────

    pub fn columnText(self: *Stmt, idx: c_int) []const u8 {
        const ptr = sqlite3_column_text(self.handle, idx);
        if (ptr == null) return "";
        const len: usize = @intCast(sqlite3_column_bytes(self.handle, idx));
        return ptr.?[0..len];
    }

    pub fn columnInt(self: *Stmt, idx: c_int) i64 {
        return sqlite3_column_int64(self.handle, idx);
    }

    pub fn columnFloat(self: *Stmt, idx: c_int) f64 {
        return sqlite3_column_double(self.handle, idx);
    }

    pub fn columnBlob(self: *Stmt, idx: c_int) []const u8 {
        const ptr = sqlite3_column_blob(self.handle, idx);
        if (ptr == null) return &.{};
        const len: usize = @intCast(sqlite3_column_bytes(self.handle, idx));
        const byte_ptr: [*]const u8 = @ptrCast(ptr);
        return byte_ptr[0..len];
    }

    pub fn columnIsNull(self: *Stmt, idx: c_int) bool {
        return sqlite3_column_type(self.handle, idx) == SQLITE_NULL;
    }
};
