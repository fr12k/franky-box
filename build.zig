const std = @import("std");

/// v0.2.0 — vendor the SQLite amalgamation (vendor/sqlite3.c) and compile
/// it into a static library. This eliminates the system-library dependency
/// (libsqlite3-dev / sqlite-dev) so:
///   - CI images don't need to install sqlite-dev.
///   - Cross-compilation works (the goreleaser step builds for 5 targets;
///     a system libsqlite3 only works for the native host triple).
/// FTS5 is enabled via -DSQLITE_ENABLE_FTS5.
///
/// Returns a `*Step.Compile` static library that callers link via
/// `mod.linkLibrary(sqlite_lib)`.
fn buildSqliteLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const c_flags: []const []const u8 = &.{
        "-DSQLITE_ENABLE_FTS5",
        "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
        "-DSQLITE_DEFAULT_BUSY_TIMEOUT=5000",
        "-DSQLITE_THREADSAFE=1",
        "-DSQLITE_OMIT_LOAD_EXTENSION",
        // Silence warnings on the amalgamation under -OReleaseFast.
        "-Wno-unused-function",
        "-Wno-unused-variable",
        "-Wno-unused-but-set-variable",
    };

    // Create a module with no root source file — the C source is added
    // via addCSourceFile so we can pass compile flags.
    const sqlite_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    sqlite_mod.addCSourceFile(.{
        .file = b.path("vendor/sqlite3.c"),
        .flags = c_flags,
    });

    return b.addLibrary(.{
        .name = "sqlite3",
        .root_module = sqlite_mod,
        .linkage = .static,
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // v0.2.0 — compile vendored SQLite amalgamation into a static lib.
    const sqlite_lib = buildSqliteLib(b, target, optimize);

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_mod.linkLibrary(sqlite_lib);

    // Export the module under the name "agent_memory" so that dependents
    // can call `agent_memory_dep.module("agent_memory")` to import it.
    // The exported module links sqlite3 from source, so dependents no
    // longer need to linkSystemLibrary("sqlite3") themselves.
    _ = b.addModule("franky_box", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Install the sqlite3 static lib as a named artifact so dependents
    // can link it via `dep.artifact("sqlite3")`.
    b.installArtifact(sqlite_lib);

    const lib = b.addLibrary(.{
        .name = "franky-box",
        .root_module = lib_mod,
    });

    // ── Tests ──────────────────────────────────────────────────────────
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.linkLibrary(sqlite_lib);

    const test_bin = b.addTest(.{
        .name = "franky-box-tests",
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(test_bin);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);

    // ── Integration tests (separate test binary) ──────────────────────
    const itest_mod = b.createModule(.{
        .root_source_file = b.path("test/sqlite_store_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    itest_mod.linkLibrary(sqlite_lib);
    itest_mod.addImport("franky_box", lib_mod);

    const itest_bin = b.addTest(.{
        .name = "franky-box-itests",
        .root_module = itest_mod,
    });

    const run_itests = b.addRunArtifact(itest_bin);
    const itest_step = b.step("test-integration", "Run integration tests");
    itest_step.dependOn(&run_itests.step);

    // Combined "test-all" step.
    const test_all_step = b.step("test-all", "Run all tests");
    test_all_step.dependOn(&run_tests.step);
    test_all_step.dependOn(&run_itests.step);

    b.installArtifact(lib);

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.linkLibrary(sqlite_lib);
    exe_module.addImport("franky_box", lib_mod);

    const exe = b.addExecutable(.{
        .name = "franky-box",
        .root_module = exe_module,
    });
    b.installArtifact(exe);
}
