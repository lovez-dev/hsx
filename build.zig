const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("hsx", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = module });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const check = b.step("check", "Compile tests and examples without running");
    check.dependOn(&unit_tests.step);
    b.default_step = check;
    const example = b.addExecutable(.{
        .name = "hsx-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/example.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "hsx", .module = module }},
        }),
    });
    check.dependOn(&example.step);
    const run_example = b.addRunArtifact(example);
    run_example.setCwd(b.path("."));
    run_example.addPassthruArgs();
    run_example.has_side_effects = true;
    b.step("example", "Run the proof-of-work example").dependOn(&run_example.step);

    const bench_step = b.step("bench", "Run benchmarks with -Dbench=true --release=fast");
    if (b.option(bool, "bench", "Enable the benchmark dependency and executable") orelse false) {
        const dependency = try b.dependencyLazy("zlap", .{ .target = target, .optimize = optimize });
        const benchmark = b.addExecutable(.{
            .name = "hsx-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/bench.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "hsx", .module = module },
                    .{ .name = "zlap", .module = dependency.module("zlap") },
                },
            }),
        });
        check.dependOn(&benchmark.step);
        const run = b.addRunArtifact(benchmark);
        run.addPassthruArgs();
        run.has_side_effects = true;
        bench_step.dependOn(&run.step);
    } else {
        bench_step.dependOn(&b.addFail("Enable benchmarks with -Dbench=true and select --release=fast").step);
    }
}
