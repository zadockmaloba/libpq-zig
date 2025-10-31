const std = @import("std");


pub fn build(b: *std.Build) void {

    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const postgres = b.dependency("libpq", .{
        .target = target,
        .optimize = optimize,
        //.@"disable-ssl" = true,
    });

    const libpq = postgres.artifact("pq");
    b.installArtifact(libpq);

    const mod = b.addModule("libpq_zig", .{

        .root_source_file = b.path("src/root.zig"),

        .target = target,
        .optimize = optimize,
    });

    mod.addIncludePath(b.path("zig-out/include/"));
    mod.addIncludePath(b.path("zig-out/include/libpq/"));
    mod.linkLibrary(libpq);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
