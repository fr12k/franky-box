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
    std.debug.print("franky-box build.zig: start
", .{});

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_mod.linkLibrary(sqlite_lib);

    // Export the module under the name "agent_memory" so that dependents
    // can call `agent_memory_dep.module("agent_memory")` to import it.
    std.debug.print("franky-box build.zig: before addModule franky_box
", .{});
    // The exported module links sqlite3 from source, so dependents no
    // longer need to linkSystemLibrary("sqlite3") themselves.
    _ = b.addModule("franky_box", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Lightweight module exporting only the box client (no SQLite).
    std.debug.print("franky-box build.zig: before addModule franky_box_client
", .{});
    // Use this from franky agents to avoid pulling in the whole SQLite build.
    _ = b.addModule("franky_box_client", .{
        .root_source_file = b.path("src/box_root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Install the sqlite3 static lib as a named artifact so dependents
    // can link it via `dep.artifact("sqlite3")`.
    b.installArtifact(sqlite_lib);

    // Named "frankybox-lib" (not "franky-box") to avoid ambiguity with
    // the executable artifact of the same name. Dependents import the
    // library via the module (b.addModule("franky_box")), not the lib
    // artifact, so this rename has no downstream impact.
    const lib = b.addLibrary(.{
        .name = "frankybox-lib",
        .root_module = lib_mod,
    });

    // ── Integration tests (separate test binary) ──────────────────────
    const itest_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration_test.zig"),
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

    // ── Unit tests ────────────────────────────────────────────────────
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
    const test_step = b.step("test", "Run all tests (unit + integration)");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_itests.step);

    // Combined "test-all" step (alias).
    const test_all_step = b.step("test-all", "Run all tests");
    test_all_step.dependOn(&run_tests.step);
    test_all_step.dependOn(&run_itests.step);

    b.installArtifact(lib);

    const franky_options = b.addOptions();
    // Version info — injected by goreleaser via -Dversion / -Dcommit / -Ddate.
    // Falls back to defaults when building with plain `zig build`.
    franky_options.addOption(
        []const u8,
        "version",
        b.option([]const u8, "version", "Version string (set by goreleaser)") orelse "dev",
    );
    franky_options.addOption(
        []const u8,
        "commit",
        b.option([]const u8, "commit", "Git commit SHA (set by goreleaser)") orelse "unknown",
    );
    franky_options.addOption(
        []const u8,
        "date",
        b.option([]const u8, "date", "Build date in RFC3339 (set by goreleaser)") orelse "unknown",
    );

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
